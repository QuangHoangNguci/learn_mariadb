#!/usr/bin/env python3
"""Frontend: phục vụ trang web (thư mục static/) và chuyển tiếp /api/* tới reader service trên bastion.

Chạy trên MÁY LOCAL (chỉ cần Python 3, không cần cài thêm gói nào):
    python3 frontend_server.py --reader http://<ip-bastion>:8081
    # hoặc đặt biến môi trường READER_URL
    # rồi mở http://localhost:8080

Vì sao có bước chuyển tiếp (proxy): trình duyệt chỉ gọi cùng địa chỉ với trang web (localhost:8080), nên không
vướng CORS và không phải sửa địa chỉ bastion trong code JavaScript.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import threading
import urllib.error
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

STATIC_DIR = Path(__file__).resolve().parent / "static"
log = logging.getLogger("frontend")


class Handler(SimpleHTTPRequestHandler):
    reader_url = "http://127.0.0.1:8081"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

    def end_headers(self):
        # luôn lấy bản mới nhất của HTML/JS/CSS khi bạn sửa file
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def _json(self, status: int, payload) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path = urlparse(self.path).path
        if path == "/_info":
            return self._json(200, {"reader_url": self.reader_url})
        if path == "/api" or path.startswith("/api/"):
            return self._proxy()
        return super().do_GET()

    def _proxy(self) -> None:
        url = self.reader_url + self.path
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/json"}),
                                        timeout=15) as resp:
                status, body = resp.status, resp.read()
        except urllib.error.HTTPError as exc:  # reader trả 4xx/5xx: chuyển nguyên nội dung lỗi cho trình duyệt
            status, body = exc.code, exc.read()
        except (urllib.error.URLError, OSError) as exc:
            log.error("Không gọi được reader %s: %s", url, exc)
            return self._json(502, {"error": f"Frontend không kết nối được reader service tại {self.reader_url} ({exc})"})
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.address_string(), fmt % args)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--reader", default=os.environ.get("READER_URL", "http://127.0.0.1:8081"),
                   help="địa chỉ reader service, mặc định $READER_URL hoặc http://127.0.0.1:8081")
    p.add_argument("--host", default="127.0.0.1", help="địa chỉ lắng nghe, mặc định 127.0.0.1 (chỉ máy này)")
    p.add_argument("--port", type=int, default=8080, help="cổng web, mặc định 8080")
    args = p.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
                        datefmt="%Y-%m-%d %H:%M:%S")
    reader = args.reader.rstrip("/")
    if urlparse(reader).scheme not in ("http", "https"):
        log.error("--reader phải bắt đầu bằng http:// hoặc https:// (nhận được: %s)", reader)
        return 2
    Handler.reader_url = reader

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    log.info("Frontend: mở http://%s:%d  (chuyển tiếp /api tới %s)", "localhost" if args.host == "127.0.0.1" else args.host,
             args.port, reader)

    def shutdown(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, shutdown)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
