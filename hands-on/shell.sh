#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# 観点 7（発展）: シェルで microVM の中に入り、アプリが「microVM の中のコンテナ」として動いているのを見る
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"
[[ -f "${RESOURCE_FILE}" ]] || { echo "❌ Error: ${RESOURCE_FILE} が見つかりません。先に bash ./setup.sh を実行してください。" >&2; exit 1; }
# shellcheck source=/dev/null
source "${RESOURCE_FILE}"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
readonly CONNECTOR_PREFIX="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Lambda MicroVMs: シェル接続"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "[1/3] SHELL_INGRESS 付きで microVM を起動（最長 30 分で自動終了）..."
RUN_JSON=$(aws lambda-microvms run-microvm --region "${REGION}" \
  --image-identifier "${IMAGE_ARN}" \
  --execution-role-arn "${EXEC_ROLE_ARN}" \
  --ingress-network-connectors "${CONNECTOR_PREFIX}:HTTP_INGRESS" "${CONNECTOR_PREFIX}:SHELL_INGRESS" \
  --maximum-duration-in-seconds 1800 \
  --output json)
MICROVM_ID=$(echo "${RUN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["microvmId"])')
ENDPOINT=$(echo "${RUN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["endpoint"])')
wait_state "${MICROVM_ID}" RUNNING 180
echo "  microVM: ${MICROVM_ID}"
echo "  endpoint: ${ENDPOINT}"
echo ""

echo "[2/3] シェル用の認証トークンが発行できることを確認（1 分有効の使い捨て）..."
aws lambda-microvms create-microvm-shell-auth-token --microvm-identifier "${MICROVM_ID}" \
  --expiration-in-minutes 1 --region "${REGION}" --query 'keys(authToken)' --output text | sed 's/^/  ヘッダー名: /'
echo "  （接続に使うトークンは、接続する直前に (b) のコマンドで発行してください。トークンは秘密情報です）"
echo ""

echo "[3/3] 接続方法"
echo ""
echo "  (a) マネジメントコンソール: Lambda → MicroVMs → ${MICROVM_ID} → 「Connect」"
echo ""
echo "  (b) websocat がある環境（ローカル PC など）から:"
echo "      websocat \"wss://${ENDPOINT#https://}/shell\" \\"
echo "        -H \"Sec-WebSocket-Protocol: lambda-microvms.authentication.\${SHELL_TOKEN}, lambda-microvms\""
echo "      （SHELL_TOKEN は次のコマンドで発行します。15 分で失効します）"
echo "      SHELL_TOKEN=\$(aws lambda-microvms create-microvm-shell-auth-token --microvm-identifier ${MICROVM_ID} \\"
echo "        --expiration-in-minutes 15 --region ${REGION} --query 'authToken.\"X-aws-proxy-auth\"' --output text)"
echo ""
echo "  入ったら、まず次を試してください:"
echo "      ps -ef                 # python3 /app/server.py が動いている（= アプリのコンテナの中）"
echo "      cat /etc/os-release    # Amazon Linux 2023"
echo "      uname -r               # ゲストカーネル"
echo "      cat /proc/sys/kernel/random/boot_id   # スナップショット由来の値（twins.sh の考察に使う）"
echo "      curl -s http://127.0.0.1:8080/state   # 自分自身のアプリ API"
echo ""
echo "  終わったら: aws lambda-microvms terminate-microvm --microvm-identifier ${MICROVM_ID} --region ${REGION}"
echo "  （放置しても 30 分で自動終了します。cleanup.sh でもまとめて終了します）"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ シェル接続の準備が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
