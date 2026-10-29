#!/usr/bin/env python3
"""AWS Deep Cuts - Lambda MicroVMs: AI が生成したコードを MicroVM の中で実行する対話型のツール

README の手順 7 で使います。CloudShell（東京リージョン）の hands-on ディレクトリで実行します:
  python3 sandbox.py

起動すると、手順 2 で作成した MicroVM イメージから MicroVM を 1 台起動します。
>>> に Python のコードを入力すると、MicroVM の中の server.py に POST /exec で送って実行します。
  >>> x = 42                     … MicroVM の中で実行する（変数は次の入力でも使える）
  >>> :ai 1 から 100 までの素数を表示して   … Amazon Bedrock でコードを生成し、確認してから MicroVM で実行する
  >>> :suspend / :resume         … MicroVM をサスペンドする / レジュームする（メモリの内容は残る）
  >>> :break / :new              … server.py のプロセスを終了させる / 新しい MicroVM に取り替える
  >>> :status / :vars / :help / :quit

内部で呼び出す API は、README の手順 3〜6 で実行した CLI のコマンドと同じです（RunMicrovm、GetMicrovm、
CreateMicrovmAuthToken、SuspendMicrovm、ResumeMicrovm、TerminateMicrovm）。呼び出すたびに「→ API 名」を表示します。
Python の標準ライブラリと boto3 だけで動きます。boto3 は 1.43.35 以降が必要で、boto3 の 1.43 系は Python 3.10 以上で動きます。
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
# 既定は東京リージョンで直接呼び出せる Amazon Nova 2 Lite。jp.amazon.nova-2-lite-v1:0（東京・大阪に振り分ける推論プロファイル）も可。
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
BASELINE_VCPU, BASELINE_GB = 0.25, 0.5  # README の手順 2-4 で、--resources に minimumMemoryInMiB=512 を指定して作成したイメージのベースライン

IDLE_SECONDS = 300          # 5 分アイドルで自動サスペンド
SUSPENDED_SECONDS = 1800    # サスペンドが 30 分続いたら自動終了
MAX_DURATION = 3600         # どうなっても 60 分で自動終了（放置対策）
APP_PORT = 8080
LIFETIME_NOTE = "5 分間リクエストが無いと自動でサスペンドし、起動から 60 分で自動で終了する設定です。"


def load_config() -> dict:
    if not os.path.exists(RESOURCE_FILE):
        sys.exit("❌ resource-ids.env が見つかりません。hands-on ディレクトリで実行しているか、setup.sh を実行したかを確認してください。")
    cfg = {}
    with open(RESOURCE_FILE, encoding="utf-8") as fh:
        for line in fh:
            if "=" in line and not line.startswith("#"):
                key, value = line.rstrip("\n").split("=", 1)
                cfg[key] = value.strip().strip('"')
    return cfg


def show_api(text: str) -> None:
    """内部で呼び出した API を 1 行で表示する（README の CLI の手順と対応づけるため）"""
    print(f"  → {text}")


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
    """MicroVM 1 台と、その中で動く server.py を操作する"""

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.region = cfg["REGION"]
        try:
            self.lmv = boto3.client("lambda-microvms", region_name=self.region)
        except UnknownServiceError:
            sys.exit("❌ この boto3 は lambda-microvms に対応していません（1.43.35 以降が必要です）。\n"
                     "   python3 -m pip install --user --upgrade boto3 を実行してから、もう一度 python3 sandbox.py を起動してください。")
        self.image_arn = cfg.get("IMAGE_ARN") or self._find_image(cfg.get("IMAGE_NAME", "aws-deepcuts-sandbox"))
        self.microvm_id: Optional[str] = None
        self.endpoint: Optional[str] = None
        self._token: Optional[str] = None
        self._token_at = 0.0
        self.running_seconds = 0.0      # 概算料金のための稼働秒数
        self._running_since: Optional[float] = None

    def _find_image(self, name: str) -> str:
        """resource-ids.env に IMAGE_ARN が無いときは、名前で MicroVM イメージを探す"""
        for item in self.lmv.list_microvm_images().get("items", []):
            if item.get("name") == name and item.get("state") in ("CREATED", "UPDATED"):
                return item["imageArn"]
        sys.exit(f"❌ MicroVM イメージ {name} が見つかりません。README の手順 2 でイメージを作成してから実行してください。")

    # ── ライフサイクル ──────────────────────────────────────────
    def run(self) -> int:
        """MicroVM を起動し、/ping に応答するまでのミリ秒を返す"""
        started = time.time()
        show_api(f"RunMicrovm（イメージ {self.cfg.get('IMAGE_NAME', '')}）")
        try:
            resp = self.lmv.run_microvm(
                imageIdentifier=self.image_arn,
                executionRoleArn=self.cfg["EXEC_ROLE_ARN"],
                ingressNetworkConnectors=[f"arn:aws:lambda:{self.region}:aws:network-connector:aws-network-connector:ALL_INGRESS"],
                idlePolicy={"maxIdleDurationSeconds": IDLE_SECONDS, "suspendedDurationSeconds": SUSPENDED_SECONDS, "autoResumeEnabled": True},
                maximumDurationInSeconds=MAX_DURATION,
                logging={"cloudWatch": {"logGroup": self.cfg["LOG_GROUP"]}},
                runHookPayload=json.dumps({"user": "sandbox.py", "startedAt": int(started)}),
            )
        except ClientError as e:
            code = e.response["Error"].get("Code", "")
            if code == "AccessDeniedException":
                print("  ❌ RunMicrovm が拒否されました。lambda:RunMicrovm・lambda:PassNetworkConnector・iam:PassRole の権限を確認してください。")
            elif code == "ServiceQuotaExceededException":
                print("  ❌ 同時に動かせる MicroVM のクォータを超えています。不要な MicroVM を終了してください。")
            raise
        self.microvm_id, self.endpoint = resp["microvmId"], with_scheme(resp["endpoint"])
        self._token, self._token_at = None, 0.0
        self.save_state()   # /ping を待つ前に保存（途中で Ctrl-C しても次回 restore() が拾える）
        # 認証トークンは RUNNING の MicroVM にしか発行できないため、先に RUNNING になるのを待つ
        show_api("GetMicrovm（状態が RUNNING になるのを待つ）")
        if not self.wait_state("RUNNING", 180):
            raise RuntimeError("MicroVM が RUNNING になりません（:status で状態を確認してください）")
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
            raise RuntimeError(f"サスペンドできるのは RUNNING のときだけです。今の状態は {current} です（サスペンド中なら :resume）")
        self._mark_stopped()
        started = time.time()
        show_api("SuspendMicrovm")
        self.lmv.suspend_microvm(microvmIdentifier=self.microvm_id)
        self.wait_state("SUSPENDED")
        return int((time.time() - started) * 1000)

    def resume(self) -> int:
        show_api("ResumeMicrovm")
        self.lmv.resume_microvm(microvmIdentifier=self.microvm_id)
        ms = self.wait_ready()
        self._running_since = time.time()
        return ms

    def terminate(self) -> None:
        self._mark_stopped()
        if self.microvm_id:
            show_api("TerminateMicrovm")
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

    # ── 前回の MicroVM を再利用 ─────────────────────────────────
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
            reason = st.get("stateReason") or "最長時間の経過などで自動で終了したか、手動で終了しました"
            print(f"  前回の MicroVM {self.microvm_id} は終了しています（{reason}）。新しく起動します。")
            self.microvm_id = self.endpoint = None
            os.remove(STATE_FILE)
            return False
        self._running_since = time.time() if st["state"] == "RUNNING" else None
        return True

    # ── エンドポイントとの通信 ──────────────────────────────────
    def token(self) -> str:
        """認証トークン（最長 60 分）。50 分たったら取り直す"""
        if self._token is None or time.time() - self._token_at > 50 * 60:
            show_api(f"CreateMicrovmAuthToken（ポート {APP_PORT}、有効期限 60 分）")
            for attempt in range(10):
                try:
                    resp = self.lmv.create_microvm_auth_token(
                        microvmIdentifier=self.microvm_id, expirationInMinutes=60, allowedPorts=[{"port": APP_PORT}])
                    break
                except ClientError as e:
                    # 起動の直後は ConflictException が返ることがあるため、1 秒おきに再試行する
                    if e.response["Error"].get("Code") != "ConflictException" or attempt == 9:
                        raise
                    time.sleep(1)
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
                print(f"  HTTP {e.code}: {e.reason}")
            return e.code, None
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            if not quiet:
                print(f"  接続エラー: {e}")
            return 0, None

    def exec_code(self, code: str) -> Optional[dict]:
        # サスペンド中なら、リクエストを送ると自動でレジュームする（autoResumeEnabled）。かかった時間も表示する
        state = self.state()["state"]
        if state in ("SUSPENDING", "SUSPENDED"):
            print("  MicroVM はサスペンド中でした。リクエストを送ると、自動でレジュームします…", end="", flush=True)
            started = time.time()
            if state == "SUSPENDING":
                self.wait_state("SUSPENDED", 30)
            self.wait_ready()
            self._running_since = time.time()
            print(f" レジュームしました（{int((time.time() - started) * 1000)} ms）")
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
                # 返答の書き出しを「```python」にしておき、「```」で生成を止める。コードだけを返させるための指定
                {"role": "assistant", "content": [{"text": "```python\n"}]},
            ],
            inferenceConfig={"maxTokens": 1500, "temperature": 0.2, "stopSequences": ["```"]},
        )
    except ClientError as e:
        code = e.response["Error"].get("Code", "")
        print(f"  ❌ Bedrock を呼び出せませんでした（{code}: {e.response['Error'].get('Message', '')[:160]}）")
        print(f"     モデル: {DEFAULT_MODEL} / リージョン: {region}。IAM の bedrock:InvokeModel 権限と、")
        print("     環境変数 DEEPCUTS_MODEL（東京で使えるモデル ID）を確認してください。:ai 以外の機能はそのまま使えます。")
        return None
    # reasoning が有効なモデル設定では content[0] が reasoningContent になるので、text ブロックだけを連結する
    text = "".join(block["text"] for block in resp["output"]["message"]["content"] if "text" in block)
    if resp.get("stopReason") == "max_tokens":
        print("  （出力が途中で切れました。依頼を小さく分けてください）")
    match = re.search(r"```(?:python)?\n(.*?)```", text, re.S)   # フェンスが残っていたら中身だけ
    return (match.group(1) if match else text).strip("\n")


def print_result(result: Optional[dict]) -> None:
    if result is None:
        print("  実行できませんでした。:status で MicroVM の状態を確認してください。")
        return
    if result.get("stdout"):
        print(result["stdout"].rstrip("\n"))
    if result.get("error"):
        print(result["error"].rstrip("\n"))


HELP = """
  Python のコードを入力 … MicroVM の中で実行する（変数は次の入力でも使える。末尾が : の行のあとは、空行まで続けて入力）
  :ai <依頼>            … Amazon Bedrock でコードを生成し、確認してから MicroVM で実行する
  :suspend              … MicroVM をサスペンドする（メモリとディスクを保存し、vCPU とメモリの料金が止まる）
  :resume               … MicroVM をレジュームする（変数・boot_id・フックの履歴を表示する）
  :vars                 … 変数の一覧とフックの履歴
  :status               … MicroVM の状態・稼働時間・概算の料金
  :break                … server.py のプロセスを終了させる（アプリが止まったときにどうなるかを確かめる）
  :new                  … 今の MicroVM を終了し、イメージから新しい MicroVM を起動する
  :quit                 … 終了する（MicroVM を終了するか確認します）
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
        print("  使い方: :ai <依頼>   例: :ai 1 から 100 までの素数を表示して")
        return
    show_api(f"Amazon Bedrock の Converse API（モデル {DEFAULT_MODEL}）でコードを生成しています…")
    code = ask_ai(sb.region, arg.strip())
    if not code:
        return
    print("  ── AI が生成したコード ──")
    for n, l in enumerate(code.splitlines(), 1):
        print(f"  {n:3d} | {l}")
    print("  ──────────────────────")
    try:
        answer = input("  このコードを MicroVM の中で実行しますか？ [y/N] ").strip().lower()
    except EOFError:
        answer = "n"
    if answer == "y":
        show_api("POST /exec（MicroVM の中の server.py に送って実行する）")
        print_result(sb.exec_code(code))
    else:
        print("  実行しませんでした")


def cmd_resume(sb: Sandbox) -> None:
    if sb.state()["state"] != "SUSPENDED":
        print(f"  サスペンド中ではありません（state: {sb.state()['state']}）")
        return
    print("  レジュームしています…", end="", flush=True)
    ms = sb.resume()
    print(f" RUNNING（/ping が返るまで {ms} ms）")
    status, st = sb.call("GET", "/state")
    if status != 200:
        return
    print(f"  変数: {st['vars']}")
    print(f"  boot_id: {st['boot_id']}（サスペンドの前と同じであれば、同じプロセスが動き続けています）")
    hooks = [h["path"].rsplit("/", 1)[-1] for h in st["hooks"]]
    print(f"  フックの履歴: {hooks}")


def cmd_status(sb: Sandbox) -> None:
    st = sb.state()
    print(f"  MicroVM: {sb.microvm_id}")
    print(f"  endpoint: {sb.endpoint}")
    print(f"  state: {st['state']}" + (f"（{st['stateReason']}）" if st.get("stateReason") else ""))
    print(f"  起動: {st['startedAt']} / 最長 {st['maximumDurationInSeconds']} 秒 / idle {st.get('idlePolicy', {})}")
    running = int(sb.running_seconds + (time.time() - sb._running_since if sb._running_since else 0))
    print(f"  概算の料金（稼働 {running} 秒、ベースラインの単価で計算）: ${sb.approx_cost():.5f}")


def handle_command(sb: Sandbox, line: str) -> bool:
    """':' で始まるコマンドを処理する。終了するときだけ True を返す"""
    cmd, _, arg = line[1:].partition(" ")
    cmd = cmd.strip().lower()
    if cmd in ("help", "h", "?"):
        print(HELP)
    elif cmd == "ai":
        cmd_ai(sb, arg)
    elif cmd in ("suspend", "sleep"):
        print("  サスペンドしています…", end="", flush=True)
        ms = sb.suspend()
        print(f" SUSPENDED（{ms} ms）。この間は vCPU とメモリの料金がかかりません。:resume でレジュームします")
    elif cmd in ("resume", "wake"):
        cmd_resume(sb)
    elif cmd == "vars":
        status, st = sb.call("GET", "/state")
        if status == 200:
            print(f"  変数: {st['vars']}")
            print(f"  実行回数: {st['exec_count']} / boot_id: {st['boot_id']}")
            for h in st["hooks"]:
                print(f"  フック {h['at']} {h['path']} body={json.dumps(h['body'], ensure_ascii=False)[:120]}")
    elif cmd == "status":
        cmd_status(sb)
    elif cmd == "break":
        print("  server.py のプロセスを終了させます。CloudShell には影響しません…")
        sb.exec_code("import os; os._exit(1)")
        time.sleep(2)
        status, _ = sb.call("GET", "/ping", timeout=10, quiet=True)
        print(f"  /ping → HTTP {status}（応答するプロセスがありません）。MicroVM の state: {sb.state()['state']}")
        print("  :new で新しい MicroVM に取り替えられます。CloudShell には影響がありません。")
    elif cmd == "new":
        print("  今の MicroVM を終了し、イメージから新しい MicroVM を起動します…", end="", flush=True)
        sb.terminate()
        ms = sb.run()
        print(f" 起動しました: {sb.microvm_id}（/ping まで {ms} ms）")
    elif cmd in ("quit", "exit", "q"):
        try:
            answer = input("  MicroVM を終了しますか？ n を選ぶと、次に sandbox.py を起動したときに再利用します [Y/n] ").strip().lower()
        except EOFError:
            answer = "y"
        if answer != "n":
            sb.terminate()
            print("  MicroVM を終了しました。後片付けは README の手順 8 で行います。")
        else:
            print(f"  MicroVM は終了していません。{LIFETIME_NOTE} 概算の料金: ${sb.approx_cost():.5f}")
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
            print(f"  前回の MicroVM を再利用します: {sb.microvm_id}（state: {sb.state()['state']}）")
        else:
            print("  MicroVM を起動しています。イメージのスナップショットから復元します…")
            ms = sb.run()
            print(f"  起動しました: {sb.microvm_id}")
            print(f"  /ping に応答するまで {ms} ms。server.py はイメージの作成時に起動済みです。")
    except KeyboardInterrupt:
        if sb.microvm_id:
            print(f"\n  中断しました。MicroVM {sb.microvm_id} は起動しています。次に sandbox.py を起動したときに再利用します。")
        sys.exit(1)
    except (ClientError, BotoCoreError) as e:
        sys.exit(f"❌ MicroVM を起動できませんでした: {e}")
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
            print("  :status で MicroVM の状態を確認してください。")
        except BotoCoreError as e:
            print(f"  ❌ AWS SDK エラー: {e}")
        except (RuntimeError, OSError) as e:
            print(f"  ❌ {e}")


if __name__ == "__main__":
    main()
