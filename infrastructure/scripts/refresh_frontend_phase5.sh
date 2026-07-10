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
BOOTSTRAP_STACK="${PROJECT}-${ENV}-bootstrap"
FE_STACK="${PROJECT}-${ENV}-frontend-dispatch"
APP_STACK="${PROJECT}-${ENV}-application"

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

FRONTEND_BUCKET="$(fetch_output "${BOOTSTRAP_STACK}" "FrontendBucketName")"
FRONTEND_URL="$(fetch_output "${FE_STACK}" "FrontendURL")"
USER_POOL_CLIENT_ID="$(fetch_output "${APP_STACK}" "UserPoolClientId")"
SECRET_API_URL="$(fetch_output "${APP_STACK}" "SecretApiUrl")"
COGNITO_DOMAIN_PREFIX="$(fetch_output "${APP_STACK}" "CognitoDomain")"

if [[ -z "${FRONTEND_BUCKET}" || "${FRONTEND_BUCKET}" == "None" ]]; then
  echo "ERROR: FrontendBucketName output not found in ${BOOTSTRAP_STACK}."
  exit 1
fi

if [[ -z "${FRONTEND_URL}" || "${FRONTEND_URL}" == "None" ]]; then
  echo "ERROR: FrontendURL output not found in ${FE_STACK}."
  exit 1
fi

DIST_ID="$(aws cloudformation list-stack-resources \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE_NAME}" \
  --stack-name "${FE_STACK}" \
  --query "StackResourceSummaries[?LogicalResourceId=='FrontendDistribution'].PhysicalResourceId | [0]" \
  --output text)"

if [[ -z "${DIST_ID}" || "${DIST_ID}" == "None" ]]; then
  echo "ERROR: CloudFront distribution ID not found in ${FE_STACK}."
  exit 1
fi

echo "[Info] AWS_REGION=${AWS_REGION}"
echo "[Info] FRONTEND_BUCKET=${FRONTEND_BUCKET}"
echo "[Info] FRONTEND_URL=${FRONTEND_URL}"
echo "[Info] DISTRIBUTION_ID=${DIST_ID}"

echo
echo "[Check] Local frontend CONFIG values"
grep -nE "clientId:|secretApiUrl:|cognitoDomainPrefix:" frontend/index.html || true

echo
echo "[Deploy] Upload frontend assets"
aws s3 sync frontend/ "s3://${FRONTEND_BUCKET}" \
  --delete \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE_NAME}"

echo
echo "[Deploy] Create CloudFront invalidation"
INVALIDATION_ID="$(aws cloudfront create-invalidation \
  --distribution-id "${DIST_ID}" \
  --paths "/*" \
  --profile "${AWS_PROFILE_NAME}" \
  --query "Invalidation.Id" \
  --output text)"
echo "[Info] InvalidationId=${INVALIDATION_ID}"

if [[ "${WAIT_INVALIDATION:-true}" == "true" ]]; then
  echo "[Wait] Waiting for invalidation completion..."
  aws cloudfront wait invalidation-completed \
    --distribution-id "${DIST_ID}" \
    --id "${INVALIDATION_ID}" \
    --profile "${AWS_PROFILE_NAME}"
fi

echo
echo "[Check] Expected values from stack outputs"
echo "  clientId=${USER_POOL_CLIENT_ID}"
echo "  secretApiUrl=${SECRET_API_URL}"
echo "  cognitoDomainPrefix=${COGNITO_DOMAIN_PREFIX}"

echo
echo "[Check] Deployed index snippet"
TMP_HTML="$(mktemp)"
curl -fsSL "${FRONTEND_URL}" > "${TMP_HTML}"
grep -nE "clientId:|secretApiUrl:|cognitoDomainPrefix:" "${TMP_HTML}" || true
rm -f "${TMP_HTML}"

echo
echo "SUCCESS: frontend sync + invalidation complete."
echo "Next: open ${FRONTEND_URL} and run 'Run Diagnostics' then 'Call /secret'."
