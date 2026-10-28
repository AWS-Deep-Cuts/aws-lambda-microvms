#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# 観点 2〜4: 起動時間、サスペンド／レジュームで状態が残ること、眠っている間の時計
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"
readonly RESULTS="${SCRIPT_DIR}/output/results.md"
[[ -f "${RESOURCE_FILE}" ]] || { echo "❌ Error: ${RESOURCE_FILE} が見つかりません。先に bash ./setup.sh を実行してください。" >&2; exit 1; }
# shellcheck source=/dev/null
source "${RESOURCE_FILE}"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
mkdir -p "${SCRIPT_DIR}/output"

# エンドポイント経由でアプリのポートに届くようにするネットワークコネクタ（Lambda 管理）
readonly INGRESS_CONNECTOR="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Lambda MicroVMs: サスペンド／レジューム"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/6] 起動 ─────────────────────────────────────────────────
echo "[1/6] microVM を起動（イメージ = 起動済みスナップショット からの復元）..."
T0=$(now_ms)
RUN_JSON=$(aws lambda-microvms run-microvm --region "${REGION}" \
  --image-identifier "${IMAGE_ARN}" \
  --execution-role-arn "${EXEC_ROLE_ARN}" \
  --ingress-network-connectors "${INGRESS_CONNECTOR}" \
  --maximum-duration-in-seconds 900 \
  --logging "{\"cloudWatch\":{\"logGroup\":\"${LOG_GROUP}\"}}" \
  --run-hook-payload '{"session":"deepcuts-run","note":"delivered to the /run hook"}' \
  --output json)
MICROVM_ID=$(echo "${RUN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["microvmId"])')
ENDPOINT=$(echo "${RUN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["endpoint"])')
echo "  microVM: ${MICROVM_ID}"
echo "  endpoint: ${ENDPOINT}"
echo "  （最長 900 秒で自動終了するように起動しています）"
TOKEN=$(create_app_token "${MICROVM_ID}")
COLD_MS=$(wait_ping_ms "${ENDPOINT}" "${TOKEN}" 180) || { echo "❌ Error: エンドポイントが応答しません。" >&2; exit 1; }
TOTAL_MS=$(( $(now_ms) - T0 ))
echo "  /ping が 200 を返すまで: ${COLD_MS} ms（run-microvm の呼び出しからは ${TOTAL_MS} ms）"
echo "  state: $(microvm_state "${MICROVM_ID}")"
echo ""

# ─── [2/6] 状態を作る ───────────────────────────────────────────
echo "[2/6] microVM の中で Python を実行し、変数を定義..."
app_exec "${ENDPOINT}" "${TOKEN}" 'import time, os
secret = 42
born = time.time()
print("secret =", secret, "/ pid =", os.getpid())' | python3 -c 'import json,sys; r=json.load(sys.stdin); print("  stdout:", r["stdout"].strip()); print("  vars:", r["vars"])'
echo "  /run フックに届いたペイロード:"
app_call "${ENDPOINT}" "${TOKEN}" GET /state | python3 -c 'import json,sys; r=json.load(sys.stdin); [print("   ", h["at"], h["method"], h["path"], h["body"]) for h in r["hooks"]]; print("  boot_id:", r["boot_id"])'
BOOT_ID_BEFORE=$(app_call "${ENDPOINT}" "${TOKEN}" GET /ping | python3 -c 'import json,sys; print(json.load(sys.stdin)["boot_id"])')
echo "  8080 番だけを許可したトークンで、フック用の 9000 番にアクセスしてみる..."
CODE_WRONG_PORT=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${ENDPOINT}/state" \
  -H "X-aws-proxy-auth: ${TOKEN}" -H "X-aws-proxy-port: ${HOOK_PORT}" || echo "000")
echo "  → HTTP ${CODE_WRONG_PORT}（トークンの allowedPorts に無いポートは、アプリに届く前にプロキシで止まる）"
echo "  egress コネクタを付けずに起動した microVM から、インターネットに出られるか..."
EGRESS_RESULT=$(app_exec "${ENDPOINT}" "${TOKEN}" 'import urllib.request
try:
    print("reachable:", urllib.request.urlopen("https://checkip.amazonaws.com", timeout=5).read().decode().strip())
except Exception as e:
    print("unreachable:", type(e).__name__, str(e)[:80])' | python3 -c 'import json,sys; r=json.load(sys.stdin); print((r["stdout"] or r["error"] or "").strip().splitlines()[-1])')
echo "  → ${EGRESS_RESULT}"
CLOCK_BEFORE=$(app_call "${ENDPOINT}" "${TOKEN}" GET /clock)
echo ""

# ─── [3/6] サスペンド ───────────────────────────────────────────
echo "[3/6] サスペンド（メモリとディスクの状態を保ったまま停止）..."
T1=$(now_ms)
aws lambda-microvms suspend-microvm --microvm-identifier "${MICROVM_ID}" --region "${REGION}"
wait_state "${MICROVM_ID}" SUSPENDED 120
SUSPEND_MS=$(( $(now_ms) - T1 ))
echo "  SUSPENDED まで: ${SUSPEND_MS} ms"
CODE_WHILE_SUSPENDED=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${ENDPOINT}/ping" \
  -H "X-aws-proxy-auth: ${TOKEN}" -H "X-aws-proxy-port: ${APP_PORT}" || echo "000")
echo "  サスペンド中に /ping を叩いたときの HTTP ステータス: ${CODE_WHILE_SUSPENDED}（autoResumeEnabled を付けていないので起きない）"
echo "  10 秒眠らせます..."
sleep 10
echo ""

# ─── [4/6] レジューム ───────────────────────────────────────────
echo "[4/6] レジューム..."
T2=$(now_ms)
aws lambda-microvms resume-microvm --microvm-identifier "${MICROVM_ID}" --region "${REGION}"
RESUME_MS=$(wait_ping_ms "${ENDPOINT}" "${TOKEN}" 180) || { echo "❌ Error: レジューム後にエンドポイントが応答しません。" >&2; exit 1; }
RESUME_TOTAL_MS=$(( $(now_ms) - T2 ))
echo "  /ping が 200 を返すまで: ${RESUME_MS} ms（resume-microvm の呼び出しからは ${RESUME_TOTAL_MS} ms）"
STATE_JSON=$(app_call "${ENDPOINT}" "${TOKEN}" GET /state)
echo "${STATE_JSON}" | python3 -c '
import json, sys
r = json.load(sys.stdin)
print("  vars after resume:", r["vars"])
print("  boot_id after resume:", r["boot_id"])
print("  hooks:")
for h in r["hooks"]:
    print("   ", h["at"], h["method"], h["path"])
'
BOOT_ID_AFTER=$(echo "${STATE_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["boot_id"])')
CLOCK_AFTER=$(app_call "${ENDPOINT}" "${TOKEN}" GET /clock)
python3 - "${CLOCK_BEFORE}" "${CLOCK_AFTER}" <<'EOF'
import json, sys
b, a = json.loads(sys.argv[1]), json.loads(sys.argv[2])
wall = a["time"] - b["time"]
mono = a["monotonic"] - b["monotonic"]
print(f"  眠る前後の経過: 壁時計 time.time() = {wall:.1f} 秒 / 単調時計 time.monotonic() = {mono:.1f} 秒")
print("  → 差がサスペンド時間ぶんあれば、ゲストの壁時計はレジューム時に補正され、単調時計は止まっていたことになります")
EOF
echo ""

# ─── [5/6] 結果を記録 ───────────────────────────────────────────
echo "[5/6] 結果を output/results.md に記録..."
{
  echo "## run.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) (${REGION})"
  echo ""
  echo "| 項目 | 値 |"
  echo "| --- | --- |"
  echo "| run-microvm → /ping 200 | ${COLD_MS} ms（API 呼び出し込み ${TOTAL_MS} ms） |"
  echo "| suspend-microvm → SUSPENDED | ${SUSPEND_MS} ms |"
  echo "| サスペンド中の /ping | HTTP ${CODE_WHILE_SUSPENDED} |"
  echo "| resume-microvm → /ping 200 | ${RESUME_MS} ms（API 呼び出し込み ${RESUME_TOTAL_MS} ms） |"
  echo "| egress コネクタ無しでのインターネット到達 | ${EGRESS_RESULT} |"
  echo "| 8080 用トークンで 9000 番へ | HTTP ${CODE_WRONG_PORT} |"
  echo "| boot_id 前後 | ${BOOT_ID_BEFORE} → ${BOOT_ID_AFTER} |"
  echo ""
} >> "${RESULTS}"
echo "  追記しました"
echo ""

# ─── [6/6] 終了 ─────────────────────────────────────────────────
echo "[6/6] microVM を終了..."
aws lambda-microvms terminate-microvm --microvm-identifier "${MICROVM_ID}" --region "${REGION}"
echo "  terminate-microvm を呼びました（state: $(microvm_state "${MICROVM_ID}")）"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ サスペンド／レジュームの確認が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "次のステップ: bash ./idle.sh（アイドルポリシーによる自動サスペンド／自動レジューム）"
