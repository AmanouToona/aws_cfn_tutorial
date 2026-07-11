# Phase 6: レート制限追加 実行手順

## 1. このフェーズの目的

Phase 6 では、認証状態に応じて API の利用回数を制御し、制限超過時に `429 Too Many Requests` を返すところまで進めます。

このフェーズで作るもの:

- レート制限状態を保存する DynamoDB テーブル
- Lambda 内のレート制限判定ロジック
- 未認証ユーザー用の制限
- 認証済みユーザー用の制限

このフェーズのゴール:

- 未認証では 10 回を超えると `429`
- 認証済みでは 100 回を超えると `429`

## 2. 今回の実装方針

今回は API Gateway Usage Plan ではなく、Lambda + DynamoDB で判定します。

理由:

- 今の構成はブラウザ + Cognito 認証が中心で、API Key 前提の Usage Plan とは相性がよくない
- 認証済み / 未認証で制限値を切り替えたい
- 将来的に `pro` / `enterprise` などのプラン別制限へ拡張しやすい

最小実装の考え方:

- 未認証ユーザーは `sourceIp` 単位で識別する
- 認証済みユーザーは Cognito の `sub` 単位で識別する
- 1 分単位の固定ウィンドウでカウントする
- しきい値を超えたら Lambda が `429` を返す

## 3. 開始前チェック

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

- Phase 5 が完了していること
- ブラウザで `/secret` が正常に呼べること
- `infrastructure/scripts/recover_phase5_browser.sh` で復旧できる状態になっていること

## 4. このフェーズで更新するファイル

1. `infrastructure/templates/application/template.yaml`
2. `backend/functions/hello/app.py`
3. 必要なら `frontend/index.html`

追加するもの:

- `docs/06_rate-limiting.md`
- 必要なら検証スクリプト

## 5. 実装ステップ

### Step 1. レート制限テーブルを追加する

`infrastructure/templates/application/template.yaml` に DynamoDB テーブルを追加します。

用途:

- 1 分単位の利用回数を保持する

推奨キー設計:

- Partition Key: `rate_key`

`rate_key` の例:

- 未認証: `anon#<sourceIp>#<YYYYMMDDHHmm>`
- 認証済み: `auth#<sub>#<YYYYMMDDHHmm>`

最小要件:

- `BillingMode: PAY_PER_REQUEST`
- TTL 用属性を持たせる（例: `ttl`）

確認ポイント:

- application テンプレートに `RateLimitTable` が追加されていること

### Step 2. Lambda 実行ロールへ権限を追加する

`HelloFunctionRole` に `RateLimitTable` の読み書き権限を追加します。

最低限必要なアクション:

- `dynamodb:GetItem`
- `dynamodb:PutItem`
- `dynamodb:UpdateItem`

確認ポイント:

- Lambda から RateLimitTable へアクセスできる IAM ポリシーになっていること

### Step 3. Lambda へテーブル名を渡す

`HelloFunction` の `Environment.Variables` にテーブル名を渡します。

例:

- `RATE_LIMIT_TABLE_NAME`

確認ポイント:

- Lambda コード内でテーブル名を環境変数から参照できること

### Step 4. Lambda で識別子を決める

`backend/functions/hello/app.py` で呼び出し元を判定します。

未認証:

- `event.requestContext.identity.sourceIp`

認証済み:

- `event.requestContext.authorizer.claims.sub`

制限値:

- 未認証: `10`
- 認証済み: `100`

確認ポイント:

- 呼び出しごとに「誰として数えるか」が一意に決まること

### Step 5. 1 分ウィンドウで回数を記録する

現在時刻から 1 分単位のウィンドウキーを作成します。

例:

- `202607111530`

処理の流れ:

1. 現在のウィンドウキーを作る
2. `rate_key` を組み立てる
3. DynamoDB のカウンタを 1 増やす
4. しきい値を超えたら `429` を返す

最小実装では、更新と判定を Lambda で完結させます。

確認ポイント:

- 連続呼び出し時にカウントが増えること

### Step 6. 429 応答を返す

制限超過時は JSON で `429` を返します。

返却例:

```json
{ "message": "rate limit exceeded" }
```

CORS を崩さないよう、成功時と同様にヘッダーを付けます。

最低限のヘッダー:

- `Content-Type: application/json`
- `Access-Control-Allow-Origin: *`

確認ポイント:

- 制限超過時にブラウザでも `429` が確認できること

### Step 7. テンプレートを検証する

```bash
aws cloudformation validate-template \
  --profile "$AWS_PROFILE_NAME" \
  --template-body file://infrastructure/templates/application/template.yaml
```

確認ポイント:

- エラーなく成功すること

### Step 8. Lambda を再アップロードして application を再デプロイする

既存の流れに沿って Lambda zip を更新し、application スタックを再デプロイします。

最短では既存スクリプトを使います。

```bash
AWS_PROFILE_NAME="$AWS_PROFILE_NAME" infrastructure/scripts/deploy_application.sh
```

もし `FrontendCallbackUrl` / `FrontendLogoutUrl` が必要な構成差分で失敗する場合は、Phase 5 の復旧スクリプトを使ってください。

```bash
AWS_PROFILE_NAME="$AWS_PROFILE_NAME" infrastructure/scripts/recover_phase5_browser.sh
```

確認ポイント:

- `UPDATE_COMPLETE` になること

### Step 9. 未認証ユーザーの制限を確認する

まず `/hello` か `/secret` のどちらを対象にするか決めます。

このチュートリアルでは、まずは `/hello` を含む共通 Lambda で判定して構いません。

最短では検証スクリプトを使います。

```bash
chmod +x infrastructure/scripts/verify_phase6_rate_limit.sh
AWS_PROFILE_NAME="$AWS_PROFILE_NAME" infrastructure/scripts/verify_phase6_rate_limit.sh
```

このスクリプトは:

- 未認証で `/hello` を連続呼び出し
- 認証済みで `/secret` を連続呼び出し
- しきい値超過後に `429` が返ることを確認

手動で確認する場合:

- 未ログイン状態で API を 11 回以上連続呼び出す
- 10 回までは `200`
- 11 回目以降に `429`

確認ポイント:

- 未認証制限が発動すること

### Step 10. 認証済みユーザーの制限を確認する

認証済みで同じ API を連続呼び出します。

期待値:

- 100 回までは `200`
- 101 回目以降に `429`

補足:

- 固定ウィンドウ方式なので、前回の試行と同じ分内に再実行すると結果がずれます
- その場合は次の分に入ってから再実行してください

確認ポイント:

- 認証済みでは未認証より大きい上限になっていること

## 6. 実装時の注意

### 6.1 今回は固定ウィンドウで十分

最初からスライディングウィンドウやトークンバケットにしなくてよいです。

このフェーズの目的は:

- 制限値の切り替え
- DynamoDB で状態管理
- 429 の返却確認

です。

### 6.2 API Gateway Usage Plan は今回は主役にしない

Usage Plan は API Key ベースの考え方が中心なので、今の SPA + Cognito の学習目的とは少しずれます。

今回は:

- Lambda で判定
- DynamoDB に保存

の方が理解しやすく、後でプラン別制御へ拡張しやすいです。

### 6.3 まずは 1 API にだけ適用する

最初から全 API に一気に適用しないでください。

おすすめ:

- まず `/hello` と `/secret` を同じロジックで守る
- 動作確認が終わってから対象を広げる

## 7. 完了条件（Definition of Done）

以下すべてを満たしたら Phase 6 完了です。

- RateLimitTable が application スタックに作成済み
- 未認証ユーザーは 10 回を超えると `429`
- 認証済みユーザーは 100 回を超えると `429`
- ブラウザと CLI の両方で挙動を確認できる

## 8. 次に進む前の確認

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].[StackName,StackStatus]" \
  --output table
```

問題なければ、次は Phase 7（CI/CD）へ進みます。
