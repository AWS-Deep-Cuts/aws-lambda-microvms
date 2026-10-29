#!/usr/bin/env python3
"""AWS Deep Cuts - Lambda MicroVMs: AI が書いたコードを「使い捨ての VM」で動かす対話型サンドボックス

CloudShell（東京リージョン）で実行します:
  python3 sandbox.py

起動すると microVM を 1 台起動し、>>> プロンプトで microVM の中の Python と会話できます。
  >>> x = 42                     … Python をそのまま書くと microVM の中で実行される（変数は残る）
  >>> :ai フィボナッチ数列を 10 個表示して   … Amazon Bedrock にコードを書かせ、確認してから microVM で実行
  >>> :sleep / :wake             … microVM を眠らせる／起こす（メモリの中身はそのまま）
  >>> :break / :new              … わざと壊す／新しい microVM に取り替える（数秒）
  >>> :status / :vars / :help / :quit

標準ライブラリ + boto3（1.43.35 以降）だけで動きます（Python 3.9 以上）。
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from typing import Optional

try:
    import readline  # noqa: F401  入力履歴と行編集（無い環境でも動く）
except ImportError:
    pass

import boto3
from botocore.config import Config as BotoConfig
from botocore.exceptions import BotoCoreError, ClientError, UnknownServiceError

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESOURCE_FILE = os.path.join(SCRIPT_DIR, "resource-ids.env")
STATE_FILE = os.path.join(SCRIPT_DIR, ".sandbox-state.json")

# Amazon Bedrock のモデル（環境変数 DEEPCUTS_MODEL で変更可）。
# 既定は東京リージョンで直接呼べる Amazon Nova 2 Lite。jp.amazon.nova-2-lite-v1:0（東京・大阪に振り分ける推論プロファイル）も可。
DEFAULT_MODEL = os.environ.get("DEEPCUTS_MODEL", "amazon.nova-2-lite-v1:0")
SYSTEM_PROMPT = (
    "You are a Python code generator for a disposable sandbox VM.\n"
    "## Model Instructions:\n"
    "- Reply with ONLY one Python 3 code block that fulfils the user's request. DO NOT add explanations before or after it.\n"
    "- Use the standard library only. Show results with print().\n"
    "- Variables defined by earlier requests may already exist in the sandbox; reuse them when the user refers to them."
)

# 東京リージョンの単価（2026-10-28 に Price List API で取得。概算表示にだけ使う）
PRICE_VCPU_SECOND = 0.0000322421
PRICE_GB_SECOND = 0.0000042688
BASELINE_VCPU, BASELINE_GB = 0.25, 0.5  # setup.sh が minimumMemoryInMiB=512 で作る最小クラス

IDLE_SECONDS = 300          # 5 分アイドルで自動サスペンド
SUSPENDED_SECONDS = 1800    # サスペンドが 30 分続いたら自動終了
MAX_DURATION = 3600         # どうなっても 60 分で自動終了（放置対策）
APP_PORT = 8080
LIFETIME_NOTE = "5 分放置で自動サスペンド、どうなっても起動から 60 分で自動終了する設定です。"


def load_config() -> dict:
    if not os.path.exists(RESOURCE_FILE):
        sys.exit("❌ resource-ids.env が見つかりません。先に bash ./setup.sh を実行してください。")
    cfg = {}
    with open(RESOURCE_FILE, encoding="utf-8") as fh:
        for line in fh:
            if "=" in line and not line.startswith("#"):
                key, value = line.rstrip("\n").split("=", 1)
                cfg[key] = value.strip().strip('"')
    return cfg


def banner(text: str) -> None:
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(f"  {text}")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")


def with_scheme(endpoint: Optional[str]) -> Optional[str]:
    """API が返すエンドポイントにスキームが無い場合に備えて https:// を補う"""
    if endpoint and not endpoint.startswith("http"):
        return "https://" + endpoint
    return endpoint


class Sandbox:
    """microVM 1 台と、その中で動く Python サンドボックス（server.py）への窓口"""

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.region = cfg["REGION"]
        try:
            self.lmv = boto3.client("lambda-microvms", region_name=self.region)
        except UnknownServiceError:
            sys.exit("❌ この boto3 は lambda-microvms に対応していません（1.43.35 以降が必要です）。\n"
                     "   python3 -m pip install --user --upgrade boto3  を実行してから、もう一度 python3 sandbox.py を起動してください。")
        self.microvm_id: Optional[str] = None
        self.endpoint: Optional[str] = None
        self._token: Optional[str] = None
        self._token_at = 0.0
        self.running_seconds = 0.0      # 概算料金のための稼働秒数
        self._running_since: Optional[float] = None
        self.clock_before_sleep: Optional[dict] = None

    # ── ライフサイクル ──────────────────────────────────────────
    def run(self) -> int:
        """microVM を起動し、/ping が通るまでのミリ秒を返す"""
        started = time.time()
        try:
            resp = self.lmv.run_microvm(
                imageIdentifier=self.cfg["IMAGE_ARN"],
                executionRoleArn=self.cfg["EXEC_ROLE_ARN"],
                ingressNetworkConnectors=[f"arn:aws:lambda:{self.region}:aws:network-connector:aws-network-connector:ALL_INGRESS"],
                idlePolicy={"maxIdleDurationSeconds": IDLE_SECONDS, "suspendedDurationSeconds": SUSPENDED_SECONDS, "autoResumeEnabled": True},
                maximumDurationInSeconds=MAX_DURATION,
                logging={"cloudWatch": {"logGroup": self.cfg["LOG_GROUP"]}},
                runHookPayload=json.dumps({"session": "deepcuts-sandbox", "startedAt": int(started)}),
            )
        except ClientError as e:
            code = e.response["Error"].get("Code", "")
            if code == "AccessDeniedException":
                print("  ❌ run-microvm が拒否されました。実行者に lambda:RunMicrovm / lambda:PassNetworkConnector / iam:PassRole があるか確認してください。")
            elif code == "ServiceQuotaExceededException":
                print("  ❌ 同時に動かせる microVM のクォータを超えています。bash ./cleanup.sh で不要な microVM を終了してください。")
            raise
        self.microvm_id, self.endpoint = resp["microvmId"], with_scheme(resp["endpoint"])
        self._token, self._token_at = None, 0.0
        self.save_state()   # /ping を待つ前に保存（途中で Ctrl-C しても次回 restore() が拾える）
        ms = self.wait_ready()
        self._running_since = time.time()
        return ms

    def wait_ready(self, limit: float = 180) -> int:
        started = time.time()
        while time.time() - started < limit:
            status, _ = self.call("GET", "/ping", timeout=10, quiet=True)
            if status == 200:
                return int((time.time() - started) * 1000)
            time.sleep(0.5)
        raise RuntimeError("エンドポイントが応答しません（state を :status で確認してください）")

    def state(self) -> dict:
        return self.lmv.get_microvm(microvmIdentifier=self.microvm_id)

    def wait_state(self, want: str, limit: float = 120) -> bool:
        started = time.time()
        while time.time() - started < limit:
            if self.state()["state"] == want:
                return True
            time.sleep(1)
        return False

    def suspend(self) -> int:
        current = self.state()["state"]
        if current != "RUNNING":
            raise RuntimeError(f"眠らせられるのは RUNNING のときだけです（今は {current}。眠っているなら :wake）")
        status, st = self.call("GET", "/state", timeout=10, quiet=True)   # 眠る直前の時計を控えておく
        if status == 200 and st:
            self.clock_before_sleep = st.get("clock")
        self._mark_stopped()
        started = time.time()
        self.lmv.suspend_microvm(microvmIdentifier=self.microvm_id)
        self.wait_state("SUSPENDED")
        return int((time.time() - started) * 1000)

    def resume(self) -> int:
        started = time.time()
        self.lmv.resume_microvm(microvmIdentifier=self.microvm_id)
        ms = self.wait_ready()
        self._running_since = time.time()
        return ms

    def terminate(self) -> None:
        self._mark_stopped()
        if self.microvm_id:
            try:
                self.lmv.terminate_microvm(microvmIdentifier=self.microvm_id)
            except ClientError as e:
                print(f"  （終了処理で警告: {e.response['Error'].get('Code')}）")
        self.microvm_id = self.endpoint = None
        if os.path.exists(STATE_FILE):
            os.remove(STATE_FILE)

    def _mark_stopped(self) -> None:
        if self._running_since is not None:
            self.running_seconds += time.time() - self._running_since
            self._running_since = None

    def approx_cost(self) -> float:
        seconds = self.running_seconds + (time.time() - self._running_since if self._running_since else 0)
        return seconds * (BASELINE_VCPU * PRICE_VCPU_SECOND + BASELINE_GB * PRICE_GB_SECOND)

    # ── 前回の microVM を再利用 ─────────────────────────────────
    def save_state(self) -> None:
        with open(STATE_FILE, "w", encoding="utf-8") as fh:
            json.dump({"microvmId": self.microvm_id, "endpoint": self.endpoint}, fh)

    def restore(self) -> bool:
        if not os.path.exists(STATE_FILE):
            return False
        with open(STATE_FILE, encoding="utf-8") as fh:
            saved = json.load(fh)
        self.microvm_id, self.endpoint = saved.get("microvmId"), with_scheme(saved.get("endpoint"))
        try:
            st = self.state()
        except ClientError:
            st = {"state": "TERMINATED"}
        if st["state"] in ("TERMINATED", "TERMINATING"):
            reason = st.get("stateReason") or "自動終了（最長時間かサスペンド時間の上限）か、手動で終了済み"
            print(f"  前回の microVM {self.microvm_id} は終了しています（{reason}）。新しく起動します。")
            self.microvm_id = self.endpoint = None
            os.remove(STATE_FILE)
            return False
        self._running_since = time.time() if st["state"] == "RUNNING" else None
        return True

    # ── エンドポイントとの通信 ──────────────────────────────────
    def token(self) -> str:
        """認証トークン（最長 60 分）。50 分たったら取り直す"""
        if self._token is None or time.time() - self._token_at > 50 * 60:
            resp = self.lmv.create_microvm_auth_token(
                microvmIdentifier=self.microvm_id, expirationInMinutes=60, allowedPorts=[{"port": APP_PORT}])
            self._token, self._token_at = resp["authToken"]["X-aws-proxy-auth"], time.time()
        return self._token

    def call(self, method: str, path: str, body: Optional[dict] = None, timeout: float = 60, quiet: bool = False):
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(self.endpoint + path, data=data, method=method, headers={
            "X-aws-proxy-auth": self.token(),
            "X-aws-proxy-port": str(APP_PORT),
            "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if not quiet:
                print(f"  （HTTP {e.code}: {e.reason}）")
            return e.code, None
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            if not quiet:
                print(f"  （接続エラー: {e}）")
            return 0, None

    def exec_code(self, code: str) -> Optional[dict]:
        # 眠っていたら、リクエストで自動的に起きる（autoResumeEnabled）。その時間も見せる
        state = self.state()["state"]
        if state in ("SUSPENDING", "SUSPENDED"):
            print("  💤 microVM は眠っていました。リクエストを送って起こします…", end="", flush=True)
            started = time.time()
            if state == "SUSPENDING":
                self.wait_state("SUSPENDED", 30)
            self.wait_ready()
            self._running_since = time.time()
            print(f" 起きました（{int((time.time() - started) * 1000)} ms）")
        status, result = self.call("POST", "/exec", {"code": code}, timeout=120)
        return result if status == 200 else None


# ── Amazon Bedrock にコードを書かせる ──────────────────────────────
def ask_ai(region: str, request: str) -> Optional[str]:
    br = boto3.client("bedrock-runtime", region_name=region, config=BotoConfig(retries={"max_attempts": 5, "mode": "adaptive"}))
    try:
        resp = br.converse(
            modelId=DEFAULT_MODEL,
            system=[{"text": SYSTEM_PROMPT}],
            messages=[
                {"role": "user", "content": [{"text": request}]},
                # 返答の書き出しを「```python」で埋めておき、「```」で止める = コードだけを返させる定番の手
                {"role": "assistant", "content": [{"text": "```python\n"}]},
            ],
            inferenceConfig={"maxTokens": 1500, "temperature": 0.2, "stopSequences": ["```"]},
        )
    except ClientError as e:
        code = e.response["Error"].get("Code", "")
        print(f"  ❌ Bedrock を呼べませんでした（{code}: {e.response['Error'].get('Message', '')[:160]}）")
        print(f"     モデル: {DEFAULT_MODEL} / リージョン: {region}。IAM の bedrock:InvokeModel 権限と、")
        print("     環境変数 DEEPCUTS_MODEL（東京で使えるモデル ID）を確認してください。:ai 以外の機能はそのまま使えます。")
        return None
    # reasoning が有効なモデル設定では content[0] が reasoningContent になるので、text ブロックだけを連結する
    text = "".join(block["text"] for block in resp["output"]["message"]["content"] if "text" in block)
    if resp.get("stopReason") == "max_tokens":
        print("  （出力が途中で切れました。お願いを小さく分けてください）")
    match = re.search(r"```(?:python)?\n(.*?)```", text, re.S)   # フェンスが残っていたら中身だけ
    return (match.group(1) if match else text).strip("\n")


def print_result(result: Optional[dict]) -> None:
    if result is None:
        print("  （実行できませんでした。:status で microVM の状態を確認してください）")
        return
    if result.get("stdout"):
        print(result["stdout"].rstrip("\n"))
    if result.get("error"):
        print(result["error"].rstrip("\n"))


HELP = """
  Python をそのまま書く … microVM の中で実行（変数はプロセスが生きている限り残る。末尾が : の行で複数行モード、空行で確定）
  :ai <お願い>          … Amazon Bedrock にコードを書かせ、確認してから microVM で実行
  :sleep                … サスペンド（メモリとディスクを凍結。コンピュート料金が止まる）
  :wake                 … レジューム（続きから。変数と時計の変化を表示）
  :vars                 … 変数一覧・フック履歴
  :status               … 状態・稼働時間・概算料金
  :break                … わざとサンドボックスのプロセスを殺す（壊れたらどうなるか）
  :new                  … 今の microVM を捨てて、新しい 1 台をイメージから起動
  :quit                 … 終了（microVM を終了するか聞きます）
"""


def read_block(first: str) -> str:
    """末尾が : の行なら、空行まで続きを読む（複数行の def / for / if 用）"""
    lines = [first]
    if first.rstrip().endswith(":"):
        while True:
            try:
                more = input("... ")
            except EOFError:
                break
            if not more.strip():
                break
            lines.append(more)
    return "\n".join(lines)


def cmd_ai(sb: Sandbox, arg: str) -> None:
    if not arg.strip():
        print("  使い方: :ai <お願い>   例: :ai 1 から 100 までの素数を表示して")
        return
    print("  🤖 Bedrock にコードを書いてもらっています…")
    code = ask_ai(sb.region, arg.strip())
    if not code:
        return
    print("  ── AI が書いたコード ──")
    for n, l in enumerate(code.splitlines(), 1):
        print(f"  {n:3d} | {l}")
    print("  ──────────────────────")
    try:
        answer = input("  このコードを microVM の中で実行しますか？ [y/N] ").strip().lower()
    except EOFError:
        answer = "n"
    if answer == "y":
        print_result(sb.exec_code(code))
    else:
        print("  実行しませんでした")


def cmd_wake(sb: Sandbox) -> None:
    if sb.state()["state"] != "SUSPENDED":
        print(f"  眠っていません（state: {sb.state()['state']}）")
        return
    print("  ⏰ レジュームしています…", end="", flush=True)
    ms = sb.resume()
    print(f" RUNNING（/ping が返るまで {ms} ms）")
    status, st = sb.call("GET", "/state")
    if status != 200:
        return
    print(f"  変数: {st['vars']}")
    print(f"  boot_id: {st['boot_id']}（起動時のまま = 同じプロセスが続いている）")
    hooks = [h["path"].rsplit("/", 1)[-1] for h in st["hooks"]]
    print(f"  フック履歴: {hooks}")
    clock, before = st["clock"], sb.clock_before_sleep
    if before:
        wall = clock["time"] - before["time"]
        mono = clock["monotonic"] - before["monotonic"]
        print(f"  時計: 眠っていた間に、壁時計（time.time）は +{wall:.1f} 秒、単調時計（time.monotonic）は +{mono:.1f} 秒進みました")
    else:
        print(f"  時計: プロセス開始（= イメージのビルド時）から壁時計で {clock['wall_since_boot']} 秒、単調時計で {clock['monotonic_since_boot']} 秒")


def cmd_status(sb: Sandbox) -> None:
    st = sb.state()
    print(f"  microVM: {sb.microvm_id}")
    print(f"  endpoint: {sb.endpoint}")
    print(f"  state: {st['state']}" + (f"（{st['stateReason']}）" if st.get("stateReason") else ""))
    print(f"  起動: {st['startedAt']} / 最長 {st['maximumDurationInSeconds']} 秒 / idle {st.get('idlePolicy', {})}")
    running = int(sb.running_seconds + (time.time() - sb._running_since if sb._running_since else 0))
    print(f"  概算のコンピュート料金（稼働 {running} 秒）: ${sb.approx_cost():.5f}")


def handle_command(sb: Sandbox, line: str) -> bool:
    """':' で始まるコマンドを処理する。終了するときだけ True を返す"""
    cmd, _, arg = line[1:].partition(" ")
    cmd = cmd.strip().lower()
    if cmd in ("help", "h", "?"):
        print(HELP)
    elif cmd == "ai":
        cmd_ai(sb, arg)
    elif cmd == "sleep":
        print("  😴 サスペンドしています…", end="", flush=True)
        ms = sb.suspend()
        print(f" SUSPENDED（{ms} ms）。この間コンピュート料金はかかりません。:wake で起こせます")
    elif cmd == "wake":
        cmd_wake(sb)
    elif cmd == "vars":
        status, st = sb.call("GET", "/state")
        if status == 200:
            print(f"  変数: {st['vars']}")
            print(f"  実行回数: {st['exec_count']} / boot_id: {st['boot_id']}")
            for h in st["hooks"]:
                print(f"  フック {h['at']} {h['method']} {h['path']} body={json.dumps(h['body'], ensure_ascii=False)[:120]}")
    elif cmd == "status":
        cmd_status(sb)
    elif cmd == "break":
        print("  💥 サンドボックスのプロセスを殺します（microVM の中だけの出来事です）…")
        sb.exec_code("import os; os._exit(1)")
        time.sleep(2)
        status, _ = sb.call("GET", "/ping", timeout=10, quiet=True)
        print(f"  /ping → HTTP {status}（応答するプロセスがいない）。state: {sb.state()['state']}")
        print("  :new で新しい microVM に取り替えられます。あなたの CloudShell は無傷です。")
    elif cmd == "new":
        print("  🗑️  今の microVM を捨てて、新しい 1 台を起動します…", end="", flush=True)
        sb.terminate()
        ms = sb.run()
        print(f" 起動しました: {sb.microvm_id}（/ping まで {ms} ms）")
    elif cmd in ("quit", "exit", "q"):
        try:
            answer = input("  microVM を終了しますか？（n なら次回 sandbox.py が再利用します）[Y/n] ").strip().lower()
        except EOFError:
            answer = "y"
        if answer != "n":
            sb.terminate()
            print("  終了しました。後片付けは bash ./cleanup.sh で行ってください。")
        else:
            print(f"  microVM は残しています（{LIFETIME_NOTE} 概算 ${sb.approx_cost():.5f}）")
        return True
    else:
        print(f"  不明なコマンド :{cmd}（:help で一覧）")
    return False


def main() -> None:
    cfg = load_config()
    sb = Sandbox(cfg)
    print()
    banner("AWS Deep Cuts - Lambda MicroVMs サンドボックス")
    print(f"  リージョン: {sb.region} / イメージ: {cfg['IMAGE_NAME']} / AI モデル: {DEFAULT_MODEL}")
    print()
    try:
        if sb.restore():
            print(f"  前回の microVM を再利用します: {sb.microvm_id}（state: {sb.state()['state']}）")
        else:
            print("  microVM を起動しています（イメージ = 起動済みのメモリとディスクのスナップショット からの復元）…")
            ms = sb.run()
            print(f"  起動しました: {sb.microvm_id}")
            print(f"  /ping が返るまで {ms} ms。アプリの初期化は済んだ状態から始まっています。")
    except KeyboardInterrupt:
        if sb.microvm_id:
            print(f"\n  中断しました。microVM {sb.microvm_id} は起動中です（次回の sandbox.py が再利用します）。")
        sys.exit(1)
    except (ClientError, BotoCoreError) as e:
        sys.exit(f"❌ microVM を起動できませんでした: {e}")
    print(f"  endpoint: {sb.endpoint}")
    print(f"  {LIFETIME_NOTE} :help でコマンド一覧。")
    print()

    while True:
        try:
            line = input(">>> ")
        except (EOFError, KeyboardInterrupt):
            print()
            line = ":quit"
        if not line.strip():
            continue

        try:
            if line.startswith(":"):
                if handle_command(sb, line):
                    break
            else:
                print_result(sb.exec_code(read_block(line)))
        except ClientError as e:
            err = e.response["Error"]
            print(f"  ❌ AWS API エラー: {err.get('Code')}: {err.get('Message', '')[:200]}")
            print("  （:status で状態を確認してください。眠っている microVM にもう一度 :sleep はできません）")
        except BotoCoreError as e:
            print(f"  ❌ AWS SDK エラー: {e}")
        except (RuntimeError, OSError) as e:
            print(f"  ❌ {e}")


if __name__ == "__main__":
    main()
