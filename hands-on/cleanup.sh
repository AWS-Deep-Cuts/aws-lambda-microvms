#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - Lambda MicroVMs ハンズオンの後片付け
# 手順の中で作成した MicroVM と MicroVM イメージ、setup.sh が作成したリソースを、すべて削除します。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Lambda MicroVMs 後片付け"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [[ ! -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が見つかりません。" >&2
  echo "   setup.sh を実行したディレクトリ（hands-on）で実行してください。" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${RESOURCE_FILE}"
REGION="${REGION:-ap-northeast-1}"
IMAGE_NAME="${IMAGE_NAME:-aws-deepcuts-sandbox}"

# イメージの ARN が resource-ids.env に無いとき（手順 2 の途中で終えたときなど）は、名前で探す
if [[ -z "${IMAGE_ARN:-}" ]]; then
  IMAGE_ARN=$(aws lambda-microvms list-microvm-images --region "${REGION}" \
    --query "items[?name=='${IMAGE_NAME}'].imageArn | [0]" --output text 2>/dev/null || true)
  [[ "${IMAGE_ARN}" == "None" ]] && IMAGE_ARN=""
fi

echo "[1/5] このイメージから起動した MicroVM をすべて終了..."
if [[ -n "${IMAGE_ARN}" ]]; then
  IDS=$(aws lambda-microvms list-microvms --image-identifier "${IMAGE_ARN}" --region "${REGION}" \
    --query "items[?state!='TERMINATED' && state!='TERMINATING'].microvmId" --output text 2>/dev/null || true)
  if [[ -z "${IDS}" || "${IDS}" == "None" ]]; then
    echo "  対象なし"
  else
    for ID in ${IDS}; do
      aws lambda-microvms terminate-microvm --microvm-identifier "${ID}" --region "${REGION}" 2>/dev/null || true
      echo "  終了: ${ID}"
    done
  fi
else
  echo "  MicroVM イメージが見つからないため、スキップします"
fi
echo ""

echo "[2/5] MicroVM イメージを削除..."
if [[ -n "${IMAGE_ARN}" ]]; then
  DELETED=""
  # 終了処理中の MicroVM が残っていると削除できないことがあるため、10 秒おきに最大 2 分試す
  for _ in $(seq 1 12); do
    if aws lambda-microvms delete-microvm-image --image-identifier "${IMAGE_ARN}" --region "${REGION}" >/dev/null 2>&1; then
      DELETED="yes"
      break
    fi
    sleep 10
  done
  if [[ -n "${DELETED}" ]]; then
    echo "  削除: ${IMAGE_ARN}"
  else
    echo "  ⚠️  削除できませんでした。数分待ってから、もう一度 bash ./cleanup.sh を実行してください。" >&2
  fi
else
  echo "  対象なし"
fi
echo ""

echo "[3/5] ロググループを削除..."
for GROUP in "${LOG_GROUP:-}" "/aws/lambda-microvms/${IMAGE_NAME}" "/aws/lambda/microvms/${IMAGE_NAME}"; do
  [[ -z "${GROUP}" ]] && continue
  if aws logs delete-log-group --log-group-name "${GROUP}" --region "${REGION}" 2>/dev/null; then
    echo "  削除: ${GROUP}"
  fi
done
echo ""

echo "[4/5] ビルド用と実行用の IAM ロールを削除..."
for PAIR in "${BUILD_ROLE_NAME:-}:aws-deepcuts-microvm-build" "${EXEC_ROLE_NAME:-}:aws-deepcuts-microvm-exec"; do
  ROLE="${PAIR%%:*}"; POLICY="${PAIR##*:}"
  [[ -z "${ROLE}" ]] && continue
  aws iam delete-role-policy --role-name "${ROLE}" --policy-name "${POLICY}" 2>/dev/null || true
  if aws iam delete-role --role-name "${ROLE}" 2>/dev/null; then
    echo "  削除: ${ROLE}"
  fi
done
echo ""

echo "[5/5] S3 バケットとローカルのファイルを削除..."
if [[ -n "${BUCKET_NAME:-}" ]]; then
  # バージョニングが有効なため、すべての版と削除マーカーを消してからバケットを削除する
  VERSIONS=$(aws s3api list-object-versions --bucket "${BUCKET_NAME}" --region "${REGION}" \
    --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][], Quiet: `true`}' \
    --output json 2>/dev/null || echo '{"Objects": []}')
  if [[ "$(echo "${VERSIONS}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("Objects") or []))')" != "0" ]]; then
    aws s3api delete-objects --bucket "${BUCKET_NAME}" --region "${REGION}" --delete "${VERSIONS}" >/dev/null 2>&1 || true
  fi
  if aws s3api delete-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
    echo "  削除: s3://${BUCKET_NAME}"
  fi
fi
# 実際にあったファイルだけを削除し、表示する
REMOVED=""
for FILE in app.zip .sandbox-state.json; do
  if [[ -e "${SCRIPT_DIR:?}/${FILE}" ]]; then
    rm -f "${SCRIPT_DIR:?}/${FILE}"
    REMOVED="${REMOVED:+${REMOVED}、}${FILE}"
  fi
done
if [[ -n "${REMOVED}" ]]; then
  echo "  削除: ${REMOVED}"
fi
echo ""

echo "残っているリソースを確認..."
LEFT=0
IMAGE_DELETING=""
if [[ -n "${IMAGE_ARN}" ]]; then
  # 削除を依頼した直後のイメージは、しばらく DELETING のまま残るため、5 秒おきに最大 2 分、消えるのを待つ
  for _ in $(seq 1 24); do
    IMAGE_STATE=$(aws lambda-microvms get-microvm-image --image-identifier "${IMAGE_ARN}" --region "${REGION}" \
      --query state --output text 2>/dev/null || true)
    [[ "${IMAGE_STATE}" == "DELETING" ]] || break
    sleep 5
  done
  case "${IMAGE_STATE}" in
    ""|"None"|"DELETED") ;;
    "DELETING")
      echo "  ⏳ MicroVM イメージはまだ削除中です（DELETING）。数分で一覧から消えます: ${IMAGE_ARN}"
      IMAGE_DELETING="yes" ;;
    *)
      echo "  ⚠️  MicroVM イメージが残っています（${IMAGE_STATE}）: ${IMAGE_ARN}"; LEFT=1 ;;
  esac
fi
for ROLE in "${BUILD_ROLE_NAME:-}" "${EXEC_ROLE_NAME:-}"; do
  [[ -n "${ROLE}" ]] && aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1 && { echo "  ⚠️  IAM ロールが残っています: ${ROLE}"; LEFT=1; }
done
if [[ -n "${BUCKET_NAME:-}" ]] && aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
  echo "  ⚠️  S3 バケットが残っています: ${BUCKET_NAME}"; LEFT=1
fi
if [[ "${LEFT}" == "1" ]]; then
  echo ""
  echo "❌ 削除できなかったリソースがあります。数分待ってから、もう一度 bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
if [[ -z "${IMAGE_DELETING}" ]]; then
  echo "  なし"
fi
rm -f "${RESOURCE_FILE}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ すべてのリソースの削除が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
