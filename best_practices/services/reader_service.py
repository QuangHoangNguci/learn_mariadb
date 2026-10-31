#!/usr/bin/env python3
"""Service đọc dữ liệu từ MariaDB và cung cấp REST API (JSON) cho Frontend.

Kết nối qua MaxScale theo chuỗi 3 node (cổng 4006). MaxScale `readwritesplit` tự đưa các câu SELECT sang node
đọc, nên service này chỉ chạy truy vấn đọc. Chỉ dùng thư viện chuẩn của Python cho phần HTTP.

Chạy trên bastion:
    python3 reader_service.py                      # lắng nghe 0.0.0.0:8081
    python3 reader_service.py --port 9000

API (GET, trả JSON):
    /api/health                      tình trạng service và DB, node đã trả lời
    /api/summary                     số liệu tổng quan (dữ liệu mẫu, bản ghi live, tốc độ ghi)
    /api/provinces                   danh sách tỉnh kèm số phường/xã
    /api/wards?q=&province=&limit=&offset=     tra cứu phường/xã trong dữ liệu mẫu (bảng wards)
    /api/live/latest?province=&since_id=&limit=  bản ghi mới nhất do writer ghi (bảng wards_live)
    /api/live/per-minute?minutes=30  số bản ghi ghi vào mỗi phút
    /api/live/by-province?limit=10   số bản ghi live theo tỉnh
    /api/live/by-node                số bản ghi live theo node đã nhận ghi (writer_node)
"""
from __future__ import annotations

import argparse
import json
import logging
import re
import signal
import threading
import time
from datetime import date, datetime, timedelta
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import pymysql

from common import Config, ConfigError, ConnectionFailed, DbClient, setup_logging

log = logging.getLogger("reader")

CODE_RE = re.compile(r"^[0-9A-Za-z_]{1,20}$")


class BadRequest(Exception):
    pass


class TTLCache:
    """Cache ngắn hạn để nhiều tab Frontend không nhân số truy vấn nặng (COUNT(*), GROUP BY) lên DB."""

    def __init__(self) -> None:
        self._data: dict = {}
        self._lock = threading.Lock()

    def get_or_compute(self, key, ttl: float, fn):
        now = time.monotonic()
        with self._lock:
            hit = self._data.get(key)
            if hit and hit[0] > now:
                return hit[1]
        value = fn()
        with self._lock:
            self._data[key] = (now + ttl, value)
        return value


def to_jsonable(value):
    if isinstance(value, (datetime, date)):
        return value.isoformat(sep=" ") if isinstance(value, datetime) else value.isoformat()
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    raise TypeError(f"Không chuyển được {type(value)} sang JSON")


def int_param(qs: dict, name: str, default: int, lo: int, hi: int) -> int:
    raw = qs.get(name, [None])[0]
    if raw in (None, ""):
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise BadRequest(f"Tham số {name} phải là số nguyên") from exc
    return max(lo, min(hi, value))


def code_param(qs: dict, name: str) -> str | None:
    raw = qs.get(name, [None])[0]
    if raw in (None, ""):
        return None
    if not CODE_RE.match(raw):
        raise BadRequest(f"Tham số {name} không hợp lệ")
    return raw


class Api:
    """Các truy vấn đọc. Mọi tham số đều đi qua placeholder %s (không nối chuỗi vào SQL)."""

    def __init__(self, db: DbClient, cache_ttl: float) -> None:
        self.db = db
        self.ttl = cache_ttl
        self.cache = TTLCache()

    def health(self, qs):
        row = self.db.query("SELECT 1 AS ok, @@hostname AS served_by, NOW(3) AS db_time")[0]
        return {"status": "ok", "served_by": row["served_by"], "db_time": row["db_time"],
                "connected_via": self.db.current_target}

    def summary(self, qs):
        def compute():
            row = self.db.query(
                "SELECT @@hostname AS served_by, NOW(3) AS db_time,"
                " (SELECT COUNT(*) FROM provinces) AS provinces,"
                " (SELECT COUNT(*) FROM wards) AS wards,"
                " (SELECT COUNT(*) FROM wards_live) AS live_total,"
                " (SELECT COUNT(*) FROM wards_live WHERE created_at >= NOW() - INTERVAL 1 MINUTE) AS live_last_minute,"
                " (SELECT MAX(created_at) FROM wards_live) AS last_insert_at"
            )[0]
            row["connected_via"] = self.db.current_target
            return row
        return self.cache.get_or_compute("summary", self.ttl, compute)

    def provinces(self, qs):
        def compute():
            return {"items": self.db.query(
                "SELECT p.code, p.name, p.full_name,"
                " (SELECT COUNT(*) FROM wards w WHERE w.province_code = p.code) AS wards"
                " FROM provinces p ORDER BY p.name"
            )}
        return self.cache.get_or_compute("provinces", 30.0, compute)

    def wards(self, qs):
        province = code_param(qs, "province")
        q = (qs.get("q", [""])[0] or "").strip()[:100]
        limit = int_param(qs, "limit", 20, 1, 100)
        offset = int_param(qs, "offset", 0, 0, 100000)
        where, params = [], []
        if province:
            where.append("w.province_code = %s")
            params.append(province)
        if q:
            like = "%" + q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
            where.append("(w.name LIKE %s OR w.full_name LIKE %s)")
            params += [like, like]
        sql = ("SELECT w.code, w.name, w.full_name, w.postal_code, w.province_code, p.name AS province_name"
               " FROM wards w JOIN provinces p ON p.code = w.province_code"
               + (" WHERE " + " AND ".join(where) if where else "")
               + " ORDER BY w.name, w.code LIMIT %s OFFSET %s")
        rows = self.db.query(sql, params + [limit + 1, offset])
        return {"items": rows[:limit], "has_more": len(rows) > limit, "limit": limit, "offset": offset}

    def live_latest(self, qs):
        province = code_param(qs, "province")
        since_id = int_param(qs, "since_id", 0, 0, 2 ** 62)
        limit = int_param(qs, "limit", 30, 1, 200)
        where, params = [], []
        if province:
            where.append("l.province_code = %s")
            params.append(province)
        if since_id:
            where.append("l.id > %s")
            params.append(since_id)
        sql = ("SELECT l.id, l.code, l.name, l.full_name, l.postal_code, l.province_code, p.name AS province_name,"
               " l.created_at, l.writer_node"
               " FROM wards_live l JOIN provinces p ON p.code = l.province_code"
               + (" WHERE " + " AND ".join(where) if where else "")
               + " ORDER BY l.id DESC LIMIT %s")
        return {"items": self.db.query(sql, params + [limit])}

    def live_per_minute(self, qs):
        minutes = int_param(qs, "minutes", 30, 1, 360)

        def compute():
            now_row = self.db.query("SELECT DATE_FORMAT(NOW(), '%Y-%m-%d %H:%i:00') AS now_bucket")[0]
            rows = self.db.query(
                "SELECT DATE_FORMAT(created_at, '%%Y-%%m-%%d %%H:%%i:00') AS bucket, COUNT(*) AS inserted"
                " FROM wards_live WHERE created_at >= NOW() - INTERVAL %s MINUTE GROUP BY bucket ORDER BY bucket",
                (minutes,))
            counts = {r["bucket"]: r["inserted"] for r in rows}
            end = datetime.strptime(now_row["now_bucket"], "%Y-%m-%d %H:%M:%S")
            items = []
            for i in range(minutes - 1, -1, -1):
                bucket = (end - timedelta(minutes=i)).strftime("%Y-%m-%d %H:%M:%S")
                items.append({"bucket": bucket, "inserted": counts.get(bucket, 0)})
            return {"minutes": minutes, "items": items}
        return self.cache.get_or_compute(("per_minute", minutes), self.ttl, compute)

    def live_by_province(self, qs):
        limit = int_param(qs, "limit", 10, 1, 50)

        def compute():
            return {"items": self.db.query(
                "SELECT p.code, p.name, COUNT(l.id) AS live_rows FROM provinces p"
                " LEFT JOIN wards_live l ON l.province_code = p.code"
                " GROUP BY p.code, p.name ORDER BY live_rows DESC, p.name LIMIT %s", (limit,))}
        return self.cache.get_or_compute(("by_province", limit), self.ttl * 2, compute)

    def live_by_node(self, qs):
        def compute():
            return {"items": self.db.query(
                "SELECT COALESCE(writer_node, '(không rõ)') AS writer_node, COUNT(*) AS rows_count,"
                " MAX(created_at) AS last_at FROM wards_live GROUP BY writer_node ORDER BY rows_count DESC")}
        return self.cache.get_or_compute("by_node", self.ttl * 2, compute)


class Handler(BaseHTTPRequestHandler):
    server_version = "wards-reader/1.0"
    api: Api  # gán trong main()

    ROUTES = {
        "/api/health": "health",
        "/api/summary": "summary",
        "/api/provinces": "provinces",
        "/api/wards": "wards",
        "/api/live/latest": "live_latest",
        "/api/live/per-minute": "live_per_minute",
        "/api/live/by-province": "live_by_province",
        "/api/live/by-node": "live_by_node",
    }

    def _send(self, status: int, payload) -> None:
        body = json.dumps(payload, default=to_jsonable, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):  # noqa: N802 - preflight CORS
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        method = self.ROUTES.get(parsed.path.rstrip("/") or "/")
        if parsed.path.rstrip("/") == "/api":
            return self._send(200, {"endpoints": sorted(self.ROUTES)})
        if method is None:
            return self._send(404, {"error": "Không có endpoint này", "endpoints": sorted(self.ROUTES)})
        started = time.monotonic()
        try:
            result = getattr(self.api, method)(parse_qs(parsed.query))
            self._send(200, result)
        except BadRequest as exc:
            self._send(400, {"error": str(exc)})
        except ConfigError as exc:
            log.error("%s", exc)
            self._send(500, {"error": str(exc)})
        except pymysql.err.ProgrammingError as exc:
            # thường là bảng wards_live chưa có vì writer chưa chạy lần nào
            log.error("Lỗi truy vấn: %s", exc)
            self._send(500, {"error": f"Lỗi truy vấn: {exc}. Bảng wards_live đã được writer tạo chưa?"})
        except (ConnectionFailed, pymysql.err.MySQLError, OSError) as exc:
            log.error("DB không sẵn sàng: %s", exc)
            self._send(503, {"error": f"Không truy cập được database: {exc}"})
        except Exception as exc:  # noqa: BLE001
            log.exception("Lỗi không mong đợi")
            self._send(500, {"error": f"Lỗi nội bộ: {exc}"})
        finally:
            log.debug("%s %s %.0fms", self.command, self.path, (time.monotonic() - started) * 1000)

    def log_message(self, fmt, *args):  # ghi log truy cập qua logging
        log.info("%s - %s", self.address_string(), fmt % args)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="0.0.0.0", help="địa chỉ lắng nghe, mặc định 0.0.0.0")
    p.add_argument("--port", type=int, default=8081, help="cổng HTTP, mặc định 8081")
    p.add_argument("--cache-ttl", type=float, default=1.0, help="giây cache cho truy vấn tổng hợp, mặc định 1.0")
    args = p.parse_args()

    setup_logging()
    try:
        cfg = Config()
    except ConfigError as exc:
        log.error("%s", exc)
        return 2
    db = DbClient(cfg, name="reader")
    Handler.api = Api(db, args.cache_ttl)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    log.info("Reader lắng nghe http://%s:%d, DB qua %s", args.host, args.port,
             ", ".join(f"{h}:{pt}" for h, pt in cfg.targets))

    def shutdown(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, shutdown)

    try:
        server.serve_forever()
    finally:
        server.server_close()
        db.close()
        log.info("Reader đã dừng")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
