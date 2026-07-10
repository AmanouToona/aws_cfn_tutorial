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
APP_STACK="${PROJECT}-${ENV}-application"
FE_STACK="${PROJECT}-${ENV}-frontend-dispatch"

export AWS_REGION PROJECT ENV BOOTSTRAP_STACK APP_STACK FE_STACK

echo "[Info] Recovery start"
echo "[Info] AWS_REGION=${AWS_REGION}"
echo "[Info] APP_STACK=${APP_STACK}"
echo "[Info] FE_STACK=${FE_STACK}"

echo
echo "[Step 1] Resolve deploy parameters"
FRONTEND_URL=$(aws cloudformation describe-stacks --region "${AWS_REGION}" --profile "${AWS_PROFILE_NAME}" --stack-name "${FE_STACK}" --query "Stacks[0].Outputs[?OutputKey=='FrontendURL'].OutputValue | [0]" --output text)
FRONTEND_CALLBACK_URL="${FRONTEND_URL}"
FRONTEND_LOGOUT_URL="${FRONTEND_URL}"
LAMBDA_BUCKET=$(aws cloudformation describe-stacks --region "${AWS_REGION}" --profile "${AWS_PROFILE_NAME}" --stack-name "${APP_STACK}" --query "Stacks[0].Parameters[?ParameterKey=='LambdaCodeS3Bucket'].ParameterValue | [0]" --output text)
LAMBDA_KEY=$(aws cloudformation describe-stacks --region "${AWS_REGION}" --profile "${AWS_PROFILE_NAME}" --stack-name "${APP_STACK}" --query "Stacks[0].Parameters[?ParameterKey=='LambdaCodeS3Key'].ParameterValue | [0]" --output text)
FRONTEND_BUCKET=$(aws cloudformation describe-stacks --region "${AWS_REGION}" --profile "${AWS_PROFILE_NAME}" --stack-name "${BOOTSTRAP_STACK}" --query "Stacks[0].Outputs[?OutputKey=='FrontendBucketName'].OutputValue | [0]" --output text)
FRONTEND_WEB_ACL_ARN=$(aws cloudformation describe-stacks --region "${AWS_REGION}" --profile "${AWS_PROFILE_NAME}" --stack-name "${FE_STACK}" --query "Stacks[0].Parameters[?ParameterKey=='FrontendWebAclArn'].ParameterValue | [0]" --output text)

echo
echo "[Step 2] Deploy application template"
aws cloudformation deploy --region "${AWS_REGION}" --profile "${AWS_PROFILE_NAME}" --stack-name "${APP_STACK}" --template-file infrastructure/templates/application/template.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides EnvironmentName="${ENV}" Project="${PROJECT}" LambdaCodeS3Bucket="${LAMBDA_BUCKET}" LambdaCodeS3Key="${LAMBDA_KEY}" FrontendCallbackUrl="${FRONTEND_CALLBACK_URL}" FrontendLogoutUrl="${FRONTEND_LOGOUT_URL}"

API_GATEWAY_DOMAIN_NAME=$(aws cloudformation describe-stacks --region "${AWS_REGION}" --profile "${AWS_PROFILE_NAME}" --stack-name "${APP_STACK}" --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayDomainName'].OutputValue | [0]" --output text)
if [[ -z "${API_GATEWAY_DOMAIN_NAME}" || "${API_GATEWAY_DOMAIN_NAME}" == "None" ]]; then
  SECRET_API_URL=$(aws cloudformation describe-stacks --region "${AWS_REGION}" --profile "${AWS_PROFILE_NAME}" --stack-name "${APP_STACK}" --query "Stacks[0].Outputs[?OutputKey=='SecretApiUrl'].OutputValue | [0]" --output text)
  API_GATEWAY_DOMAIN_NAME=$(echo "${SECRET_API_URL}" | sed -E 's#https?://([^/]+)/.*#\1#')
fi

if [[ "${FRONTEND_WEB_ACL_ARN}" == "None" ]]; then
  FRONTEND_WEB_ACL_ARN=""
fi

echo
echo "[Step 2.5] Deploy frontend-dispatch with API proxy behavior"
aws cloudformation deploy --region "${AWS_REGION}" --profile "${AWS_PROFILE_NAME}" --stack-name "${FE_STACK}" --template-file infrastructure/templates/frontend-dispatch/template.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides EnvironmentName="${ENV}" Project="${PROJECT}" FrontendBucketName="${FRONTEND_BUCKET}" FrontendWebAclArn="${FRONTEND_WEB_ACL_ARN}" ApiGatewayDomainName="${API_GATEWAY_DOMAIN_NAME}"

echo
echo "[Step 3] Verify auth path by CLI"
infrastructure/scripts/verify_phase5_auth.sh

echo
echo "[Step 4] Refresh frontend and invalidate CloudFront"
infrastructure/scripts/refresh_frontend_phase5.sh

echo
echo "[Done] Recovery completed"
echo "Open: ${FRONTEND_URL}"
echo "Browser steps:"
echo "  1) Hard Reset Session"
echo "  2) Login with Cognito"
echo "  3) Run Diagnostics"
echo "  4) Call /secret"
echo "If browser still fails, test in private window with extensions disabled."
