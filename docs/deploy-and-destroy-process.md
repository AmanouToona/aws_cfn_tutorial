# CloudFormation ベースのデプロイ/完全削除手順（AWS コンソール不要）

## 1. 目的

この手順書は、AWS コンソールを手で操作せず、CloudFormation / SAM と AWS CLI のみで
以下を実行するためのものです。

- デプロイ（作成/更新）
- 動作確認
- チュートリアル終了時の完全削除

## 2. 前提条件

- AWS CLI 設定済み（`aws configure` 済み）
- SAM CLI インストール済み
- `jq` インストール済み（CloudFront 設定 JSON を編集するため）
- 実行リージョンを決定済み（例: `ap-northeast-1`）
- プロジェクトルートでコマンドを実行する

## 3. 環境変数の設定

```bash
export AWS_REGION=ap-northeast-1
export PROJECT=aws-cfn-tutorial
export ENV=dev

export BOOTSTRAP_STACK=${PROJECT}-${ENV}-bootstrap
export WAF_STACK=${PROJECT}-${ENV}-waf
export APP_STACK=${PROJECT}-${ENV}-application
export FE_STACK=${PROJECT}-${ENV}-frontend-dispatch
```

## 4. デプロイ順序（CloudFormation/SAMのみ）

### 4.1 Bootstrap

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$BOOTSTRAP_STACK" \
  --template-file infrastructure/templates/bootstrap/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides Environment="$ENV" Project="$PROJECT"
```

### 4.2 WAF

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$WAF_STACK" \
  --template-file infrastructure/templates/waf/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides Environment="$ENV" Project="$PROJECT"
```

### 4.3 Application（API/Lambda/Cognito/DynamoDB）

```bash
sam build --template-file infrastructure/templates/application/template.yaml

sam deploy \
  --region "$AWS_REGION" \
  --stack-name "$APP_STACK" \
  --template-file infrastructure/templates/application/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --resolve-s3 \
  --parameter-overrides Environment="$ENV" Project="$PROJECT"
```

### 4.4 Frontend-Dispatch（CloudFront + WAF + S3 + API 紐付け）

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$FE_STACK" \
  --template-file infrastructure/templates/frontend-dispatch/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides Environment="$ENV" Project="$PROJECT"
```

### 4.5 フロントエンド配信（CLIで実行）

```bash
# 1) フロントエンドをビルド
cd frontend
npm ci
npm run build
cd ..

# 2) バケット名を CloudFormation 出力から取得
FRONTEND_BUCKET=$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --stack-name "$BOOTSTRAP_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendBucketName'].OutputValue" \
  --output text)

# 3) S3 へ同期
aws s3 sync frontend/dist "s3://${FRONTEND_BUCKET}" --delete

# 4) CloudFront Distribution ID を取得してキャッシュ無効化
DISTRIBUTION_ID=$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" \
  --output text)

aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*"
```

## 5. 状態確認（CLIのみ）

```bash
aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$BOOTSTRAP_STACK" --query "Stacks[0].StackStatus"
aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$WAF_STACK" --query "Stacks[0].StackStatus"
aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$APP_STACK" --query "Stacks[0].StackStatus"
aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$FE_STACK" --query "Stacks[0].StackStatus"
```

期待値:

- すべて `CREATE_COMPLETE` または `UPDATE_COMPLETE`

## 6. 完全削除手順（チュートリアル終了時）

削除は依存関係の都合で、配信側から順番に行います。

### 6.1 CloudFront を先に無効化してから削除

```bash
# Distribution ID を取得
DISTRIBUTION_ID=$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" \
  --output text)

# 設定を取得
aws cloudfront get-distribution-config --id "$DISTRIBUTION_ID" > /tmp/cf-config.json

# ETag を取得
ETAG=$(jq -r '.ETag' /tmp/cf-config.json)

# Enabled を false にして更新用 JSON を作成（jq 必須）
jq '.DistributionConfig | .Enabled=false' /tmp/cf-config.json > /tmp/cf-disable-config.json

aws cloudfront update-distribution \
  --id "$DISTRIBUTION_ID" \
  --if-match "$ETAG" \
  --distribution-config "$(cat /tmp/cf-disable-config.json)"

# Deployed になるまで待つ
aws cloudfront wait distribution-deployed --id "$DISTRIBUTION_ID"
```

注記:

- CloudFront 削除前に Disabled が必要なため、この手順を先に実施する

### 6.2 スタックを逆順で削除

```bash
aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$FE_STACK"
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$FE_STACK"

aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$APP_STACK"
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$APP_STACK"

aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$WAF_STACK"
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$WAF_STACK"

aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$BOOTSTRAP_STACK"
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$BOOTSTRAP_STACK"
```

### 6.3 バケットの残骸を削除（必要時のみ）

```bash
# 例: 残っている場合のみ空にする
aws s3 rm "s3://${PROJECT}-${ENV}-frontend" --recursive || true
aws s3 rm "s3://${PROJECT}-${ENV}-artifacts" --recursive || true
```

### 6.4 最終確認

```bash
aws cloudformation list-stacks \
  --region "$AWS_REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED ROLLBACK_COMPLETE UPDATE_ROLLBACK_COMPLETE \
  --query "StackSummaries[?contains(StackName, '${PROJECT}-${ENV}')].[StackName,StackStatus]" \
  --output table
```

期待値:

- 対象スタックが一覧に出ない、または `DELETE_COMPLETE`

## 7. よくあるハマりどころ

- S3 バケットが空でないとスタック削除に失敗する
- CloudFront が有効状態のままだと削除に失敗する
- IAM ロールを手動変更すると、テンプレートとの差分で更新失敗しやすい

## 8. 追加の改善（任意）

- `infrastructure/scripts/deploy.sh` と `infrastructure/scripts/destroy.sh` にコマンドをまとめる
- GitHub Actions から同じ手順を呼び出し、ローカルと CI の挙動を一致させる
