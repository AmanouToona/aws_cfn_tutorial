#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${AWS_PROFILE_NAME:-}" ]]; then
  echo "ERROR: AWS_PROFILE_NAME is not set."
  echo "Example: export AWS_PROFILE_NAME=my-sso-profile"
  exit 1
fi

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
PROJECT="${PROJECT:-aws-cfn-tutorial}"
ENV="${ENV:-dev}"
APP_STACK="${PROJECT}-${ENV}-application"

TEST_USERNAME="${TEST_USERNAME:-testuser01}"
TEST_PASSWORD="${TEST_PASSWORD:-TmpPassw0rd!2026}"
UNAUTH_EXPECT_OK="${UNAUTH_EXPECT_OK:-10}"
AUTH_EXPECT_OK="${AUTH_EXPECT_OK:-100}"
UNAUTH_TOTAL_REQUESTS="${UNAUTH_TOTAL_REQUESTS:-12}"
AUTH_TOTAL_REQUESTS="${AUTH_TOTAL_REQUESTS:-102}"

fetch_output() {
  local stack_name="$1"
  local output_key="$2"
  aws cloudformation describe-stacks \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE_NAME}" \
    --stack-name "${stack_name}" \
    --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue | [0]" \
    --output text
}

HELLO_API_URL="$(fetch_output "${APP_STACK}" "HelloApiUrl")"
SECRET_API_URL="$(fetch_output "${APP_STACK}" "SecretApiUrl")"
USER_POOL_CLIENT_ID="$(fetch_output "${APP_STACK}" "UserPoolClientId")"

if [[ -z "${HELLO_API_URL}" || "${HELLO_API_URL}" == "None" ]]; then
  echo "ERROR: HelloApiUrl output not found in ${APP_STACK}."
  exit 1
fi

if [[ -z "${SECRET_API_URL}" || "${SECRET_API_URL}" == "None" ]]; then
  echo "ERROR: SecretApiUrl output not found in ${APP_STACK}."
  exit 1
fi

if [[ -z "${USER_POOL_CLIENT_ID}" || "${USER_POOL_CLIENT_ID}" == "None" ]]; then
  echo "ERROR: UserPoolClientId output not found in ${APP_STACK}."
  exit 1
fi

ID_TOKEN="$(aws cognito-idp initiate-auth \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE_NAME}" \
  --client-id "${USER_POOL_CLIENT_ID}" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${TEST_USERNAME},PASSWORD=${TEST_PASSWORD}" \
  --query 'AuthenticationResult.IdToken' \
  --output text)"

if [[ -z "${ID_TOKEN}" || "${ID_TOKEN}" == "None" ]]; then
  echo "ERROR: IdToken not returned."
  exit 1
fi

call_status() {
  local url="$1"
  local auth_header="${2:-}"
  if [[ -n "${auth_header}" ]]; then
    curl -s -o /tmp/phase6_rate_limit_body.txt -w '%{http_code}' \
      -H "Authorization: Bearer ${auth_header}" \
      "${url}"
  else
    curl -s -o /tmp/phase6_rate_limit_body.txt -w '%{http_code}' \
      "${url}"
  fi
}

run_series() {
  local label="$1"
  local url="$2"
  local auth_header="$3"
  local expect_ok="$4"
  local total_requests="$5"

  echo
  echo "[Check] ${label}"

  local ok_count=0
  local limit_count=0
  local first_limit_at=""
  local request_number
  local status_code

  for ((request_number=1; request_number<=total_requests; request_number++)); do
    status_code="$(call_status "${url}" "${auth_header}")"
    printf '  request=%03d status=%s\n' "${request_number}" "${status_code}"

    if [[ "${status_code}" == "200" ]]; then
      ok_count=$((ok_count + 1))
    elif [[ "${status_code}" == "429" ]]; then
      limit_count=$((limit_count + 1))
      if [[ -z "${first_limit_at}" ]]; then
        first_limit_at="${request_number}"
      fi
    else
      echo "ERROR: Unexpected status ${status_code} during ${label}."
      echo "Response body:"
      cat /tmp/phase6_rate_limit_body.txt
      exit 1
    fi
  done

  echo "[Summary] ${label}: ok_count=${ok_count}, limit_count=${limit_count}, first_limit_at=${first_limit_at:-none}"

  if [[ "${ok_count}" -lt "${expect_ok}" ]]; then
    echo "ERROR: ${label} returned fewer than expected successful responses."
    exit 1
  fi

  if [[ -z "${first_limit_at}" ]]; then
    echo "ERROR: ${label} never returned 429."
    exit 1
  fi

  if [[ "${first_limit_at}" -gt $((expect_ok + 1)) ]]; then
    echo "ERROR: ${label} returned 429 too late. expected around request $((expect_ok + 1))."
    exit 1
  fi
}

echo "[Info] AWS_REGION=${AWS_REGION}"
echo "[Info] APP_STACK=${APP_STACK}"
echo "[Info] HELLO_API_URL=${HELLO_API_URL}"
echo "[Info] SECRET_API_URL=${SECRET_API_URL}"
echo "[Info] USER_POOL_CLIENT_ID=${USER_POOL_CLIENT_ID}"

echo
echo "NOTE: This check assumes you run it near the start of a minute."
echo "If a previous run already used the current minute window, wait for the next minute and rerun."

run_series "Unauthenticated /hello rate limit" "${HELLO_API_URL}" "" "${UNAUTH_EXPECT_OK}" "${UNAUTH_TOTAL_REQUESTS}"
run_series "Authenticated /secret rate limit" "${SECRET_API_URL}" "${ID_TOKEN}" "${AUTH_EXPECT_OK}" "${AUTH_TOTAL_REQUESTS}"

echo
echo "SUCCESS: Phase 6 rate limiting behaved as expected."
