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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LAMBDA_DIR="${REPO_ROOT}/backend/functions/hello"

if [[ ! -f "${LAMBDA_DIR}/app.py" ]]; then
  echo "ERROR: Lambda source not found: ${LAMBDA_DIR}/app.py"
  exit 1
fi

ARTIFACT_BUCKET="$(aws cloudformation describe-stacks \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE_NAME}" \
  --stack-name "${BOOTSTRAP_STACK}" \
  --query "Stacks[0].Outputs[?OutputKey=='ArtifactBucketName'].OutputValue" \
  --output text)"

if [[ -z "${ARTIFACT_BUCKET}" || "${ARTIFACT_BUCKET}" == "None" ]]; then
  echo "ERROR: ArtifactBucketName output not found in stack ${BOOTSTRAP_STACK}."
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

ZIP_PATH="${TMP_DIR}/hello-function.zip"
S3_KEY="lambda/hello/${ENV}/hello-function.zip"

(
  cd "${LAMBDA_DIR}"
  zip -q "${ZIP_PATH}" app.py
)

echo "Uploading lambda artifact to s3://${ARTIFACT_BUCKET}/${S3_KEY}"
aws s3 cp "${ZIP_PATH}" "s3://${ARTIFACT_BUCKET}/${S3_KEY}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE_NAME}"

echo "Validating CloudFormation template"
aws cloudformation validate-template \
  --profile "${AWS_PROFILE_NAME}" \
  --template-body "file://${REPO_ROOT}/infrastructure/templates/application/template.yaml"

echo "Deploying stack ${APP_STACK}"
aws cloudformation deploy \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE_NAME}" \
  --stack-name "${APP_STACK}" \
  --template-file "${REPO_ROOT}/infrastructure/templates/application/template.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EnvironmentName="${ENV}" \
    Project="${PROJECT}" \
    LambdaCodeS3Bucket="${ARTIFACT_BUCKET}" \
    LambdaCodeS3Key="${S3_KEY}"

HELLO_API_URL="$(aws cloudformation describe-stacks \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE_NAME}" \
  --stack-name "${APP_STACK}" \
  --query "Stacks[0].Outputs[?OutputKey=='HelloApiUrl'].OutputValue" \
  --output text)"

echo "Deployment completed."
echo "Hello API URL: ${HELLO_API_URL}"
echo "Try: curl \"${HELLO_API_URL}\""
