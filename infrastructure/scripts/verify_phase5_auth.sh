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
FE_STACK="${PROJECT}-${ENV}-frontend-dispatch"

TEST_USERNAME="${TEST_USERNAME:-testuser01}"
TEST_PASSWORD="${TEST_PASSWORD:-TmpPassw0rd!2026}"

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

SECRET_API_URL="$(fetch_output "${APP_STACK}" "SecretApiUrl")"
USER_POOL_ID="$(fetch_output "${APP_STACK}" "UserPoolId")"
USER_POOL_CLIENT_ID="$(fetch_output "${APP_STACK}" "UserPoolClientId")"
FRONTEND_URL="$(fetch_output "${FE_STACK}" "FrontendURL")"

if [[ -z "${SECRET_API_URL}" || "${SECRET_API_URL}" == "None" ]]; then
  echo "ERROR: SecretApiUrl output not found in ${APP_STACK}."
  exit 1
fi

if [[ -z "${USER_POOL_ID}" || "${USER_POOL_ID}" == "None" ]]; then
  echo "ERROR: UserPoolId output not found in ${APP_STACK}."
  exit 1
fi

if [[ -z "${USER_POOL_CLIENT_ID}" || "${USER_POOL_CLIENT_ID}" == "None" ]]; then
  echo "ERROR: UserPoolClientId output not found in ${APP_STACK}."
  exit 1
fi

if [[ -z "${FRONTEND_URL}" || "${FRONTEND_URL}" == "None" ]]; then
  echo "ERROR: FrontendURL output not found in ${FE_STACK}."
  exit 1
fi

echo "[Info] AWS_REGION=${AWS_REGION}"
echo "[Info] APP_STACK=${APP_STACK}"
echo "[Info] FE_STACK=${FE_STACK}"
echo "[Info] SECRET_API_URL=${SECRET_API_URL}"
echo "[Info] USER_POOL_ID=${USER_POOL_ID}"
echo "[Info] USER_POOL_CLIENT_ID=${USER_POOL_CLIENT_ID}"
echo "[Info] FRONTEND_URL=${FRONTEND_URL}"

echo
echo "[Check] Preflight OPTIONS /secret"
OPTIONS_HEADERS="$(curl -s -i -X OPTIONS "${SECRET_API_URL}" \
  -H "Origin: ${FRONTEND_URL}" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: authorization,content-type")"
echo "${OPTIONS_HEADERS}" | sed -n '1,20p'

echo
echo "[Check] GET /secret without auth (expect 401/403)"
NOAUTH_HEADERS="$(curl -s -i "${SECRET_API_URL}" \
  -H "Origin: ${FRONTEND_URL}")"
echo "${NOAUTH_HEADERS}" | sed -n '1,20p'

NOAUTH_STATUS="$(echo "${NOAUTH_HEADERS}" | awk 'NR==1 {print $2}')"
if [[ "${NOAUTH_STATUS}" != "401" && "${NOAUTH_STATUS}" != "403" ]]; then
  echo "WARNING: Unexpected unauthenticated status: ${NOAUTH_STATUS}"
fi

echo
echo "[Check] Get token by USER_PASSWORD_AUTH"
AUTH_JSON="$(aws cognito-idp initiate-auth \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE_NAME}" \
  --client-id "${USER_POOL_CLIENT_ID}" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${TEST_USERNAME},PASSWORD=${TEST_PASSWORD}" \
  --output json 2>/tmp/verify_phase5_auth_error.log || true)"

if [[ -z "${AUTH_JSON}" ]]; then
  echo "ERROR: Failed to get token with USER_PASSWORD_AUTH."
  echo "- Check TEST_USERNAME/TEST_PASSWORD."
  echo "- Check UserPoolClient ExplicitAuthFlows includes ALLOW_USER_PASSWORD_AUTH."
  echo "Details:"
  cat /tmp/verify_phase5_auth_error.log
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

ACCESS_TOKEN="$(aws cognito-idp initiate-auth \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE_NAME}" \
  --client-id "${USER_POOL_CLIENT_ID}" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${TEST_USERNAME},PASSWORD=${TEST_PASSWORD}" \
  --query 'AuthenticationResult.AccessToken' \
  --output text)"

if [[ -z "${ID_TOKEN}" || "${ID_TOKEN}" == "None" ]]; then
  echo "ERROR: IdToken not returned."
  exit 1
fi

echo "[Check] GET /secret with ID token"
ID_HEADERS="$(curl -s -i "${SECRET_API_URL}" \
  -H "Origin: ${FRONTEND_URL}" \
  -H "Authorization: Bearer ${ID_TOKEN}")"
echo "${ID_HEADERS}" | sed -n '1,20p'

ID_STATUS="$(echo "${ID_HEADERS}" | awk 'NR==1 {print $2}')"
if [[ "${ID_STATUS}" == "200" ]]; then
  echo
  echo "SUCCESS: Authenticated call with ID token returned 200."
  exit 0
fi

if [[ -n "${ACCESS_TOKEN}" && "${ACCESS_TOKEN}" != "None" ]]; then
  echo
  echo "[Retry] GET /secret with Access token"
  ACCESS_HEADERS="$(curl -s -i "${SECRET_API_URL}" \
    -H "Origin: ${FRONTEND_URL}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")"
  echo "${ACCESS_HEADERS}" | sed -n '1,20p'

  ACCESS_STATUS="$(echo "${ACCESS_HEADERS}" | awk 'NR==1 {print $2}')"
  if [[ "${ACCESS_STATUS}" == "200" ]]; then
    echo
    echo "SUCCESS: Authenticated call with Access token returned 200."
    exit 0
  fi
fi

echo
echo "ERROR: Authenticated call still failed."
echo "- ID token status: ${ID_STATUS}"
echo "- Check API Gateway Cognito authorizer configuration and token audience/issuer alignment."
exit 1
