# Phase 7: GitHub Actions + OIDC で CI/CD を自動化する

## 1. このフェーズの目的

Phase 7 では、手元で実行しているデプロイ手順を GitHub Actions へ移し、
push 時に自動で更新される状態を作ります。

このフェーズで作るもの:

- GitHub Actions 用 OIDC ロール（AWS 側）
- GitHub Actions ワークフロー（リポジトリ側）
- application / frontend-dispatch 再デプロイと CloudFront invalidation の自動化

ゴール:

- `main` ブランチへの push で dev 環境が自動デプロイされること

## 2. 前提条件

- Phase 6 まで完了している
- GitHub リポジトリが作成済み
- AWS 側に bootstrap / waf / application / frontend-dispatch スタックが存在する

環境変数:

```bash
export AWS_REGION=ap-northeast-1
export AWS_WAF_REGION=us-east-1
export PROJECT=aws-cfn-tutorial
export ENV=dev
export GITHUB_ORG=<your-org-or-user>
export GITHUB_REPO=<your-repo>
```

補足:

- CloudFront 用 WAF（`Scope: CLOUDFRONT`）は `us-east-1` 管理です
- そのため workflow でも WAF スタック参照は `us-east-1` を使います

## 3. AWS 側: OIDC ロールを作成する

まず OIDC ロール用テンプレートをデプロイします。

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "${PROJECT}-${ENV}-github-oidc" \
  --template-file infrastructure/templates/bootstrap/github-oidc-role.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    CreateOidcProvider=false \
    GitHubOrg="$GITHUB_ORG" \
    GitHubRepo="$GITHUB_REPO" \
    BranchName=main
```

補足:

- 既存アカウントでは `CreateOidcProvider=false` を使う（推奨）
- 完全に新規アカウントで OIDC Provider が未作成の場合のみ `CreateOidcProvider=true` を指定する

ロール ARN を取得します。

```bash
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "${PROJECT}-${ENV}-github-oidc" \
  --query "Stacks[0].Outputs[?OutputKey=='GitHubActionsDeployRoleArn'].OutputValue | [0]" \
  --output text
```

作成に失敗して StackStatus が `ROLLBACK_COMPLETE` の場合は、いったん削除して再作成します。

```bash
aws cloudformation delete-stack \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "${PROJECT}-${ENV}-github-oidc"

aws cloudformation wait stack-delete-complete \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "${PROJECT}-${ENV}-github-oidc"
```

## 4. GitHub 側: シークレットを設定する

Repository Secrets に次を設定します。

- `AWS_ROLE_TO_ASSUME`: さきほど取得した IAM Role ARN

## 5. GitHub Actions ワークフロー

このリポジトリには以下を追加済みです。

- `.github/workflows/deploy-dev.yml`

ワークフローは次を実行します。

1. OIDC で AWS 認証
2. Lambda artifact をユニークキーで S3 へアップロード
3. application スタックを再デプロイ
4. frontend-dispatch スタックを再デプロイ
5. frontend を S3 sync
6. CloudFront invalidation

## 6. 動作確認

1. GitHub Actions の `Deploy Dev` を `workflow_dispatch` で手動実行する
2. 成功後、CloudFront URL を開いて最新の画面が出ることを確認する
3. `/hello` と `/secret` の動作を確認する

必要ならローカル確認も実行します。

```bash
AWS_PROFILE_NAME="$AWS_PROFILE_NAME" infrastructure/scripts/verify_phase5_auth.sh
AWS_PROFILE_NAME="$AWS_PROFILE_NAME" infrastructure/scripts/verify_phase6_rate_limit.sh
```

## 7. 注意点

- ワークフローは `main` ブランチ push をトリガーにしています
- ブランチ名が異なる場合は、`deploy-dev.yml` と OIDC ロールの `BranchName` を一致させる
- IAM 権限は学習向けに広めに設定しています。安定後は最小権限へ絞る

## 8. 完了条件（Definition of Done）

- GitHub Actions が OIDC で AWS 認証できる
- `main` への push で自動デプロイが完了する
- デプロイ後に frontend が更新され、CloudFront キャッシュも更新される
