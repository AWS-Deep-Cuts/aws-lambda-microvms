#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Lambda MicroVMs クリーンアップ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [[ ! -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が見つかりません。" >&2
  echo "   setup.sh を実行したディレクトリで実行してください。" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${RESOURCE_FILE}"

echo "[1/5] このイメージから起動した microVM をすべて終了..."
if [[ -n "${IMAGE_ARN:-}" ]]; then
  IDS=$(aws lambda-microvms list-microvms --image-identifier "${IMAGE_ARN}" --region "${REGION}" \
    --query "items[?state!='TERMINATED' && state!='TERMINATING'].microvmId" --output text 2>/dev/null || true)
  for ID in ${IDS}; do
    aws lambda-microvms terminate-microvm --microvm-identifier "${ID}" --region "${REGION}" 2>/dev/null || true
    echo "  terminate: ${ID}"
  done
  [[ -z "${IDS}" ]] && echo "  対象なし"
fi
echo ""

echo "[2/5] MicroVM イメージを削除..."
if [[ -n "${IMAGE_ARN:-}" ]]; then
  # 実行中の microVM が残っていると削除できないので、少し待ってから削除する
  for _ in $(seq 1 12); do
    if aws lambda-microvms delete-microvm-image --image-identifier "${IMAGE_ARN}" --region "${REGION}" >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
  echo "  完了: ${IMAGE_ARN}"
fi
echo ""

echo "[3/5] ロググループを削除..."
if [[ -n "${LOG_GROUP:-}" ]]; then
  aws logs delete-log-group --log-group-name "${LOG_GROUP}" --region "${REGION}" 2>/dev/null || true
  echo "  完了: ${LOG_GROUP}"
fi
# ロググループを指定しなかった場合にサービスが自動作成する既定のロググループも消しておく
if [[ -n "${IMAGE_NAME:-}" ]]; then
  aws logs delete-log-group --log-group-name "/aws/lambda-microvms/${IMAGE_NAME}" --region "${REGION}" 2>/dev/null || true
  aws logs delete-log-group --log-group-name "/aws/lambda/microvms/${IMAGE_NAME}" --region "${REGION}" 2>/dev/null || true
fi
echo ""

echo "[4/5] ビルド用・実行用 IAM ロールを削除..."
if [[ -n "${BUILD_ROLE_NAME:-}" ]]; then
  aws iam delete-role-policy --role-name "${BUILD_ROLE_NAME}" --policy-name "aws-deepcuts-microvm-build" 2>/dev/null || true
  aws iam delete-role --role-name "${BUILD_ROLE_NAME}" 2>/dev/null || true
  echo "  完了: ${BUILD_ROLE_NAME}"
fi
if [[ -n "${EXEC_ROLE_NAME:-}" ]]; then
  aws iam delete-role-policy --role-name "${EXEC_ROLE_NAME}" --policy-name "aws-deepcuts-microvm-exec" 2>/dev/null || true
  aws iam delete-role --role-name "${EXEC_ROLE_NAME}" 2>/dev/null || true
  echo "  完了: ${EXEC_ROLE_NAME}"
fi
echo ""

echo "[5/5] S3 バケットとローカルの生成物を削除..."
if [[ -n "${BUCKET_NAME:-}" ]]; then
  # バージョニングが有効なので、全バージョンと削除マーカーを消してからバケットを削除する
  VERSIONS=$(aws s3api list-object-versions --bucket "${BUCKET_NAME}" --region "${REGION}" \
    --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][] , Quiet: `true`}' \
    --output json 2>/dev/null || echo '{"Objects": []}')
  if [[ "$(echo "${VERSIONS}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("Objects") or []))')" != "0" ]]; then
    aws s3api delete-objects --bucket "${BUCKET_NAME}" --region "${REGION}" --delete "${VERSIONS}" >/dev/null 2>&1 || true
  fi
  aws s3api delete-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null || true
  echo "  完了: ${BUCKET_NAME}"
fi
rm -rf "${SCRIPT_DIR}/output"
rm -f "${RESOURCE_FILE}" "${SCRIPT_DIR}/app.zip"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ すべてのリソースの削除が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
