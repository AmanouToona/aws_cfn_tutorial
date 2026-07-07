# Phase 2: 最小バックエンド実行手順

## 1. このフェーズの目的

Phase 2 では、最小構成のバックエンドを AWS 上にデプロイし、公開 API が動くところまで進めます。

このフェーズで作るもの:

- API Gateway
- Lambda 関数
- DynamoDB テーブル
- 公開 API `GET /hello`

最初のゴール:

- ブラウザまたは `curl` で `GET /hello` を呼び、レスポンスが返ること

## 2. 開始前チェック

```bash
aws sts get-caller-identity --profile "$AWS_PROFILE_NAME"
```

```bash
export AWS_REGION=ap-northeast-1
export PROJECT=aws-cfn-tutorial
export ENV=dev
export APP_STACK=${PROJECT}-${ENV}-application
```

確認ポイント:

- AWS 認証が有効であること
- Phase 1 の bootstrap スタックが作成済みであること

## 3. このフェーズで最初に作るファイル

最小構成では、まず次の 2 つを作ります。

1. `infrastructure/templates/application/template.yaml`
2. `backend/functions/hello/app.py`

必要なら後で追加するもの:

- `backend/functions/hello/requirements.txt`
- `backend/functions/hello/tests/`

## 4. 先に決める実装方針

Phase 2 では、複雑さを増やさないため、次の方針で進めます。

- 認証なしの公開 API から始める
- Lambda は 1 関数だけ作る
- API は `GET /hello` だけ作る
- DynamoDB はまず 1 テーブルだけ作る
- まずは「動く」ことを優先し、認証やレート制限は後のフェーズに回す

## 5. 作業ステップ

### Step 1. ディレクトリを作成する

```bash
mkdir -p infrastructure/templates/application
mkdir -p backend/functions/hello
```

確認ポイント:

- ディレクトリが作成されること

### Step 2. Lambda の最小コードを書く

`backend/functions/hello/app.py` に、最小のレスポンスを返す処理を書きます。

最小要件:

- ステータスコード `200`
- JSON ボディを返す
- 例: `{"message": "hello"}`

確認ポイント:

- ローカルで見て内容が単純であること

### Step 3. SAM / CloudFormation テンプレートを書く

`infrastructure/templates/application/template.yaml` に、最初は次の 3 つだけ定義します。

1. API Gateway
2. Hello Lambda
3. DynamoDB テーブル

最小要件:

- `GET /hello` が Lambda にルーティングされる
- DynamoDB テーブルが 1 つ作られる
- Outputs に API の URL が出る

確認ポイント:

- API URL を Outputs で取れるようにする

### Step 4. テンプレートを検証する

```bash
aws cloudformation validate-template \
  --profile "$AWS_PROFILE_NAME" \
  --template-body file://infrastructure/templates/application/template.yaml
```

確認ポイント:

- エラーなく成功すること

### Step 5. SAM ビルドを実行する

```bash
sam build --template-file infrastructure/templates/application/template.yaml
```

確認ポイント:

- ビルドが成功すること

### Step 6. application スタックをデプロイする

```bash
sam deploy \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --template-file infrastructure/templates/application/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --resolve-s3 \
  --parameter-overrides EnvironmentName="$ENV" Project="$PROJECT"
```

確認ポイント:

- デプロイが成功すること

### Step 7. API URL を取得する

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table
```

確認ポイント:

- API エンドポイントの URL が取れること

### Step 8. `GET /hello` を動作確認する

```bash
curl "<ここに API の URL>/hello"
```

期待値:

- `200 OK`
- 例: `{"message":"hello"}`

## 6. Git での区切り（推奨）

学習しやすくするため、以下の単位でコミットするのがおすすめです。

1. Lambda の最小コード追加
2. application テンプレート追加
3. SAM build / deploy 手順追加

コミット前チェック:

```bash
git status
```

## 7. よくある失敗と対処

### 7.1 Lambda の CodeUri パス間違い

症状:

- `sam build` が失敗する

対処:

- `CodeUri` が `backend/functions/hello/` を正しく指しているか確認する

### 7.2 API のパス設定ミス

症状:

- `/hello` にアクセスしても `404` になる

対処:

- テンプレートのイベント定義で `Path: /hello` と `Method: get` を確認する

### 7.3 deploy 時の権限不足

症状:

- `AccessDenied` が返る

対処:

- Phase 1 で作成した実行ロールや deploy 権限を見直す

### 7.4 Outputs が足りない

症状:

- API URL が分からず、動作確認できない

対処:

- API エンドポイント URL を Outputs に追加する

## 8. 完了条件（Definition of Done）

以下すべてを満たしたら Phase 2 完了です。

- application スタックが `CREATE_COMPLETE` または `UPDATE_COMPLETE`
- `GET /hello` が `200` を返す
- API URL を CloudFormation Outputs から取得できる
- Git で変更が追跡できている

## 9. 次に進む前の確認

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$APP_STACK" \
  --query "Stacks[0].[StackName,StackStatus]" \
  --output table
```

問題なければ、次は Phase 3（フロントエンド）へ進みます。
