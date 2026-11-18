#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - Lambda MicroVMs ハンズオンの事前準備
# MicroVMs そのものの操作（イメージの作成・起動・サスペンドなど）は、README の手順で 1 コマンドずつ実行します。
# このスクリプトは、その前提になる次の 4 つだけを作成します。
#   1. S3 バケット          … アプリの zip（Dockerfile と server.py）を保存する
#   2. ビルド用の IAM ロール … イメージの作成中に Lambda が引き受け、S3 から zip を読み、ビルドのログを書く
#   3. 実行用の IAM ロール   … MicroVM の実行中に Lambda が引き受け、アプリのログを書く
#   4. CloudWatch Logs のロググループ … ビルドと実行のログの保存先（保持期間 7 日）

readonly PROJECT_NAME="aws-deepcuts"
readonly REGION="ap-northeast-1"          # Lambda MicroVMs は東京リージョンで提供されている（2026 年 10 月時点）
readonly IMAGE_NAME="${PROJECT_NAME}-sandbox"
readonly BUILD_ROLE_NAME="${PROJECT_NAME}-microvm-build-role"
readonly EXEC_ROLE_NAME="${PROJECT_NAME}-microvm-exec-role"
readonly LOG_GROUP="/aws/lambda-microvms/${PROJECT_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Lambda MicroVMs 事前準備"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/5] 前提の確認 ─────────────────────────────────────────
echo "[1/5] 前提を確認..."
if [[ -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が既に存在します。前回の環境が残っています。" >&2
  echo "   先に bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
if ! aws lambda-microvms run-microvm --generate-cli-skeleton input >/dev/null 2>&1; then
  echo "❌ Error: この AWS CLI は lambda-microvms コマンドに対応していません（v2.35.10 以降が必要です）。" >&2
  echo "   現在のバージョン: $(aws --version 2>&1)" >&2
  echo "   README の「前提条件」の手順で、ホームディレクトリに最新版の AWS CLI をインストールしてください。" >&2
  exit 1
fi
for cmd in zip curl python3; do
  command -v "${cmd}" >/dev/null || { echo "❌ Error: ${cmd} コマンドが見つかりません。" >&2; exit 1; }
done
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "❌ Error: AWS の認証情報を取得できません。CloudShell で実行しているか確認してください。" >&2
  exit 1
}
echo "  アカウント: ${ACCOUNT_ID} / リージョン: ${REGION}"

# 作成したリソースは、作成した直後に resource-ids.env へ書き足す。
# 途中で失敗しても、cleanup.sh がこのファイルを読んで、作成済みのリソースを削除できるようにするため。
BUILD_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${BUILD_ROLE_NAME}"
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE_NAME}"
cat > "${RESOURCE_FILE}" <<EOF
# AWS Deep Cuts Lambda MicroVMs - リソース情報（setup.sh が作成。README の手順で行を追記します）
REGION="${REGION}"
ACCOUNT_ID="${ACCOUNT_ID}"
BUILD_ROLE_NAME="${BUILD_ROLE_NAME}"
EXEC_ROLE_NAME="${EXEC_ROLE_NAME}"
LOG_GROUP="${LOG_GROUP}"
IMAGE_NAME="${IMAGE_NAME}"
INGRESS_CONNECTOR="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"
EOF
echo "  リソース情報の保存先: ${RESOURCE_FILE}"
echo ""

# ─── [2/5] S3 バケット ─────────────────────────────────────────
echo "[2/5] アプリの zip を保存する S3 バケットを作成..."
BUCKET_NAME="${PROJECT_NAME}-microvms-${ACCOUNT_ID}-$(date +%Y%m%d-%H%M%S)"
aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
echo "BUCKET_NAME=\"${BUCKET_NAME}\"" >> "${RESOURCE_FILE}"
aws s3api put-public-access-block --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
# zip を上書きしても、作成済みのイメージが参照した版を残せるように、バージョニングを有効にする
aws s3api put-bucket-versioning --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --versioning-configuration Status=Enabled
echo "  作成: s3://${BUCKET_NAME}"
echo ""

# ─── [3/5] IAM ロール ─────────────────────────────────────────
echo "[3/5] ビルド用と実行用の IAM ロールを作成..."
# どちらのロールも、Lambda のサービスが引き受ける（sts:TagSession も必要）。
# 本番では aws:SourceAccount の条件を付けて、他のアカウントからの利用を防ぐことが推奨されている。
# このハンズオンでは、公式チュートリアルと同じ最小限の構成にしている。
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}'
for ROLE in "${BUILD_ROLE_NAME}" "${EXEC_ROLE_NAME}"; do
  if aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1; then
    echo "  既に存在するため、そのまま使います: ${ROLE}"
  else
    aws iam create-role --role-name "${ROLE}" \
      --description "AWS Deep Cuts Lambda MicroVMs hands-on" \
      --tags "Key=Project,Value=${PROJECT_NAME}" \
      --assume-role-policy-document "${TRUST_POLICY}" >/dev/null
    echo "  作成: ${ROLE}"
  fi
done
# ビルド用ロール: S3 の zip を読む権限と、ビルドのログを書く権限
aws iam put-role-policy --role-name "${BUILD_ROLE_NAME}" --policy-name "${PROJECT_NAME}-microvm-build" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"ReadCodeArtifact\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:GetObjectVersion\"],
        \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/*\"
      },
      {
        \"Sid\": \"WriteBuildLogs\",
        \"Effect\": \"Allow\",
        \"Action\": [\"logs:CreateLogGroup\", \"logs:CreateLogStream\", \"logs:PutLogEvents\"],
        \"Resource\": \"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*\"
      }
    ]
  }"
# 実行用ロール: アプリのログを書く権限だけ（MicroVM の中のアプリは、これ以外の AWS の操作ができない）
aws iam put-role-policy --role-name "${EXEC_ROLE_NAME}" --policy-name "${PROJECT_NAME}-microvm-exec" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"WriteRuntimeLogs\",
      \"Effect\": \"Allow\",
      \"Action\": [\"logs:CreateLogGroup\", \"logs:CreateLogStream\", \"logs:PutLogEvents\"],
      \"Resource\": \"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*\"
    }]
  }"
{
  echo "BUILD_ROLE_ARN=\"${BUILD_ROLE_ARN}\""
  echo "EXEC_ROLE_ARN=\"${EXEC_ROLE_ARN}\""
} >> "${RESOURCE_FILE}"
echo "  ビルド用ロール: ${BUILD_ROLE_ARN}"
echo "  実行用ロール:   ${EXEC_ROLE_ARN}"
echo ""

# ─── [4/5] CloudWatch Logs のロググループ ───────────────────────
echo "[4/5] ロググループを作成..."
if aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" --region "${REGION}" \
     --query "logGroups[?logGroupName=='${LOG_GROUP}'] | length(@)" --output text | grep -q '^[1-9]'; then
  echo "  既に存在するため、そのまま使います: ${LOG_GROUP}"
else
  aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${REGION}" --tags "Project=${PROJECT_NAME}"
  aws logs put-retention-policy --log-group-name "${LOG_GROUP}" --retention-in-days 7 --region "${REGION}"
  echo "  作成: ${LOG_GROUP}（保持期間 7 日）"
fi
echo ""

# ─── [5/5] IAM の反映待ち ──────────────────────────────────────
# 作成した直後の IAM ロールは、Lambda から引き受けられるようになるまで少し時間がかかる
echo "[5/5] IAM ロールの反映を待機（10 秒）..."
sleep 10
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ セットアップが完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "作成したリソースは、マネジメントコンソールの次の画面で確認できます。"
echo "  S3 バケット:   https://${REGION}.console.aws.amazon.com/s3/buckets/${BUCKET_NAME}?region=${REGION}"
echo "  IAM ロール:    https://us-east-1.console.aws.amazon.com/iam/home#/roles/details/${BUILD_ROLE_NAME}"
echo "                 https://us-east-1.console.aws.amazon.com/iam/home#/roles/details/${EXEC_ROLE_NAME}"
echo "  ロググループ:  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups"
echo ""
echo "次のステップ: README の手順 1 に戻り、作成したリソースを確認してから、次のコマンドで変数を読み込んでください。"
echo "  source ./resource-ids.env"
