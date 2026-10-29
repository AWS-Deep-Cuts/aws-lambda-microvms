#!/bin/bash
# AWS Deep Cuts - Lambda MicroVMs: twins.sh が source して使う共通関数（単体では実行しない）

# ミリ秒単位の現在時刻
now_ms() { date +%s%3N; }

# microVM の状態を返す
microvm_state() {
  aws lambda-microvms get-microvm --microvm-identifier "$1" --region "${REGION}" --query 'state' --output text
}

# 状態が $2 になるまで待つ（最大 $3 秒）。なったら 0、ならなければ 1
wait_state() {
  local id="$1" want="$2" limit="${3:-300}" state=""
  local started; started=$(date +%s)
  while (( $(date +%s) - started < limit )); do
    state=$(microvm_state "${id}")
    [[ "${state}" == "${want}" ]] && return 0
    sleep 2
  done
  echo "  ⚠️  ${limit} 秒以内に ${want} になりませんでした（現在: ${state}）" >&2
  return 1
}

# アプリ用の認証トークンを発行して標準出力に返す（X-aws-proxy-auth ヘッダーの値）
create_app_token() {
  aws lambda-microvms create-microvm-auth-token --microvm-identifier "$1" --region "${REGION}" \
    --expiration-in-minutes 60 --allowed-ports "[{\"port\": ${APP_PORT}}]" \
    --query 'authToken."X-aws-proxy-auth"' --output text
}

# エンドポイントの API を叩く: app_call <endpoint> <token> <method> <path> [json-body]
app_call() {
  local endpoint="$1" token="$2" method="$3" path="$4" body="${5:-}"
  [[ "${endpoint}" == http* ]] || endpoint="https://${endpoint}"   # スキーム無しで返ってきた場合に備える
  if [[ -n "${body}" ]]; then
    curl -sS --max-time 30 -X "${method}" "${endpoint}${path}" \
      -H "X-aws-proxy-auth: ${token}" -H "X-aws-proxy-port: ${APP_PORT}" \
      -H "Content-Type: application/json" --data "${body}"
  else
    curl -sS --max-time 30 -X "${method}" "${endpoint}${path}" \
      -H "X-aws-proxy-auth: ${token}" -H "X-aws-proxy-port: ${APP_PORT}"
  fi
}

# /ping が 200 を返すまで待ち、かかったミリ秒を標準出力に返す（最大 $3 秒）
wait_ping_ms() {
  local endpoint="$1" token="$2" limit="${3:-180}"
  [[ "${endpoint}" == http* ]] || endpoint="https://${endpoint}"
  local started; started=$(now_ms)
  while (( ($(now_ms) - started) / 1000 < limit )); do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${endpoint}/ping" \
      -H "X-aws-proxy-auth: ${token}" -H "X-aws-proxy-port: ${APP_PORT}" || true)
    if [[ "${code}" == "200" ]]; then
      echo $(( $(now_ms) - started ))
      return 0
    fi
    sleep 0.5
  done
  echo "-1"
  return 1
}

# Python コードを microVM 内で実行し、結果の JSON を返す: app_exec <endpoint> <token> <python-code>
app_exec() {
  local code_json
  code_json=$(python3 -c 'import json,sys; print(json.dumps({"code": sys.argv[1]}))' "$3")
  app_call "$1" "$2" POST /exec "${code_json}"
}
