# Phase 9: 完全削除（チュートリアル終了処理）実行手順

## 1. このフェーズの目的

学習環境を、課金リスクを残さずに安全に閉じます。

このフェーズで行うこと:

- CloudFront ディストリビューションの無効化と削除
- `frontend-dispatch` / `application` / `waf` / `bootstrap` スタックの削除
- 残存 S3 オブジェクト・CloudWatch ロググループの確認と削除
- 全スタックが `DELETE_COMPLETE` であることの最終確認

このフェーズのゴール:

- `aws cloudformation list-stacks` で関連スタックが残っていないこと
- 想定外の課金リソースが残っていないこと

## 2. 前提条件

- Phase 8 まで完了している
- `bootstrap` / `waf` / `application` / `frontend-dispatch` スタックが存在する

環境変数:

```bash
export AWS_REGION=ap-northeast-1
export AWS_WAF_REGION=us-east-1
export PROJECT=aws-cfn-tutorial
export ENV=dev

export BOOTSTRAP_STACK=${PROJECT}-${ENV}-bootstrap
export WAF_STACK=${PROJECT}-${ENV}-waf
export APP_STACK=${PROJECT}-${ENV}-application
export FE_STACK=${PROJECT}-${ENV}-frontend-dispatch
export OIDC_STACK=${PROJECT}-${ENV}-github-oidc
```

## 3. 削除の基本方針

- 依存関係の都合上、**配信側（CloudFront）→ アプリ側 → 土台（bootstrap）** の順に削除する
- S3 バケットは中身が空でないとスタック削除に失敗するため、**bootstrap スタック削除前に必ず空にする**
- CloudFront はディストリビューションが有効なままだと削除できないため、**先に無効化してから delete-stack を呼ぶ**

## 4. 作業ステップ

### Step 0. Distribution ID の Output を反映する

`frontend-dispatch/template.yaml` の Outputs に `CloudFrontDistributionId` を追加済みです。まだ反映していない場合は再デプロイしておきます（Phase 8 で使った `CF_LOG_BUCKET` などの変数がすでに揃っている前提です）。

```bash
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

### Step 1. CloudFront ディストリビューションを無効化する

Distribution ID を取得します。

```bash
DISTRIBUTION_ID="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue | [0]" \
  --output text)"

echo "$DISTRIBUTION_ID"
```

現在の設定と ETag を取得し、`Enabled` を `false` にして更新します（`jq` が必要です）。

```bash
aws cloudfront get-distribution-config \
  --profile "$AWS_PROFILE_NAME" \
  --id "$DISTRIBUTION_ID" > /tmp/cf-config.json

ETAG="$(jq -r '.ETag' /tmp/cf-config.json)"

jq '.DistributionConfig | .Enabled = false' /tmp/cf-config.json > /tmp/cf-disable-config.json

aws cloudfront update-distribution \
  --profile "$AWS_PROFILE_NAME" \
  --id "$DISTRIBUTION_ID" \
  --if-match "$ETAG" \
  --distribution-config file:///tmp/cf-disable-config.json
```

無効化が世界中に反映されるまで待ちます（数分〜十数分かかります）。

```bash
aws cloudfront wait distribution-deployed \
  --profile "$AWS_PROFILE_NAME" \
  --id "$DISTRIBUTION_ID"
```

補足:

- CloudFront は `Enabled: false` かつ `Deployed` 状態でないと削除できません
- `wait` はブロッキングなので、しばらく戻ってこなくても正常です

### Step 2. frontend-dispatch スタックを削除する

```bash
aws cloudformation delete-stack \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK"

aws cloudformation wait stack-delete-complete \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK"
```

### Step 3. application スタックを削除する

```bash
aws cloudformation delete-stack \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK"

aws cloudformation wait stack-delete-complete \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK"
```

### Step 4. waf スタックを削除する（us-east-1）

CloudFront 用 WAF は `us-east-1` 管理です。

```bash
aws cloudformation delete-stack \
  --region "$AWS_WAF_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$WAF_STACK"

aws cloudformation wait stack-delete-complete \
  --region "$AWS_WAF_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$WAF_STACK"
```

### Step 5. bootstrap 管理下の S3 バケットを空にする

`bootstrap` スタックは 3 つのバケット（Artifact / Frontend / CloudFront ログ）を作成しています。中身が残っているとスタック削除が失敗するため、先に空にします。

```bash
ARTIFACT_BUCKET="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ArtifactBucketName'].OutputValue | [0]" \
  --output text)"

FRONTEND_BUCKET="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendBucketName'].OutputValue | [0]" \
  --output text)"

CF_LOG_BUCKET="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontLogBucketName'].OutputValue | [0]" \
  --output text)"

# Artifact / Frontend バケットはバージョニング有効なので、全バージョンを削除する
for BUCKET in "$ARTIFACT_BUCKET" "$FRONTEND_BUCKET"; do
  aws s3api delete-objects \
    --profile "$AWS_PROFILE_NAME" \
    --bucket "$BUCKET" \
    --delete "$(aws s3api list-object-versions \
      --profile "$AWS_PROFILE_NAME" \
      --bucket "$BUCKET" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
      --output json)" 2>/dev/null || true

  aws s3api delete-objects \
    --profile "$AWS_PROFILE_NAME" \
    --bucket "$BUCKET" \
    --delete "$(aws s3api list-object-versions \
      --profile "$AWS_PROFILE_NAME" \
      --bucket "$BUCKET" \
      --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
      --output json)" 2>/dev/null || true
done

# CloudFront ログバケットはバージョニング無効なので通常削除でよい
aws s3 rm "s3://${CF_LOG_BUCKET}" --recursive --profile "$AWS_PROFILE_NAME"
```

補足:

- `delete-objects` はオブジェクトが 0 件だと Malformed Input エラーになることがありますが、`|| true` で無視して問題ありません
- 心配な場合は `aws s3 ls s3://<bucket> --recursive` で空になったか個別に確認してください

### Step 6. bootstrap スタックを削除する

```bash
aws cloudformation delete-stack \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK"

aws cloudformation wait stack-delete-complete \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK"
```

### Step 7. github-oidc スタックを削除する（任意）

IAM ロールのみで課金は発生しませんが、完全に閉じたい場合は削除します。再度 Phase 7 の CI/CD を試す予定があるなら残しておいても問題ありません。

```bash
aws cloudformation delete-stack \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$OIDC_STACK"

aws cloudformation wait stack-delete-complete \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$OIDC_STACK"
```

### Step 8. 残存 CloudWatch ロググループを確認・削除する

Lambda のロググループは、関数を削除しても自動的には消えません。

```bash
aws logs describe-log-groups \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --log-group-name-prefix "/aws/lambda/${PROJECT}" \
  --query "logGroups[].logGroupName" \
  --output table
```

表示されたロググループを削除します（対象ロググループ名に読み替えてください）。

```bash
aws logs delete-log-group \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --log-group-name "/aws/lambda/${PROJECT}-hello-function-${ENV}"
```

API Gateway のアクセスログを有効化していた場合は、そのロググループも同様に確認してください。

```bash
aws logs describe-log-groups \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --log-group-name-prefix "/aws/apigateway/${PROJECT}" \
  --query "logGroups[].logGroupName" \
  --output table
```

## 5. 失敗時の確認

スタック削除が `DELETE_FAILED` になった場合、原因を確認します。

```bash
aws cloudformation describe-stack-events \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "<失敗したスタック名>" \
  --query "StackEvents[?contains(ResourceStatus,'FAILED')].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
  --output table
```

よくある原因:

- S3 バケットが空でない（Step 5 をやり直す）
- CloudFront が `Enabled` のまま、または `Deployed` になっていない（Step 1 の `wait` を待ち直す）
- IAM ロールを手動変更していて、CloudFormation の管理と食い違いが起きている

## 6. 完了条件（Definition of Done）

- `frontend-dispatch` / `application` / `waf` / `bootstrap` スタックがすべて存在しない、または `DELETE_COMPLETE`
- bootstrap 管理下の S3 バケットが 3 つとも存在しない
- 主要な CloudWatch ロググループが残っていない

## 7. 最終確認

```bash
aws cloudformation list-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED ROLLBACK_COMPLETE UPDATE_ROLLBACK_COMPLETE \
  --query "StackSummaries[?contains(StackName, '${PROJECT}-${ENV}')].[StackName,StackStatus]" \
  --output table

aws cloudformation list-stacks \
  --region "$AWS_WAF_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED ROLLBACK_COMPLETE UPDATE_ROLLBACK_COMPLETE \
  --query "StackSummaries[?contains(StackName, '${PROJECT}-${ENV}')].[StackName,StackStatus]" \
  --output table
```

期待値:

- 対象スタックが一覧に出ない（＝完全に削除済み）

問題なければ、学習環境のクローズは完了です。再度チュートリアルを実施する場合は Phase 0 から作り直します。
