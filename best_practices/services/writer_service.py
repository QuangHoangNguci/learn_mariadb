#!/usr/bin/env python3
"""Service ghi dữ liệu liên tục vào MariaDB để mô phỏng tải thật.

Cứ mỗi chu kỳ (mặc định 1 giây) service sinh một lô bản ghi phường/xã mới (cùng cấu trúc và kiểu dữ liệu với
bảng `wards` trong sample_data/mysql) rồi INSERT vào bảng `wards_live` qua MaxScale (cổng ghi 4006).
Kết nối theo chuỗi 3 node: nếu node/MaxScale đang dùng chết, tự chuyển sang node kế tiếp và thử lại.

Chạy trên bastion:
    python3 writer_service.py                       # 5 bản ghi mỗi giây
    python3 writer_service.py --batch 20 --interval 0.5
    python3 writer_service.py --duration 300        # tự dừng sau 5 phút
"""
from __future__ import annotations

import argparse
import logging
import random
import signal
import threading
import time
import unicodedata

from common import (WARDS_LIVE_DDL, Config, ConfigError, ConnectionFailed, DbClient, setup_logging)

log = logging.getLogger("writer")

FIRST = ["An", "Bình", "Cẩm", "Đông", "Hòa", "Hưng", "Kim", "Long", "Mỹ", "Nam", "Phú", "Quang",
         "Tân", "Thanh", "Thành", "Trung", "Vĩnh", "Xuân", "Yên", "Bắc", "Tây", "Hải", "Lộc", "Sơn"]
SECOND = ["An", "Bình", "Châu", "Đức", "Giang", "Hải", "Hiệp", "Lạc", "Lâm", "Lộc", "Minh", "Phong",
          "Phước", "Sơn", "Thắng", "Thịnh", "Trường", "Việt", "Hưng", "Quới", "Thạnh", "Tiến"]

# (tên viết tắt tiếng Việt trong administrative_units, tên tiếng Anh, trọng số)
UNIT_KINDS = [("Phường", "Ward", 60), ("Xã", "Commune", 38), ("Đặc khu", "Special administrative region", 2)]


def fold(text: str) -> str:
    """Bỏ dấu tiếng Việt (giống cột name_en trong dữ liệu mẫu)."""
    text = text.replace("Đ", "D").replace("đ", "d")
    return "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")


class DataFactory:
    """Sinh bản ghi phường/xã giống dữ liệu mẫu, tham chiếu tỉnh và loại đơn vị có thật trong DB."""

    def __init__(self, provinces: list[dict], units: dict[str, int]) -> None:
        self.provinces = provinces
        self.units = units
        self._seq = 0
        self._salt = f"{random.randint(0, 999):03d}"
        self.kinds = [(vi, en, w) for vi, en, w in UNIT_KINDS if vi in units]
        if not self.kinds:
            raise ConfigError("Bảng administrative_units không có Phường/Xã/Đặc khu. Đã import dữ liệu mẫu chưa?")

    def row(self) -> tuple:
        province = random.choice(self.provinces)
        vi, en, _ = random.choices(self.kinds, weights=[k[2] for k in self.kinds])[0]
        name = f"{random.choice(FIRST)} {random.choice(SECOND)}"
        name_en = fold(name)
        prefixes = [p.strip() for p in (province.get("postal_code_prefix") or "10").split(",") if p.strip()]
        postal = f"{random.choice(prefixes)}{random.randint(0, 999):03d}"[:5].ljust(5, "0")
        # Mã duy nhất, đúng 20 ký tự (cột code là VARCHAR(20)): "L" + thời gian (ms) + số thứ tự trong tiến trình
        # (không bao giờ trùng giữa các dòng sinh cùng một mili giây) + mã ngẫu nhiên riêng của tiến trình
        # (để hai writer chạy song song không trùng nhau).
        self._seq = (self._seq + 1) % 1000
        code = f"L{int(time.time() * 1000):013d}{self._seq:03d}{self._salt}"
        return (code, name, name_en, f"{vi} {name}", f"{name_en} {en}", name_en.lower().replace(" ", "_"),
                postal, province["code"], self.units[vi])


INSERT_SQL = (
    "INSERT IGNORE INTO wards_live "
    "(code, name, name_en, full_name, full_name_en, code_name, postal_code, province_code, "
    "administrative_unit_id, writer_node) "
    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, @@hostname)"
)


def insert_batch(cursor, rows: list[tuple]) -> int:
    """INSERT IGNORE theo khóa duy nhất `code`: chạy lại cùng lô (sau khi mất kết nối) không tạo bản ghi trùng."""
    inserted = 0
    for row in rows:
        cursor.execute(INSERT_SQL, row)
        inserted += cursor.rowcount
    return inserted


def load_reference(db: DbClient) -> DataFactory:
    provinces = db.query("SELECT code, name, postal_code_prefix FROM provinces ORDER BY code")
    if not provinces:
        raise ConfigError("Bảng provinces trống. Hãy import dữ liệu mẫu trước (sample_data/mysql/README.md).")
    rows = db.query("SELECT id, short_name FROM administrative_units WHERE short_name IN ('Phường', 'Xã', 'Đặc khu')")
    return DataFactory(provinces, {r["short_name"]: r["id"] for r in rows})


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--interval", type=float, default=1.0, help="chu kỳ giữa hai lô (giây), mặc định 1.0")
    p.add_argument("--batch", type=int, default=5, help="số bản ghi mỗi lô (một giao dịch), mặc định 5")
    p.add_argument("--max-rows", type=int, default=0, help="dừng sau khi ghi đủ số bản ghi này (0 = không giới hạn)")
    p.add_argument("--duration", type=float, default=0, help="dừng sau số giây này (0 = chạy mãi)")
    p.add_argument("--report", type=float, default=10.0, help="chu kỳ in thống kê (giây), mặc định 10")
    p.add_argument("--no-create-table", action="store_true", help="không tự tạo bảng wards_live")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    setup_logging()
    try:
        cfg = Config()
        db = DbClient(cfg, name="writer")
        if not args.no_create_table:
            db.execute_script([WARDS_LIVE_DDL])
            log.info("Bảng wards_live sẵn sàng")
        factory = load_reference(db)
    except ConfigError as exc:
        log.error("%s", exc)
        return 2
    except ConnectionFailed as exc:
        log.error("%s", exc)
        return 3

    log.info("Bắt đầu ghi: %d bản ghi mỗi %.2fs qua %s", args.batch, args.interval,
             ", ".join(f"{h}:{p}" for h, p in cfg.targets))

    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())

    started = time.monotonic()
    total = errors = 0
    window_rows = 0
    window_started = started
    latencies: list[float] = []

    while not stop.is_set():
        loop_start = time.monotonic()
        if args.duration and loop_start - started >= args.duration:
            break
        if args.max_rows and total >= args.max_rows:
            break
        size = args.batch if not args.max_rows else min(args.batch, args.max_rows - total)
        rows = [factory.row() for _ in range(size)]
        try:
            inserted = db.transaction(lambda cur, r=rows: insert_batch(cur, r))
            if inserted != len(rows):
                # thường do lần thử lại sau khi COMMIT lần trước đã thành công nhưng mất phản hồi: lô đã có sẵn
                log.debug("Lô %d bản ghi, thực ghi mới %d (phần còn lại đã tồn tại)", len(rows), inserted)
            total += len(rows)
            window_rows += len(rows)
            latencies.append(time.monotonic() - loop_start)
        except ConfigError as exc:
            log.error("%s", exc)
            return 2
        except Exception as exc:  # noqa: BLE001 - mọi lỗi sau khi thử lại đều chỉ ghi nhận rồi đi tiếp
            errors += 1
            log.error("Lô bị lỗi sau khi thử lại, bỏ qua: %s", exc)

        now = time.monotonic()
        if now - window_started >= args.report:
            span = now - window_started
            avg = sum(latencies) / len(latencies) if latencies else 0.0
            log.info("tổng=%d (+%d, %.1f dòng/s) lỗi=%d độ trễ lô: tb=%.0fms max=%.0fms qua %s", total, window_rows,
                     window_rows / span, errors, avg * 1000, (max(latencies) if latencies else 0) * 1000,
                     db.current_target or "?")
            window_rows, window_started, latencies = 0, now, []

        # đợi hết chu kỳ, thoát ngay nếu có tín hiệu dừng
        stop.wait(max(0.0, args.interval - (time.monotonic() - loop_start)))

    elapsed = time.monotonic() - started
    log.info("Dừng. Đã ghi %d bản ghi trong %.0fs (%.1f dòng/s), lỗi=%d", total, elapsed,
             total / elapsed if elapsed else 0, errors)
    db.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
