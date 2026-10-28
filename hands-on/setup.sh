#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

readonly PROJECT_NAME="aws-deepcuts"
readonly REGION="ap-northeast-1"          # Lambda MicroVMs は東京リージョンで提供（2026 年 10 月時点）
readonly IMAGE_NAME="${PROJECT_NAME}-microvm-sandbox"
readonly BUILD_ROLE_NAME="${PROJECT_NAME}-microvm-build-role"
readonly EXEC_ROLE_NAME="${PROJECT_NAME}-microvm-exec-role"
readonly LOG_GROUP="/aws/lambda-microvms/${PROJECT_NAME}"
readonly HOOK_PORT=9000
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"
readonly ARTIFACT="${SCRIPT_DIR}/app.zip"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Lambda MicroVMs セットアップ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/7] 前提チェック ─────────────────────────────────────────
echo "[1/7] 前提を確認..."
if [[ -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が既に存在します。前回の環境が残っています。" >&2
  echo "   先に bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
if ! aws lambda-microvms run-microvm --generate-cli-skeleton input >/dev/null 2>&1; then
  echo "❌ Error: この AWS CLI は lambda-microvms コマンドに対応していません。" >&2
  echo "   AWS CLI v2 を最新版に更新してください。現在: $(aws --version 2>&1)" >&2
  exit 1
fi
for cmd in zip curl python3; do
  command -v "${cmd}" >/dev/null || { echo "❌ Error: ${cmd} が見つかりません。" >&2; exit 1; }
done
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "❌ Error: AWS 認証情報が取得できません。AWS CLI の設定を確認してください。" >&2
  exit 1
}
echo "  アカウント: ${ACCOUNT_ID} / リージョン: ${REGION}"
echo ""

# ─── [2/7] ベースイメージの確認 ────────────────────────────────
echo "[2/7] Lambda 管理のベースイメージを確認..."
BASE_IMAGE_ARN=$(aws lambda-microvms list-managed-microvm-images --region "${REGION}" \
  --query 'items[?contains(imageArn, `al2023`)].imageArn | [0]' --output text)
if [[ -z "${BASE_IMAGE_ARN}" || "${BASE_IMAGE_ARN}" == "None" ]]; then
  echo "❌ Error: ベースイメージが見つかりません。リージョン ${REGION} で Lambda MicroVMs が使えるか確認してください。" >&2
  aws lambda-microvms list-managed-microvm-images --region "${REGION}" --output table || true
  exit 1
fi
echo "  ベースイメージ: ${BASE_IMAGE_ARN}"
echo ""

# ─── [3/7] S3 バケットとコード成果物 ────────────────────────────
echo "[3/7] コード成果物（Dockerfile + server.py）を S3 にアップロード..."
BUCKET_NAME="${PROJECT_NAME}-microvms-${ACCOUNT_ID}-$(date +%Y%m%d-%H%M%S)"
aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
aws s3api put-public-access-block --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
# コード成果物のバケットはバージョニングを有効にしておく（ビルドが特定バージョンのオブジェクトを参照できるように）
aws s3api put-bucket-versioning --bucket "${BUCKET_NAME}" --versioning-configuration Status=Enabled --region "${REGION}"
rm -f "${ARTIFACT}"
(cd "${SCRIPT_DIR}/app" && zip -q -r "${ARTIFACT}" Dockerfile server.py)
aws s3 cp "${ARTIFACT}" "s3://${BUCKET_NAME}/app.zip" --region "${REGION}" >/dev/null
echo "  s3://${BUCKET_NAME}/app.zip ($(du -h "${ARTIFACT}" | cut -f1))"
echo ""

# ─── [4/7] ビルド用 IAM ロール ──────────────────────────────────
# イメージ作成時に Lambda サービスが引き受け、S3 から成果物を取得し、ビルドログを CloudWatch Logs に書く。
# もう 1 つ、実行ロール（microVM が実行時に引き受け、ランタイムのログを CloudWatch Logs に書く）も作る。
# 実行ロールが無いと、アプリの標準出力やフックのログは CloudWatch Logs に転送されない。
echo "[4/7] ビルド用・実行用の IAM ロールを作成..."
# Lambda サービスが引き受けるロールの信頼ポリシー（sts:TagSession も必要）。
# 本番では混乱した代理（confused deputy）対策に aws:SourceAccount 条件を付けるのが推奨だが、
# ハンズオンでは公式チュートリアルと同じ最小構成にしている。
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}'
BUILD_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${BUILD_ROLE_NAME}"
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE_NAME}"
for ROLE in "${BUILD_ROLE_NAME}" "${EXEC_ROLE_NAME}"; do
  if aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1; then
    echo "  ℹ️  既に存在します: ${ROLE}"
  else
    aws iam create-role --role-name "${ROLE}" \
      --description "AWS Deep Cuts Lambda MicroVMs hands-on" \
      --tags "Key=Project,Value=${PROJECT_NAME}" \
      --assume-role-policy-document "${TRUST_POLICY}" >/dev/null
    echo "  作成: ${ROLE}"
  fi
done
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
echo "  IAM の伝播を待機（10 秒）..."
sleep 10
echo ""

# ─── [5/7] CloudWatch Logs ロググループ ──────────────────────────
echo "[5/7] ロググループを作成..."
if aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" --region "${REGION}" \
     --query "logGroups[?logGroupName=='${LOG_GROUP}'] | length(@)" --output text | grep -q '^[1-9]'; then
  echo "  ℹ️  既に存在します: ${LOG_GROUP}"
else
  aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${REGION}" \
    --tags "Project=${PROJECT_NAME}"
  aws logs put-retention-policy --log-group-name "${LOG_GROUP}" --retention-in-days 7 --region "${REGION}"
  echo "  作成: ${LOG_GROUP}（保持 7 日）"
fi
echo ""

# ─── [6/7] MicroVM イメージの作成（ビルド = 起動してスナップショット） ──
echo "[6/7] MicroVM イメージを作成（Dockerfile を実行 → アプリ起動 → /ready を待つ → メモリとディスクをスナップショット）..."
IMAGE_ARN=$(aws lambda-microvms create-microvm-image --region "${REGION}" \
  --name "${IMAGE_NAME}" \
  --description "AWS Deep Cuts: stateful Python sandbox" \
  --base-image-arn "${BASE_IMAGE_ARN}" \
  --build-role-arn "${BUILD_ROLE_ARN}" \
  --code-artifact "uri=s3://${BUCKET_NAME}/app.zip" \
  --logging "{\"cloudWatch\":{\"logGroup\":\"${LOG_GROUP}\"}}" \
  --hooks "{
    \"port\": ${HOOK_PORT},
    \"microvmImageHooks\": {\"ready\": \"ENABLED\", \"readyTimeoutInSeconds\": 120},
    \"microvmHooks\": {
      \"run\": \"ENABLED\", \"runTimeoutInSeconds\": 10,
      \"suspend\": \"ENABLED\", \"suspendTimeoutInSeconds\": 10,
      \"resume\": \"ENABLED\", \"resumeTimeoutInSeconds\": 10,
      \"terminate\": \"ENABLED\", \"terminateTimeoutInSeconds\": 10
    }
  }" \
  --environment-variables "APP_PORT=8080,HOOK_PORT=${HOOK_PORT}" \
  --resources '[{"minimumMemoryInMiB": 512}]' \
  --tags "Project=${PROJECT_NAME}" \
  --query 'imageArn' --output text)
echo "  イメージ: ${IMAGE_ARN}"
echo "  ビルド完了を待機中（数分かかります）..."
STATE=""
for _ in $(seq 1 60); do
  STATE=$(aws lambda-microvms get-microvm-image --image-identifier "${IMAGE_ARN}" --region "${REGION}" \
    --query 'state' --output text)
  case "${STATE}" in
    CREATED) break ;;
    CREATE_FAILED)
      echo "❌ Error: イメージのビルドに失敗しました。CloudWatch Logs の ${LOG_GROUP} を確認してください。" >&2
      aws lambda-microvms get-microvm-image --image-identifier "${IMAGE_ARN}" --region "${REGION}" --output json >&2 || true
      exit 1 ;;
    *) printf '.'; sleep 15 ;;
  esac
done
echo ""
if [[ "${STATE}" != "CREATED" ]]; then
  echo "❌ Error: 15 分待ってもビルドが完了しませんでした（state=${STATE}）。しばらく待ってから get-microvm-image で確認してください。" >&2
  exit 1
fi
IMAGE_VERSION=$(aws lambda-microvms get-microvm-image --image-identifier "${IMAGE_ARN}" --region "${REGION}" \
  --query 'latestActiveImageVersion' --output text)
echo "  ビルド完了: version ${IMAGE_VERSION}"

# スナップショットの大きさ（= 起動済みのメモリとディスクが凍結されている証拠）。
# 1 バージョンにつき、対象チップセット世代ごとにビルド（スナップショット）が作られる。
echo "  このバージョンのビルド（スナップショット）:"
for BUILD_ID in $(aws lambda-microvms list-microvm-image-builds --image-identifier "${IMAGE_ARN}" \
  --image-version "${IMAGE_VERSION}" --region "${REGION}" --query 'items[].buildId' --output text); do
  aws lambda-microvms get-microvm-image-build --image-identifier "${IMAGE_ARN}" \
    --image-version "${IMAGE_VERSION}" --build-id "${BUILD_ID}" --region "${REGION}" \
    --query '{buildState:buildState,architecture:architecture,chipset:chipset,chipsetGeneration:chipsetGeneration,memorySnapshotBytes:to_string(snapshotBuild.memorySnapshotSizeInBytes),diskSnapshotBytes:to_string(snapshotBuild.diskSnapshotSizeInBytes),codeInstallBytes:to_string(snapshotBuild.codeInstallSizeInBytes)}' \
    --output table
done
echo ""

# ─── [7/7] リソース情報を保存 ───────────────────────────────────
echo "[7/7] リソース情報を保存..."
cat > "${RESOURCE_FILE}" <<EOF
# AWS Deep Cuts Lambda MicroVMs - リソース情報（setup.sh が自動生成）
REGION="${REGION}"
ACCOUNT_ID="${ACCOUNT_ID}"
BUCKET_NAME="${BUCKET_NAME}"
BUILD_ROLE_NAME="${BUILD_ROLE_NAME}"
BUILD_ROLE_ARN="${BUILD_ROLE_ARN}"
EXEC_ROLE_NAME="${EXEC_ROLE_NAME}"
EXEC_ROLE_ARN="${EXEC_ROLE_ARN}"
LOG_GROUP="${LOG_GROUP}"
BASE_IMAGE_ARN="${BASE_IMAGE_ARN}"
IMAGE_NAME="${IMAGE_NAME}"
IMAGE_ARN="${IMAGE_ARN}"
IMAGE_VERSION="${IMAGE_VERSION}"
HOOK_PORT="${HOOK_PORT}"
APP_PORT="8080"
EOF
echo "  ${RESOURCE_FILE}"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ セットアップが完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "次のステップ: bash ./run.sh で microVM を起動し、サスペンド／レジュームを試してください。"
