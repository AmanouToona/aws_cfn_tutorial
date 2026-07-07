# Phase 1: Bootstrap スタック実行手順

## 1. このフェーズの目的

Phase 1 では、後続フェーズの土台となる以下を CloudFormation で作成します。

- デプロイアーティファクト用 S3 バケット
- フロントエンド配信用 S3 バケット
- CloudFormation 実行ロール（後続スタックが使うロール）

このフェーズが終わると、以後のデプロイを CLI だけで進めやすくなります。

## 2. 開始前チェック

```bash
aws sts get-caller-identity --profile "$AWS_PROFILE_NAME"
```

確認ポイント:

- 実行結果が返ること
- 期待する AWS アカウントであること

環境変数（必要なら再設定）:

```bash
export AWS_REGION=ap-northeast-1
export PROJECT=aws-cfn-tutorial
export ENV=dev
export BOOTSTRAP_STACK=${PROJECT}-${ENV}-bootstrap
```

## 3. 作業ステップ

### Step 1. bootstrap テンプレートの配置を確認する

```bash
ls -la infrastructure/templates/bootstrap/template.yaml
```

確認ポイント:

- ファイルが存在すること

### Step 2. bootstrap スタックをデプロイする

```bash
aws cloudformation validate-template \
  --profile "$AWS_PROFILE_NAME" \
  --template-body file://infrastructure/templates/bootstrap/template.yaml
```

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK" \
  --template-file infrastructure/templates/bootstrap/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides EnvironmentName="$ENV" Project="$PROJECT"
```

確認ポイント:

- コマンドがエラー終了しないこと

### Step 3. スタック状態を確認する

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK" \
  --query "Stacks[0].StackStatus" \
  --output text
```

期待値:

- `CREATE_COMPLETE` または `UPDATE_COMPLETE`

### Step 4. Outputs を確認する

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table
```

確認ポイント:

- 後続で使う値（例: バケット名、実行ロール ARN）が出力されていること

## 5. よくある失敗と対処

### 5.1 CAPABILITY エラー

症状:

- IAM リソースがあるのに `--capabilities CAPABILITY_NAMED_IAM` を付けていない

対処:

- deploy コマンドに `--capabilities CAPABILITY_NAMED_IAM` を付ける

### 5.2 バケット名重複

症状:

- S3 バケット名がグローバルで重複して作成失敗する

対処:

- テンプレートでバケット名にアカウント ID や環境名を含める

### 5.3 権限不足

症状:

- `AccessDenied` でロール作成やスタック作成に失敗する

対処:

- Phase 0 で作った deploy role のポリシーを見直す
- どの API で拒否されたかをエラーメッセージで確認する

## 6. 完了条件（Definition of Done）

以下すべてを満たしたら Phase 1 完了です。

- bootstrap スタックが `CREATE_COMPLETE` または `UPDATE_COMPLETE`
- 必要な Outputs が取得できる
- 手順が docs に記録されている
- Git で変更が追跡できている

## 7. 次に進む前の確認

Phase 2 に進む前に、次を一度だけ確認します。

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$BOOTSTRAP_STACK" \
  --query "Stacks[0].[StackName,StackStatus]" \
  --output table
```

問題なければ、次は Phase 2（最小バックエンド）へ進みます。
