"""Tiện ích dùng chung cho các service: nạp cấu hình, kết nối MariaDB qua MaxScale theo chuỗi node.

Chuỗi kết nối: DB_HOSTS liệt kê các MaxScale (mỗi node MariaDB có một MaxScale). Client thử lần lượt từng
địa chỉ, giống chế độ `sequential` của JDBC MariaDB. Khi một node/MaxScale chết, kết nối mới tự chuyển sang
địa chỉ kế tiếp; các thao tác lỗi tạm thời (mất kết nối, node chưa sẵn sàng, deadlock) được thử lại.
"""
from __future__ import annotations

import logging
import os
import queue
import threading
import time
from contextlib import contextmanager
from pathlib import Path

import pymysql
from pymysql.cursors import DictCursor

SERVICES_DIR = Path(__file__).resolve().parent

# Mã lỗi MySQL/MariaDB đáng thử lại:
#   1047 Unknown command (node Galera chưa sẵn sàng/non-Primary), 1053 server đang tắt,
#   1205 lock wait timeout, 1213 deadlock (kể cả xung đột certification của Galera),
#   1927 connection killed, 2003 không nối được, 2006 server gone away, 2013 mất kết nối giữa chừng,
#   2055 mất kết nối khi đọc
RETRYABLE_CODES = {1047, 1053, 1205, 1213, 1927, 2003, 2006, 2013, 2055}
# Lỗi cấu hình/quyền: thử node khác hoặc thử lại đều vô ích
FATAL_CONNECT_CODES = {1044, 1045, 1049}

log = logging.getLogger("common")


class ConfigError(Exception):
    """Cấu hình thiếu hoặc sai."""


class ConnectionFailed(Exception):
    """Không kết nối được tới bất kỳ node nào trong chuỗi."""


def setup_logging(level: str | None = None) -> None:
    logging.basicConfig(
        level=getattr(logging, (level or os.environ.get("LOG_LEVEL", "INFO")).upper(), logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def load_env_file(path: Path | None = None) -> None:
    """Nạp file .env (KEY=VALUE). Biến môi trường thật luôn ưu tiên hơn giá trị trong file."""
    path = path or SERVICES_DIR / ".env"
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
            value = value[1:-1]
        else:
            value = value.split(" #", 1)[0].strip()
        os.environ.setdefault(key, value)


def parse_targets(hosts: str, default_port: int) -> list[tuple[str, int]]:
    targets = []
    for item in hosts.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" in item:
            host, port = item.rsplit(":", 1)
            targets.append((host.strip(), int(port)))
        else:
            targets.append((item, default_port))
    return targets


class Config:
    """Cấu hình kết nối, đọc từ biến môi trường (và file .env cạnh code)."""

    def __init__(self) -> None:
        load_env_file()
        env = os.environ
        try:
            default_port = int(env.get("DB_PORT", "4006"))
            self.targets = parse_targets(env.get("DB_HOSTS", ""), default_port)
            self.connect_timeout = float(env.get("DB_CONNECT_TIMEOUT", "3"))
            self.read_timeout = float(env.get("DB_READ_TIMEOUT", "20"))
            self.write_timeout = float(env.get("DB_WRITE_TIMEOUT", "20"))
            self.max_attempts = int(env.get("DB_MAX_ATTEMPTS", "5"))
            self.pool_size = int(env.get("DB_POOL_SIZE", "4"))
        except ValueError as exc:
            raise ConfigError(f"Giá trị cấu hình không hợp lệ: {exc}") from exc
        self.user = env.get("DB_USER", "tdht")
        self.password = env.get("DB_PASSWORD", "")
        self.database = env.get("DB_NAME", "vn_provinces")
        if not self.targets:
            raise ConfigError("Thiếu DB_HOSTS (ví dụ DB_HOSTS=10.0.0.1,10.0.0.2,10.0.0.3). Xem .env.example")
        if self.password in ("", "CHANGE_ME"):
            raise ConfigError("Thiếu DB_PASSWORD. Đặt trong file .env hoặc biến môi trường.")


def is_retryable(exc: BaseException) -> bool:
    if isinstance(exc, (ConnectionFailed, ConnectionError, TimeoutError, OSError, pymysql.err.InterfaceError)):
        return True
    if isinstance(exc, pymysql.err.MySQLError) and exc.args and isinstance(exc.args[0], int):
        return exc.args[0] in RETRYABLE_CODES
    return False


class DbClient:
    """Pool kết nối nhỏ, có failover theo chuỗi node và tự thử lại.

    - query(): chạy một câu SELECT, trả về danh sách dict.
    - transaction(fn): chạy fn(cursor) trong một giao dịch rồi commit. fn có thể bị chạy LẠI khi mất kết nối
      hoặc gặp deadlock nên PHẢI idempotent (ví dụ INSERT IGNORE trên khóa duy nhất).
    """

    def __init__(self, cfg: Config, name: str = "db") -> None:
        self.cfg = cfg
        self.name = name
        self._pool: queue.LifoQueue = queue.LifoQueue()
        self._slots = threading.BoundedSemaphore(cfg.pool_size)
        self._start = 0                      # chỉ số node thử đầu tiên (node tốt gần nhất)
        self._lock = threading.Lock()
        self.current_target = ""

    # ---- kết nối ----
    def _open(self):
        errors = []
        n = len(self.cfg.targets)
        for i in range(n):
            idx = (self._start + i) % n
            host, port = self.cfg.targets[idx]
            try:
                conn = pymysql.connect(
                    host=host, port=port, user=self.cfg.user, password=self.cfg.password,
                    database=self.cfg.database, charset="utf8mb4", autocommit=True,
                    connect_timeout=self.cfg.connect_timeout, read_timeout=self.cfg.read_timeout,
                    write_timeout=self.cfg.write_timeout, cursorclass=DictCursor,
                )
            except (pymysql.err.OperationalError, pymysql.err.InterfaceError, OSError) as exc:
                code = exc.args[0] if exc.args and isinstance(exc.args[0], int) else None
                if code in FATAL_CONNECT_CODES:
                    raise ConfigError(self._fatal_hint(host, port, exc)) from exc
                errors.append(f"{host}:{port} ({exc})")
                continue
            with self._lock:
                if idx != self._start:
                    log.warning("[%s] Failover: chuyển sang %s:%s (trước đó thử %s)", self.name, host, port,
                                "; ".join(errors) or "không có lỗi")
                self._start = idx
                self.current_target = f"{host}:{port}"
            return conn
        raise ConnectionFailed("Không kết nối được tới node nào: " + "; ".join(errors))

    def _fatal_hint(self, host: str, port: int, exc: Exception) -> str:
        code = exc.args[0]
        hints = {
            1045: "sai user/mật khẩu, hoặc user chưa có host khớp IP của máy này (xem users.sql: 10.%, 192.168.%, 172.%)",
            1044: "user không có quyền trên database này",
            1049: f"database '{self.cfg.database}' chưa tồn tại: hãy import dữ liệu mẫu (sample_data/mysql/README.md)",
        }
        return f"Lỗi {code} khi nối {host}:{port}: {exc}. Gợi ý: {hints.get(code, '')}"

    @contextmanager
    def _borrow(self):
        self._slots.acquire()
        conn = None
        healthy = False
        try:
            try:
                conn = self._pool.get_nowait()
            except queue.Empty:
                conn = self._open()
            yield conn
            healthy = True
        finally:
            if conn is not None:
                if healthy:
                    self._pool.put(conn)
                else:
                    try:
                        conn.close()
                    except Exception:  # noqa: BLE001 - đóng kết nối hỏng, bỏ qua mọi lỗi
                        pass
            self._slots.release()

    def _with_retry(self, work):
        last: BaseException | None = None
        for attempt in range(1, self.cfg.max_attempts + 1):
            try:
                with self._borrow() as conn:
                    return work(conn)
            except ConfigError:
                raise
            except BaseException as exc:  # noqa: BLE001
                if not is_retryable(exc):
                    raise
                last = exc
                if attempt == self.cfg.max_attempts:
                    log.warning("[%s] Lỗi tạm thời (lần %d/%d), hết số lần thử: %s", self.name, attempt,
                                self.cfg.max_attempts, exc)
                    break
                delay = min(0.5 * attempt, 3.0)
                log.warning("[%s] Lỗi tạm thời (lần %d/%d): %s. Thử lại sau %.1fs", self.name, attempt,
                            self.cfg.max_attempts, exc, delay)
                time.sleep(delay)
        assert last is not None
        raise last

    # ---- API ----
    def query(self, sql: str, params=None) -> list[dict]:
        def work(conn):
            with conn.cursor() as cur:
                cur.execute(sql, params)
                return list(cur.fetchall())
        return self._with_retry(work)

    def execute_script(self, statements: list[str]) -> None:
        def work(conn):
            with conn.cursor() as cur:
                for stmt in statements:
                    cur.execute(stmt)
        self._with_retry(work)

    def transaction(self, fn):
        def work(conn):
            conn.begin()
            try:
                with conn.cursor() as cur:
                    result = fn(cur)
                conn.commit()
                return result
            except BaseException:
                try:
                    conn.rollback()
                except Exception:  # noqa: BLE001
                    pass
                raise
        return self._with_retry(work)

    def close(self) -> None:
        while True:
            try:
                self._pool.get_nowait().close()
            except queue.Empty:
                break
            except Exception:  # noqa: BLE001
                pass


# ---- Schema bảng sinh dữ liệu (cùng cấu trúc cột với bảng wards trong sample_data/mysql) ----
WARDS_LIVE_DDL = """
CREATE TABLE IF NOT EXISTS wards_live (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  code VARCHAR(20) NOT NULL,
  name VARCHAR(255) NOT NULL,
  name_en VARCHAR(255) NULL,
  full_name VARCHAR(255) NULL,
  full_name_en VARCHAR(255) NULL,
  code_name VARCHAR(255) NULL,
  postal_code VARCHAR(20) NULL,
  province_code VARCHAR(20) NOT NULL,
  administrative_unit_id INT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  writer_node VARCHAR(64) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_wards_live_code (code),
  KEY idx_wards_live_province (province_code),
  KEY idx_wards_live_created (created_at),
  CONSTRAINT wards_live_province_fk FOREIGN KEY (province_code) REFERENCES provinces(code),
  CONSTRAINT wards_live_unit_fk FOREIGN KEY (administrative_unit_id) REFERENCES administrative_units(id)
) ENGINE=InnoDB
"""
