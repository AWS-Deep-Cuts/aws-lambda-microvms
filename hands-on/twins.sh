#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# 観点（発展）: 同じスナップショットから復元した 2 台の microVM は、同じ乱数を出すか
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

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Lambda MicroVMs: 双子の microVM と乱数"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "[1/3] 同じイメージから microVM を 2 台起動..."
declare -a IDS=() ENDPOINTS=() TOKENS=()
for i in 1 2; do
  RUN_JSON=$(aws lambda-microvms run-microvm --region "${REGION}" --image-identifier "${IMAGE_ARN}" \
    --execution-role-arn "${EXEC_ROLE_ARN}" --ingress-network-connectors "${INGRESS_CONNECTOR}" --maximum-duration-in-seconds 600 --output json)
  IDS[i]=$(echo "${RUN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["microvmId"])')
  ENDPOINTS[i]=$(echo "${RUN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["endpoint"])')
  echo "  #${i}: ${IDS[i]}"
done
for i in 1 2; do
  TOKENS[i]=$(create_app_token "${IDS[i]}")
  wait_ping_ms "${ENDPOINTS[i]}" "${TOKENS[i]}" 180 >/dev/null || { echo "❌ Error: #${i} が応答しません。" >&2; exit 1; }
done
echo ""

echo "[2/3] それぞれの /random を 1 回ずつ取得..."
R1=$(app_call "${ENDPOINTS[1]}" "${TOKENS[1]}" GET /random)
R2=$(app_call "${ENDPOINTS[2]}" "${TOKENS[2]}" GET /random)
python3 - "${R1}" "${R2}" <<'EOF' | tee -a /dev/stderr >/dev/null
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print(f"  {'項目':<16} {'#1':<36} {'#2':<36} 一致?")
for key in ("boot_id", "random_random", "os_urandom_hex", "uuid4"):
    print(f"  {key:<16} {str(a[key]):<36} {str(b[key]):<36} {'★一致' if a[key] == b[key] else '不一致'}")
EOF
{
  echo "## twins.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) (${REGION})"
  echo ""
  echo '```json'
  echo "${R1}"
  echo "${R2}"
  echo '```'
  echo ""
} >> "${RESULTS}"
echo ""

echo "[3/3] 2 台を終了..."
for i in 1 2; do
  aws lambda-microvms terminate-microvm --microvm-identifier "${IDS[i]}" --region "${REGION}"
done
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 双子の microVM の比較が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
