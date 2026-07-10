# Phase 5: Cognito 認証追加（PKCE）実行手順

## 1. このフェーズの目的

Phase 5 では、Cognito を使ってログイン可能にし、認証付き API の呼び出し確認まで進めます。

このフェーズで作るもの:

- Cognito User Pool
- Cognito App Client（Authorization Code + PKCE）
- Cognito Domain
- API Gateway の Cognito Authorizer（認証付き API 用）
- フロントエンドのログイン導線（最小）

最初のゴール:

- ブラウザでログインし、アクセストークン付きで認証 API を呼べること

## 2. 開始前チェック

```bash
aws sts get-caller-identity --profile "$AWS_PROFILE_NAME"
```

```bash
export AWS_REGION=ap-northeast-1
export PROJECT=aws-cfn-tutorial
export ENV=dev

export APP_STACK=${PROJECT}-${ENV}-application
export FE_STACK=${PROJECT}-${ENV}-frontend-dispatch
```

確認ポイント:

- Phase 2（application）と Phase 3（frontend）が完了していること
- フロントエンドが CloudFront 経由で表示できること

## 3. このフェーズで最初に更新するファイル

1. `infrastructure/templates/application/template.yaml`
2. `frontend/index.html`（または `frontend/app.js`）

必要なら後で追加するもの:

- `frontend/auth/` 配下の分離ファイル

## 4. 先に決める実装方針

最初は最小構成で進めます。

- 認証方式は Authorization Code + PKCE
- App Client Secret は作らない（SPA 前提）
- 認証対象 API は 1 つだけ（例: `/secret`）
- まず動かすことを優先し、画面 UX は後で改善

## 5. 作業ステップ

### Step 1. application テンプレートに Cognito リソースを追加する

`infrastructure/templates/application/template.yaml` に次を追加します。

1. `AWS::Cognito::UserPool`
2. `AWS::Cognito::UserPoolClient`
3. `AWS::Cognito::UserPoolDomain`

最小要件:

- `AllowedOAuthFlowsUserPoolClient: true`
- `AllowedOAuthFlows: [code]`
- `AllowedOAuthScopes: [openid, email, profile]`
- `GenerateSecret: false`
- `CallbackURLs` は CloudFront URL に合わせる

### Step 2. API 側に認証付きエンドポイントを追加する

application テンプレートに以下を追加します。

1. API Gateway Cognito Authorizer
2. 認証付き API（例: `GET /secret`）

最小要件:

- `AuthorizationType: COGNITO_USER_POOLS`
- `AuthorizerId` が Cognito Authorizer を参照

実装チェックポイント（このプロジェクトの最小構成）:

- `AWS::ApiGateway::Authorizer` を追加
- `GET /secret` を追加（`AuthorizationType: COGNITO_USER_POOLS`）
- `OPTIONS /secret` を追加（CORS プリフライト用）
- Lambda Permission に `GET /secret` の `SourceArn` を追加
- `AWS::ApiGateway::Deployment` の `DependsOn` に `/secret` の Method を追加

### Step 3. Outputs を追加する

application テンプレートの Outputs に次を追加します。

- `UserPoolId`
- `UserPoolClientId`
- `CognitoDomain`
- `CognitoIssuer`
- `ApiBaseUrl`（必要なら）

確認ポイント:

- フロントエンド側で必要値を取得できること

### Step 4. テンプレートを検証する

```bash
aws cloudformation validate-template \
  --profile "$AWS_PROFILE_NAME" \
  --template-body file://infrastructure/templates/application/template.yaml
```

確認ポイント:

- エラーなく成功すること

### Step 5. デプロイ用パラメータを準備する

先に CloudFront URL を取得し、Cognito の redirect パラメータへ渡します。

```bash
export FRONTEND_URL="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendURL'].OutputValue | [0]" \
  --output text)"

export FRONTEND_CALLBACK_URL="$FRONTEND_URL"
export FRONTEND_LOGOUT_URL="$FRONTEND_URL"
```

次に、既存スタックの Lambda Artifact パラメータを取得します。

```bash
export LAMBDA_BUCKET="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].Parameters[?ParameterKey=='LambdaCodeS3Bucket'].ParameterValue | [0]" \
  --output text)"

export LAMBDA_KEY="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].Parameters[?ParameterKey=='LambdaCodeS3Key'].ParameterValue | [0]" \
  --output text)"
```

### Step 6. Lambda コードを再アップロードする

`backend/functions/hello/app.py` を更新しているため、deploy 前に zip を再作成して同じ S3 キーへアップロードします。

```bash
(cd backend/functions/hello && zip -q hello-function.zip app.py)

aws s3 cp backend/functions/hello/hello-function.zip "s3://${LAMBDA_BUCKET}/${LAMBDA_KEY}" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME"
```

### Step 7. application スタックを再デプロイする

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --template-file infrastructure/templates/application/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EnvironmentName="$ENV" \
    Project="$PROJECT" \
    LambdaCodeS3Bucket="$LAMBDA_BUCKET" \
    LambdaCodeS3Key="$LAMBDA_KEY" \
    FrontendCallbackUrl="$FRONTEND_CALLBACK_URL" \
    FrontendLogoutUrl="$FRONTEND_LOGOUT_URL"
```

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].[StackName,StackStatus,StackStatusReason]" \
  --output table
```

確認ポイント:

- `UPDATE_COMPLETE` になること

### Step 8. Cognito 設定値を取得する

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table
```

確認ポイント:

- `UserPoolClientId` など必要値が取得できること

### Step 9. 未ログインで `/secret` が拒否されることを確認する

```bash
curl -i "$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='SecretApiUrl'].OutputValue | [0]" \
  --output text)"
```

確認ポイント:

- `401` または `403` が返ること（認証なしアクセス拒否）

### Step 10. フロントエンドに最小ログイン導線を追加する

最小実装:

- ログインボタン（Cognito Hosted UI へ遷移）
- リダイレクト後に `code` を受け取りトークン交換
- アクセストークンを使って `/secret` を呼ぶ

このリポジトリでは `frontend/index.html` の `CONFIG` を更新します。

`CONFIG` へ設定する値:

- `region`: `ap-northeast-1`
- `clientId`: Output の `UserPoolClientId`
- `cognitoDomainPrefix`: Output の `CognitoDomain`
- `secretApiUrl`: `/prod/secret`（CloudFront 経由の同一オリジン呼び出し）

この手順では、`frontend-dispatch` に API Gateway origin を追加して
`/prod/*` を API 側へ転送します。これによりブラウザ CORS 依存を下げられます。

`frontend/index.html` 更新後に S3 へ再配置:

```bash
aws s3 sync frontend/ "s3://$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "${PROJECT}-${ENV}-bootstrap" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendBucketName'].OutputValue | [0]" \
  --output text)" \
  --delete \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME"
```

CloudFront 反映待ち後の確認:

```bash
# アクセス先の url を取得
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendURL'].OutputValue | [0]" \
  --output text
```

1. `Login with Cognito` で Hosted UI へ遷移できる
2. ログイン後にページへ戻る
3. `Call /secret` で `200` が返る

Hosted UI の `username` は Cognito User Pool 内のユーザー名です。
初回はユーザーが未作成なので、CLI でテストユーザーを作成します（AWS Console 不要）。

```bash
export USER_POOL_ID="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue | [0]" \
  --output text)"

aws cognito-idp admin-create-user \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --user-pool-id "$USER_POOL_ID" \
  --username testuser01 \
  --user-attributes Name=email,Value=your-email@example.com Name=email_verified,Value=true \
  --message-action SUPPRESS

aws cognito-idp admin-set-user-password \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --user-pool-id "$USER_POOL_ID" \
  --username testuser01 \
  --password 'TmpPassw0rd!2026' \
  --permanent
```

ログイン画面には次を入力します。

- username: `testuser01`
- password: `TmpPassw0rd!2026`

確認ポイント:

- ログイン後に認証 API 呼び出し結果が表示されること

### Step 11. 動作確認

1. 未ログインで認証 API を呼ぶ

- 期待値: 401/403

1. ログイン後に認証 API を呼ぶ

- 期待値: 200

ショートカット（CLI で一括確認）:

```bash
chmod +x infrastructure/scripts/verify_phase5_auth.sh
AWS_PROFILE_NAME="$AWS_PROFILE_NAME" infrastructure/scripts/verify_phase5_auth.sh
```

任意のユーザーで実行する場合:

```bash
TEST_USERNAME="testuser01" \
TEST_PASSWORD='TmpPassw0rd!2026' \
AWS_PROFILE_NAME="$AWS_PROFILE_NAME" \
infrastructure/scripts/verify_phase5_auth.sh
```

## 6. 失敗時の確認

### 6.1 Callback URL 不一致

症状:

- Hosted UI から戻る時に `redirect_mismatch`

対処:

- User Pool Client の `CallbackURLs` を CloudFront URL と一致させる

### 6.2 Authorizer 設定ミス

症状:

- ログイン後も API が 401/403

対処:

- API Method の `AuthorizationType` と `AuthorizerId` を再確認

### 6.3 PKCE フローの token 交換失敗

症状:

- `invalid_grant` など

対処:

- `code_verifier` と `code_challenge` の対応を確認

### 6.4 CognitoUserPoolDomain の CREATE_FAILED

症状:

- `Invalid request provided: AWS::Cognito::UserPoolDomain`

対処:

- Domain prefix を英小文字・数字・ハイフンのみの形式にする
- `aws` など予約語と衝突しやすい prefix を避ける
- 一意性のため account id / region を含める

### 6.5 `Call /secret` が `TypeError: Failed to fetch`

症状:

- ブラウザで `Call /secret` 実行時に `TypeError: Failed to fetch`

対処:

- API Gateway の `UNAUTHORIZED` / `ACCESS_DENIED` 応答に CORS ヘッダーを付与する
- 追加で `DEFAULT_4XX` / `DEFAULT_5XX` にも CORS ヘッダーを付与する
- `AWS::ApiGateway::GatewayResponse` を追加後、application スタックを再デプロイする
- その後、ブラウザをハードリロードして再確認する

まずは次を実行して、フロント再配信と CloudFront キャッシュ無効化をまとめて行ってください。

```bash
chmod +x infrastructure/scripts/refresh_frontend_phase5.sh
AWS_PROFILE_NAME="$AWS_PROFILE_NAME" infrastructure/scripts/refresh_frontend_phase5.sh
```

`frontend/index.html` には `Run Diagnostics` ボタンを追加済みです。
再配信後にブラウザでこれを押すと、以下が JSON で確認できます。

- preflight (`OPTIONS`) の status と CORS ヘッダー
- no auth (`GET`) の status
- token 付き (`GET`) の status または network_error の詳細

`network_error` が続く場合は、その JSON をそのまま貼ってください。

追加対処（Authorization 付き preflight 失敗が疑われる場合）:

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --template-file infrastructure/templates/application/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EnvironmentName="$ENV" \
    Project="$PROJECT" \
    LambdaCodeS3Bucket="$LAMBDA_BUCKET" \
    LambdaCodeS3Key="$LAMBDA_KEY" \
    FrontendCallbackUrl="$FRONTEND_CALLBACK_URL" \
    FrontendLogoutUrl="$FRONTEND_LOGOUT_URL"

AWS_PROFILE_NAME="$AWS_PROFILE_NAME" infrastructure/scripts/refresh_frontend_phase5.sh
```

zsh での貼り付け崩れ対策（1 行ずつ実行）:

```bash
export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
export PROJECT="${PROJECT:-aws-cfn-tutorial}"
export ENV="${ENV:-dev}"
export APP_STACK="${PROJECT}-${ENV}-application"
export FE_STACK="${PROJECT}-${ENV}-frontend-dispatch"

export FRONTEND_URL=$(aws cloudformation describe-stacks --region "$AWS_REGION" --profile "$AWS_PROFILE_NAME" --stack-name "$FE_STACK" --query "Stacks[0].Outputs[?OutputKey=='FrontendURL'].OutputValue | [0]" --output text)
export FRONTEND_CALLBACK_URL="$FRONTEND_URL"
export FRONTEND_LOGOUT_URL="$FRONTEND_URL"
export LAMBDA_BUCKET=$(aws cloudformation describe-stacks --region "$AWS_REGION" --profile "$AWS_PROFILE_NAME" --stack-name "$APP_STACK" --query "Stacks[0].Parameters[?ParameterKey=='LambdaCodeS3Bucket'].ParameterValue | [0]" --output text)
export LAMBDA_KEY=$(aws cloudformation describe-stacks --region "$AWS_REGION" --profile "$AWS_PROFILE_NAME" --stack-name "$APP_STACK" --query "Stacks[0].Parameters[?ParameterKey=='LambdaCodeS3Key'].ParameterValue | [0]" --output text)

aws cloudformation deploy --region "$AWS_REGION" --profile "$AWS_PROFILE_NAME" --stack-name "$APP_STACK" --template-file infrastructure/templates/application/template.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides EnvironmentName="$ENV" Project="$PROJECT" LambdaCodeS3Bucket="$LAMBDA_BUCKET" LambdaCodeS3Key="$LAMBDA_KEY" FrontendCallbackUrl="$FRONTEND_CALLBACK_URL" FrontendLogoutUrl="$FRONTEND_LOGOUT_URL"

AWS_PROFILE_NAME="$AWS_PROFILE_NAME" infrastructure/scripts/refresh_frontend_phase5.sh
```

この更新では `Access-Control-Allow-Headers` を拡張し、
`frontend/index.html` は `access_token` 優先で `/secret` を呼び、失敗時に別トークンへ自動再試行します。

さらに追加で、API Gateway の `EXPIRED_TOKEN` / `INVALID_SIGNATURE` /
`AUTHORIZER_FAILURE` / `AUTHORIZER_CONFIGURATION_ERROR` にも CORS ヘッダーを付与しました。
ブラウザで `TypeError: Failed to fetch` が出る場合の取りこぼしを減らすためです。

`frontend/index.html` はログイン開始時に保存済みトークンをクリアし、
期限切れ JWT を優先的に使わないよう更新済みです。

さらに「どうせまた失敗する」前提の復旧手順として、
`infrastructure/scripts/recover_phase5_browser.sh` を追加しました。
このスクリプトは以下を順番に自動実行します。

- application 再デプロイ
- frontend-dispatch 再デプロイ（`/prod/*` を API Gateway へ転送）
- CLI 認証確認（`verify_phase5_auth.sh`）
- frontend 再配信 + CloudFront invalidation（`refresh_frontend_phase5.sh`）

実行:

```bash
chmod +x infrastructure/scripts/recover_phase5_browser.sh
AWS_PROFILE_NAME="$AWS_PROFILE_NAME" infrastructure/scripts/recover_phase5_browser.sh
```

実行後、ブラウザで次の順番を固定してください。

1. `Hard Reset Session`
2. `Login with Cognito`
3. `Run Diagnostics`
4. `Call /secret`

## 7. 完了条件（Definition of Done）

以下すべてを満たしたら Phase 5 完了です。

- Cognito リソースが application スタックに作成済み
- フロントエンドからログインできる
- 未ログイン API 呼び出しは拒否される
- ログイン後 API 呼び出しは成功する

## 8. 次に進む前の確認

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].[StackName,StackStatus]" \
  --output table
```

問題なければ、次は Phase 6（レート制限）へ進みます。
