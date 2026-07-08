# Phase 4: WAF 追加（CloudFront 保護）実行手順

## 1. このフェーズの目的

Phase 4 では、CloudFront の前段に AWS WAF を追加して防御層を作ります。

このフェーズで作るもの:

- WAF Web ACL（CLOUDFRONT スコープ）
- CloudFront への Web ACL 紐付け
- ブロック動作の確認

最初のゴール:

- CloudFront 配信に WAF が関連付けられていること
- 意図したリクエストが 403 でブロックされること

## 2. 重要な前提

CloudFront 用 WAF（`Scope: CLOUDFRONT`）は **必ず us-east-1 で作成**します。

通常リージョン（例: ap-northeast-1）とは別で管理する点に注意してください。

## 3. 開始前チェック

```bash
aws sts get-caller-identity --profile "$AWS_PROFILE_NAME"
```

```bash
export AWS_REGION=ap-northeast-1
export AWS_WAF_REGION=us-east-1

export PROJECT=aws-cfn-tutorial
export ENV=dev

export FE_STACK=${PROJECT}-${ENV}-frontend-dispatch
export WAF_STACK=${PROJECT}-${ENV}-waf
```

確認ポイント:

- Phase 3 の frontend-dispatch スタックが `CREATE_COMPLETE` / `UPDATE_COMPLETE`

## 4. このフェーズで最初に作るファイル

1. `infrastructure/templates/waf/template.yaml`

## 5. 先に決める実装方針

最初は「分かりやすさ優先」で次の 2 ルールにします。

- AWS Managed Rule（CommonRuleSet）
- 学習確認用の明示ブロックルール（URI パス一致）

## 6. 作業ステップ

### Step 1. WAF テンプレートを作成する

```bash
mkdir -p infrastructure/templates/waf
```

`infrastructure/templates/waf/template.yaml` に次を記載します。

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: WAF stack for CloudFront protection

Parameters:
  EnvironmentName:
    Type: String
    Default: dev
  Project:
    Type: String
    Default: aws-cfn-tutorial

Resources:
  FrontendWebAcl:
    Type: AWS::WAFv2::WebACL
    Properties:
      Name: !Sub "${Project}-frontend-webacl-${EnvironmentName}"
      Scope: CLOUDFRONT
      DefaultAction:
        Allow: {}
      VisibilityConfig:
        CloudWatchMetricsEnabled: true
        MetricName: !Sub "${Project}-frontend-webacl-${EnvironmentName}"
        SampledRequestsEnabled: true
      Rules:
        - Name: AWSManagedCommonRuleSet
          Priority: 1
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesCommonRuleSet
          VisibilityConfig:
            CloudWatchMetricsEnabled: true
            MetricName: awsManagedCommon
            SampledRequestsEnabled: true

        - Name: BlockWafTestPath
          Priority: 2
          Action:
            Block: {}
          Statement:
            ByteMatchStatement:
              FieldToMatch:
                UriPath: {}
              PositionalConstraint: EXACTLY
              SearchString: /waf-test-block
              TextTransformations:
                - Priority: 0
                  Type: NONE
          VisibilityConfig:
            CloudWatchMetricsEnabled: true
            MetricName: blockWafTestPath
            SampledRequestsEnabled: true

Outputs:
  FrontendWebAclArn:
    Description: ARN of Web ACL for CloudFront
    Value: !GetAtt FrontendWebAcl.Arn
```

### Step 2. テンプレートを検証する

```bash
aws cloudformation validate-template \
  --profile "$AWS_PROFILE_NAME" \
  --template-body file://infrastructure/templates/waf/template.yaml
```

確認ポイント:

- エラーなく成功すること

### Step 3. WAF スタックをデプロイする（us-east-1）

```bash
aws cloudformation deploy \
  --region "$AWS_WAF_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$WAF_STACK" \
  --template-file infrastructure/templates/waf/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides EnvironmentName="$ENV" Project="$PROJECT"
```

確認ポイント:

- デプロイが成功すること

### Step 4. Web ACL ARN を取得する

```bash
WEB_ACL_ARN="$(aws cloudformation describe-stacks \
  --region "$AWS_WAF_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$WAF_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendWebAclArn'].OutputValue" \
  --output text)"

echo "$WEB_ACL_ARN"
```

確認ポイント:

- ARN が取得できること

### Step 5. CloudFront 側に WAF を紐付ける

このプロジェクトでは `frontend-dispatch` テンプレートにパラメータを追加して管理するのがおすすめです。

追加する内容（`infrastructure/templates/frontend-dispatch/template.yaml`）:

- Parameters に `WebAclArn`（Type: String, Default: ""）
- `FrontendDistribution -> DistributionConfig -> WebACLId: !Ref WebAclArn`

その後、frontend-dispatch スタックを再デプロイします。

```bash
FRONTEND_BUCKET="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "${PROJECT}-${ENV}-bootstrap" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendBucketName'].OutputValue" \
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
    FrontendWebAclArn="$WEB_ACL_ARN"
```

確認ポイント:

- frontend-dispatch が `UPDATE_COMPLETE` になること

### Step 6. ブロック動作を確認する

学習用ルール `BlockWafTestPath` は `/waf-test-block` をブロックする設定です。

CloudFront ドメインを取得:

```bash
CF_DOMAIN="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendURL'].OutputValue" \
  --output text | sed 's#https://##')"

curl -I "https://${CF_DOMAIN}/waf-test-block"
```

期待値:

- `403 Forbidden`

## 7. 失敗時の確認

```bash
aws cloudformation describe-stack-events \
  --region "$AWS_WAF_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$WAF_STACK" \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || ResourceStatus=='UPDATE_FAILED'].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
  --output table
```

```bash
aws cloudformation describe-stack-events \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$FE_STACK" \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || ResourceStatus=='UPDATE_FAILED'].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
  --output table
```

## 8. 完了条件（Definition of Done）

以下すべてを満たしたら Phase 4 完了です。

- WAF スタックが `CREATE_COMPLETE` / `UPDATE_COMPLETE`
- frontend-dispatch に Web ACL が関連付け済み
- `/waf-test-block` で `403` が返る

## 9. 次に進む前の確認

```bash
aws cloudformation describe-stacks \
  --region "$AWS_WAF_REGION" \
  --profile "$AWS_PROFILE_NAME" \
  --stack-name "$WAF_STACK" \
  --query "Stacks[0].[StackName,StackStatus]" \
  --output table
```

問題なければ、次は Phase 5（Cognito 認証）へ進みます。
