# Phase 3: フロントエンド配信（S3 + CloudFront）実行手順

## 1. このフェーズの目的

Phase 3 では、最小のフロントエンドを作成し、CloudFront 経由で表示できる状態にします。

このフェーズで作るもの:

- フロントエンドの最小静的ファイル
- frontend-dispatch 用の CloudFormation テンプレート
- S3 配信 + CloudFront 配信の導線

最初のゴール:

- CloudFront URL で画面が表示されること

## 2. 開始前チェック

```bash
aws sts get-caller-identity --profile "$AWS_PROFILE_NAME"
```

```bash
export AWS_REGION=ap-northeast-1
export PROJECT=aws-cfn-tutorial
export ENV=dev

export BOOTSTRAP_STACK=${PROJECT}-${ENV}-bootstrap
export APP_STACK=${PROJECT}-${ENV}-application
export FE_STACK=${PROJECT}-${ENV}-frontend-dispatch
```

確認ポイント:

- Phase 1 の bootstrap スタックが作成済み
- Phase 2 の application スタックが作成済み

## 3. このフェーズで最初に作るファイル

1. `frontend/index.html`
2. `infrastructure/templates/frontend-dispatch/template.yaml`

必要なら後で追加するもの:

- `frontend/styles.css`
- `frontend/app.js`
- `infrastructure/scripts/deploy_frontend.sh`

## 4. 先に決める実装方針

Phase 3 は表示確認が目的なので、まずは最小構成にします。

- 初回は静的 1 ページだけでよい
- 認証連携（Cognito）はこのフェーズでは実装しない
- WAF 連携は Phase 4 で追加する
- まず S3 + CloudFront の配信成立を優先する

## 5. 作業ステップ

### Step 1. フロントエンド最小ページを作る

```bash
mkdir -p frontend
cat > frontend/index.html <<'EOF'
<!doctype html>
<html lang="ja">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>AWS CFN Tutorial</title>
  </head>
  <body>
    <h1>Phase 3 Frontend Ready</h1>
    <p>S3 + CloudFront 配信の確認ページです。</p>
  </body>
</html>
EOF
```

確認ポイント:

- `frontend/index.html` が存在する

### Step 2. frontend-dispatch テンプレートを作る

`infrastructure/templates/frontend-dispatch/template.yaml` に次のリソースを定義します。

1. CloudFront Distribution
2. OAC（Origin Access Control）
3. S3 バケットポリシー（CloudFront OAC のみ許可）

最小要件:

- Origin は Phase 1 で作った FrontendBucket を参照する
- DefaultRootObject は `index.html`
- Outputs に CloudFront URL を出す

### Step 3. テンプレートを検証する

```bash
aws cloudformation validate-template \
  --profile "$AWS_PROFILE_NAME" \
  --template-body file://infrastructure/templates/frontend-dispatch/template.yaml
```

確認ポイント:

- エラーなく成功すること

### Step 4. frontend-dispatch スタックをデプロイする

```bash
FRONTEND_BUCKET="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendBucketName'].OutputValue" \
  --output text)"

aws cloudformation deploy \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --template-file infrastructure/templates/frontend-dispatch/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides EnvironmentName="$ENV" Project="$PROJECT" FrontendBucketName="$FRONTEND_BUCKET"
```

失敗時の確認:

```bash
aws cloudformation describe-stack-events \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
  --output table

aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].StackStatus" \
  --output text

# ステータスが ROLLBACK_COMPLETE の場合のみ削除して再作成
aws cloudformation delete-stack \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK"
```

確認ポイント:

- デプロイが成功すること

### Step 5. FrontendBucket にファイルを配置する

まずバケット名を取得します。

```bash
FRONTEND_BUCKET=$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendBucketName'].OutputValue" \
  --output text)
```

次にアップロードします。

```bash
aws s3 sync frontend/ "s3://${FRONTEND_BUCKET}" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --delete
```

確認ポイント:

- `index.html` がバケットに配置されること

### Step 6. CloudFront URL を取得する

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table
```

確認ポイント:

- CloudFront のドメイン名（または URL）が取れること

### Step 7. 表示確認

ブラウザで CloudFront URL を開くか、`curl` で確認します。

```bash
curl "https://<CloudFrontDomainName>/"
```

期待値:

- `Phase 3 Frontend Ready` が含まれる HTML が返る

## 8. よくある失敗と対処

### 8.1 S3 バケットがパブリックアクセス拒否で 403

症状:

- CloudFront で `403 Forbidden`

対処:

- OAC 設定とバケットポリシーの Principal/Condition を再確認する

### 8.2 index.html が表示されない

症状:

- 404 またはディレクトリ一覧エラー

対処:

- CloudFront の `DefaultRootObject` が `index.html` か確認する

### 8.3 反映が遅い

症状:

- 最新ファイルが表示されない

対処:

- CloudFront invalidation（`/*`）を実行する

## 9. 完了条件（Definition of Done）

以下すべてを満たしたら Phase 3 完了です。

- frontend-dispatch スタックが `CREATE_COMPLETE` または `UPDATE_COMPLETE`
- CloudFront 経由で `index.html` が表示される
- FrontendBucket がパブリック公開されていない

## 10. 次に進む前の確認

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].[StackName,StackStatus]" \
  --output table
```

問題なければ、次は Phase 4（WAF 追加）へ進みます。
