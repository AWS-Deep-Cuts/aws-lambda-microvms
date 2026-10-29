#!/usr/bin/env python3
"""AWS Deep Cuts - Lambda MicroVMs ハンズオン用「状態を持つサンドボックス」

1 プロセスで 2 つの HTTP サーバーを動かす（Python 標準ライブラリのみ）。

  APP_PORT  (既定 8080): ハンズオンで叩くアプリ API
    GET  /ping   … 生存確認（200 を返せば microVM は応答可能）
    GET  /state  … 変数一覧・起動からの経過秒数・フック履歴・時計
    GET  /clock  … time.time() / time.monotonic()（サスペンド中に時計がどうなるかを見る）
    GET  /random … random.random() / os.urandom()（同じスナップショット由来の microVM で一致するかを見る）
    POST /exec   … {"code": "..."} を永続的な名前空間で exec し、stdout と例外を返す
  HOOK_PORT (既定 9000): Lambda MicroVMs のライフサイクルフック
    POST /aws/lambda-microvms/runtime/v1/{ready,validate,run,suspend,resume,terminate} を受け取り、時刻と body を記録して 200 を返す

環境変数 APP_PORT / HOOK_PORT で変更できる。ログは標準出力（CloudWatch Logs に流れる）。
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import random
import socket
import sys
import threading
import time
import traceback
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_PORT = int(os.environ.get("APP_PORT", "8080"))
HOOK_PORT = int(os.environ.get("HOOK_PORT", "9000"))

BOOT_ID = str(uuid.uuid4())          # プロセスが起動するたびに変わる。スナップショット復元なら変わらない
BOOT_WALL = time.time()
BOOT_MONO = time.monotonic()

NAMESPACE: dict = {"__name__": "__sandbox__"}   # /exec が使う永続的な名前空間
EXEC_LOCK = threading.Lock()
EXEC_COUNT = 0
HOOK_LOG: list[dict] = []


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def log(message: str) -> None:
    print(f"[{now_iso()}] {message}", flush=True)


def clock() -> dict:
    return {
        "time": time.time(),
        "time_iso": now_iso(),
        "monotonic": time.monotonic(),
        "wall_since_boot": round(time.time() - BOOT_WALL, 3),
        "monotonic_since_boot": round(time.monotonic() - BOOT_MONO, 3),
    }


def user_vars() -> dict:
    return {k: repr(v)[:80] for k, v in NAMESPACE.items() if not k.startswith("__")}


class JSONHandler(BaseHTTPRequestHandler):
    server_version = "DeepCutsSandbox/1.0"

    def log_message(self, fmt, *args):  # 既定のアクセスログを自前の形式に
        log(f"{self.server.server_port} {self.command} {self.path} {fmt % args}")

    def read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return {"_raw": raw.decode("utf-8", errors="replace")}

    def send_json(self, status: int, body: dict) -> None:
        data = json.dumps(body, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class AppHandler(JSONHandler):
    def do_GET(self):
        if self.path == "/ping":
            self.send_json(200, {"ok": True, "boot_id": BOOT_ID, "hostname": socket.gethostname()})
        elif self.path == "/state":
            self.send_json(200, {
                "boot_id": BOOT_ID,
                "hostname": socket.gethostname(),
                "exec_count": EXEC_COUNT,
                "vars": user_vars(),
                "hooks": HOOK_LOG,
                "clock": clock(),
            })
        elif self.path == "/clock":
            self.send_json(200, clock())
        elif self.path == "/random":
            # random モジュールはプロセス起動時（= イメージのビルド時）に seed される。
            # 同じスナップショットから復元した 2 台で同じ値が出るかどうかが見どころ。
            self.send_json(200, {
                "boot_id": BOOT_ID,
                "random_random": random.random(),
                "os_urandom_hex": os.urandom(8).hex(),
                "uuid4": str(uuid.uuid4()),
            })
        else:
            self.send_json(404, {"error": f"unknown path {self.path}"})

    def do_POST(self):
        global EXEC_COUNT
        if self.path != "/exec":
            self.send_json(404, {"error": f"unknown path {self.path}"})
            return
        code = self.read_json().get("code")
        if not isinstance(code, str):
            self.send_json(400, {"error": 'body must be {"code": "<python source>"}'})
            return
        stdout = io.StringIO()
        error = None
        started = time.perf_counter()
        with EXEC_LOCK:
            EXEC_COUNT += 1
            try:
                with contextlib.redirect_stdout(stdout):
                    exec(compile(code, "<exec>", "exec"), NAMESPACE)  # noqa: S102 - サンドボックスの中なので意図的
            except Exception:  # noqa: BLE001
                error = traceback.format_exc()
        self.send_json(200, {
            "stdout": stdout.getvalue(),
            "error": error,
            "duration_ms": round((time.perf_counter() - started) * 1000, 2),
            "vars": user_vars(),
        })


class HookHandler(JSONHandler):
    """Lambda MicroVMs から呼ばれるライフサイクルフック。どのパスでも記録して 200 を返す。"""

    def _record(self):
        body = self.read_json()
        entry = {"path": self.path, "method": self.command, "at": now_iso(), "clock": clock(), "body": body}
        HOOK_LOG.append(entry)
        log(f"hook {self.command} {self.path} body={json.dumps(body, ensure_ascii=False)[:200]}")
        self.send_json(200, {"ok": True, "hook": self.path, "boot_id": BOOT_ID})

    do_POST = _record
    do_GET = _record
    do_PUT = _record


def serve(port: int, handler) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("0.0.0.0", port), handler)
    threading.Thread(target=server.serve_forever, name=f"http-{port}", daemon=True).start()
    log(f"listening on :{port} ({handler.__name__})")
    return server


def main() -> None:
    log(f"sandbox starting boot_id={BOOT_ID} python={sys.version.split()[0]} app_port={APP_PORT} hook_port={HOOK_PORT}")
    serve(HOOK_PORT, HookHandler)
    serve(APP_PORT, AppHandler)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        log("shutting down")


if __name__ == "__main__":
    main()
