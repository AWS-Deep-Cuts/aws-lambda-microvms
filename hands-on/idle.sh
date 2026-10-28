#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# 観点 5: アイドルポリシー（60 秒アイドルで自動サスペンド、リクエストが来たら自動レジューム）
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
readonly INGRESS_CONNECTOR="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"
readonly IDLE_SECONDS=60

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Lambda MicroVMs: アイドルポリシー"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "[1/4] アイドルポリシー付きで起動（${IDLE_SECONDS} 秒アイドルで自動サスペンド、自動レジューム有効、サスペンド 600 秒で自動終了）..."
RUN_JSON=$(aws lambda-microvms run-microvm --region "${REGION}" \
  --image-identifier "${IMAGE_ARN}" \
  --execution-role-arn "${EXEC_ROLE_ARN}" \
  --ingress-network-connectors "${INGRESS_CONNECTOR}" \
  --maximum-duration-in-seconds 900 \
  --idle-policy "maxIdleDurationSeconds=${IDLE_SECONDS},suspendedDurationSeconds=600,autoResumeEnabled=true" \
  --logging "{\"cloudWatch\":{\"logGroup\":\"${LOG_GROUP}\"}}" \
  --output json)
MICROVM_ID=$(echo "${RUN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["microvmId"])')
ENDPOINT=$(echo "${RUN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["endpoint"])')
TOKEN=$(create_app_token "${MICROVM_ID}")
wait_ping_ms "${ENDPOINT}" "${TOKEN}" 180 >/dev/null || { echo "❌ Error: エンドポイントが応答しません。" >&2; exit 1; }
app_exec "${ENDPOINT}" "${TOKEN}" 'counter = 1
print("counter =", counter)' >/dev/null
echo "  microVM: ${MICROVM_ID}（counter = 1 を定義しました）"
echo ""

echo "[2/4] 何もせずに待ち、状態が SUSPENDED になるまでを観察（最大 ${IDLE_SECONDS}+180 秒）..."
LAST_REQUEST=$(date +%s)
STATE="RUNNING"
while (( $(date +%s) - LAST_REQUEST < IDLE_SECONDS + 180 )); do
  STATE=$(microvm_state "${MICROVM_ID}")
  printf '  +%3d s: %s\n' "$(( $(date +%s) - LAST_REQUEST ))" "${STATE}"
  [[ "${STATE}" == "SUSPENDED" ]] && break
  sleep 10
done
if [[ "${STATE}" != "SUSPENDED" ]]; then
  echo "  ⚠️  自動サスペンドを確認できませんでした（現在: ${STATE}）。get-microvm の state は結果整合なので、少し待って再確認してください。"
fi
IDLE_TO_SUSPENDED=$(( $(date +%s) - LAST_REQUEST ))
echo ""

echo "[3/4] サスペンド中のエンドポイントにリクエストを送る（自動レジューム）..."
T0=$(now_ms)
AUTO_RESUME_MS=$(wait_ping_ms "${ENDPOINT}" "${TOKEN}" 180) || { echo "❌ Error: 自動レジュームしませんでした。" >&2; exit 1; }
echo "  最初の /ping が 200 を返すまで: ${AUTO_RESUME_MS} ms（呼び出し開始から $(( $(now_ms) - T0 )) ms）"
app_call "${ENDPOINT}" "${TOKEN}" GET /state | python3 -c 'import json,sys; r=json.load(sys.stdin); print("  vars:", r["vars"]); print("  state after request:", end=" ")'
microvm_state "${MICROVM_ID}"
{
  echo "## idle.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) (${REGION})"
  echo ""
  echo "| 項目 | 値 |"
  echo "| --- | --- |"
  echo "| maxIdleDurationSeconds | ${IDLE_SECONDS} |"
  echo "| 最後のリクエスト → SUSPENDED を観測 | 約 ${IDLE_TO_SUSPENDED} 秒 |"
  echo "| 自動レジューム（最初の /ping 200 まで） | ${AUTO_RESUME_MS} ms |"
  echo ""
} >> "${RESULTS}"
echo ""

echo "[4/4] microVM を終了..."
aws lambda-microvms terminate-microvm --microvm-identifier "${MICROVM_ID}" --region "${REGION}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ アイドルポリシーの確認が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
