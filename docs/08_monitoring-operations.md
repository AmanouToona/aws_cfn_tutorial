# Phase 8: 監視と運用（CloudWatch / WAF / CloudFront）実行手順

## 1. このフェーズの目的

Phase 8 では、障害時にすぐ原因を追えるよう、ログ確認の導線を整えます。

このフェーズで行うこと:

- Lambda / API Gateway のログ確認手順を固定化する
- WAF のブロック確認手順を固定化する
- CloudFront の配信ログを有効化する

このフェーズのゴール:

- 「どこで失敗したか」を CLI だけで切り分けできること

## 2. 前提条件

- Phase 7 まで完了している
- `application` / `frontend-dispatch` / `waf` スタックが存在する

環境変数:

```bash
export AWS_REGION=ap-northeast-1
export AWS_WAF_REGION=us-east-1
export PROJECT=aws-cfn-tutorial
export ENV=dev

export APP_STACK=${PROJECT}-${ENV}-application
export FE_STACK=${PROJECT}-${ENV}-frontend-dispatch
export WAF_STACK=${PROJECT}-${ENV}-waf
```

## 3. 監視の基本方針

- まず Lambda ログを見る
- 次に API Gateway（ステータスコード）を見る
- 次に WAF（ブロック）を見る
- 最後に CloudFront 配信ログで全体の入口を確認する

## 4. 作業ステップ

### Step 1. Lambda ログを確認する

まず最新ログストリームを確認します。

```bash
aws logs describe-log-streams \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --log-group-name "/aws/lambda/${PROJECT}-hello-function-${ENV}" \
  --order-by LastEventTime \
  --descending \
  --max-items 5
```

直近 15 分のエラーを確認します。

```bash
START_MS="$(($(date +%s) * 1000 - 15 * 60 * 1000))"

aws logs filter-log-events \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --log-group-name "/aws/lambda/${PROJECT}-hello-function-${ENV}" \
  --start-time "$START_MS" \
  --filter-pattern '?ERROR ?Exception ?Traceback'
```

### Step 2. API Gateway 4xx / 5xx を確認する

API のヘルス確認を行います。

```bash
HELLO_API_URL="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='HelloApiUrl'].OutputValue | [0]" \
  --output text)"

curl -i "$HELLO_API_URL"
```

必要に応じて API Gateway 側のレスポンス（401/403/429/5xx）を再確認します。

### Step 3. WAF のブロックを確認する

学習用ルールのブロックを確認します。

```bash
FE_URL="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendURL'].OutputValue | [0]" \
  --output text)"

curl -I "${FE_URL}/waf-test-block"
```

期待値:

- `403 Forbidden`

WAF の概要（us-east-1）を確認します。

```bash
aws cloudformation describe-stacks \
  --region "$AWS_WAF_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$WAF_STACK" \
  --query "Stacks[0].[StackName,StackStatus]" \
  --output table
```

### Step 4. CloudFront 標準ログ出力を有効化する

CloudFront ログ保存用バケットを作成します。

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "${PROJECT}-${ENV}-bootstrap" \
  --template-file infrastructure/templates/bootstrap/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EnvironmentName="$ENV" \
    Project="$PROJECT"
```

`infrastructure/templates/frontend-dispatch/template.yaml` の `DistributionConfig` に以下を追加します。

```yaml
Logging:
  Bucket: !Sub "${CloudFrontLogBucketName}.s3.amazonaws.com"
  Prefix: cloudfront/
  IncludeCookies: false
```

あわせて Parameters に `CloudFrontLogBucketName` を追加します。

```yaml
CloudFrontLogBucketName:
  Type: String
  Default: ""
```

ログを有効化したテンプレートを再デプロイします。

```bash
FRONTEND_BUCKET="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "${PROJECT}-${ENV}-bootstrap" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendBucketName'].OutputValue | [0]" \
  --output text)"

WEB_ACL_ARN="$(aws cloudformation describe-stacks \
  --region "$AWS_WAF_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$WAF_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendWebAclArn'].OutputValue | [0]" \
  --output text)"

API_GATEWAY_DOMAIN_NAME="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayDomainName'].OutputValue | [0]" \
  --output text)"

CF_LOG_BUCKET="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "${PROJECT}-${ENV}-bootstrap" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontLogBucketName'].OutputValue | [0]" \
  --output text)"

aws cloudformation deploy \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --template-file infrastructure/templates/frontend-dispatch/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EnvironmentName="$ENV" \
    Project="$PROJECT" \
    FrontendBucketName="$FRONTEND_BUCKET" \
    FrontendWebAclArn="$WEB_ACL_ARN" \
    ApiGatewayDomainName="$API_GATEWAY_DOMAIN_NAME" \
    CloudFrontLogBucketName="$CF_LOG_BUCKET"
```

### Step 5. CloudFront ログの到着を確認する

```bash
aws s3 ls "s3://${CF_LOG_BUCKET}/${PROJECT}-frontend-dispatch/${ENV}/" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --recursive
```

補足:

- ログはリクエスト発生後に配信されます。事前に `curl -I "$FE_URL"` などでアクセスを発生させてから数分待って確認してください

補足:

- CloudFront 標準ログは反映まで数分かかる場合があります

## 5. 失敗時の確認

WAF スタックの失敗（us-east-1）:

```bash
aws cloudformation describe-stack-events \
  --region "$AWS_WAF_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$WAF_STACK" \
  --query "StackEvents[?contains(ResourceStatus,'FAILED')].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
  --output table
```

frontend-dispatch の失敗（ap-northeast-1）:

```bash
aws cloudformation describe-stack-events \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "StackEvents[?contains(ResourceStatus,'FAILED')].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
  --output table
```

## 6. 完了条件（Definition of Done）

- Lambda エラーを CLI で追跡できる
- `/waf-test-block` で 403 が確認できる
- CloudFront 標準ログが S3 に保存される

## 7. 次に進む前の確認

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].[StackName,StackStatus]" \
  --output table
```

問題なければ、Phase 9（完全削除）へ進みます。
