# Phase 0: Bootstrap デプロイロール作成と初回 assume-role

## 1. 目的

この手順は、AWS コンソールを使わずに、CloudFormation で bootstrap 用のデプロイロールを作り、
そのロールを `assume-role` で使えるようにするためのものです。

ここで作るのは「CLI から引き受けるためのロール」です。
CloudFormation が実際に他のリソースを作るための実行ロールは、次の bootstrap スタックの中で別に作ります。

## 2. 事前確認

```bash
aws sso login --profile "$AWS_PROFILE_NAME"
aws sts get-caller-identity --profile "$AWS_PROFILE_NAME"
```

`get-caller-identity` が成功したら、次に現在の SSO ロール ARN を調べます。

## 3. 現在の SSO ロール ARN を確認する

まずは一覧を目で確認したい場合だけ `table` を使います。

```bash
aws iam list-roles \
    --profile "$AWS_PROFILE_NAME" \
    --query "Roles[?starts_with(RoleName, 'AWSReservedSSO_')].[RoleName,Arn]" \
    --output table
```

実際に変数へ入れるときは、`table` ではなく `text` を使います。  
複数の Arn が返る場合は、最初の 1 つを使います。  
**異なる SSO ロールを使う場合は、`--query` の条件を変えてください。**

```bash
export TRUSTED_PRINCIPAL_ARN="$(aws iam list-roles \
    --profile "$AWS_PROFILE_NAME" \
    --query "Roles[?starts_with(RoleName, 'AWSReservedSSO_')].Arn | [0]" \
    --output text)"
```

必要なら、`echo "$TRUSTED_PRINCIPAL_ARN"` で内容を確認できます。

## 4. bootstrap 用デプロイロールを CloudFormation で作成する

### 4.1 テンプレートを用意する

`00-bootstrap-deploy-role.yaml` を作成し、次の内容を入れます。

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Bootstrap deploy role for CLI assume-role

Parameters:
    RoleName:
        Type: String
        Default: aws-cfn-tutorial-bootstrap-deploy-role
    TrustedPrincipalArn:
        Type: String

Resources:
    BootstrapDeployRole:
        Type: AWS::IAM::Role
        Properties:
            RoleName: !Ref RoleName
            AssumeRolePolicyDocument:
                Version: '2012-10-17'
                Statement:
                    - Effect: Allow
                        Principal:
                            AWS: !Ref TrustedPrincipalArn
                        Action: sts:AssumeRole
            ManagedPolicyArns:
                - arn:aws:iam::aws:policy/PowerUserAccess
            Policies:
                - PolicyName: BootstrapIamAccess
                    PolicyDocument:
                        Version: '2012-10-17'
                        Statement:
                            - Effect: Allow
                                Action:
                                    - iam:CreateRole
                                    - iam:DeleteRole
                                    - iam:AttachRolePolicy
                                    - iam:DetachRolePolicy
                                    - iam:PutRolePolicy
                                    - iam:DeleteRolePolicy
                                    - iam:GetRole
                                    - iam:TagRole
                                    - iam:UntagRole
                                    - iam:PassRole
                                Resource:
                                    - arn:aws:iam::*:role/aws-cfn-tutorial-*
                            - Effect: Allow
                                Action:
                                    - cloudformation:CreateStack
                                    - cloudformation:UpdateStack
                                    - cloudformation:DeleteStack
                                    - cloudformation:DescribeStacks
                                    - cloudformation:DescribeStackEvents
                                    - cloudformation:GetTemplate
                                    - cloudformation:ListStacks
                                    - cloudformation:ValidateTemplate
                                Resource: "*"

Outputs:
    BootstrapDeployRoleArn:
        Value: !GetAtt BootstrapDeployRole.Arn
```

### 4.2 スタックを作成する

```bash
aws cloudformation deploy \
    --profile "$AWS_PROFILE_NAME" \
    --stack-name aws-cfn-tutorial-bootstrap-deploy-role \
    --template-file bootstrap-deploy-role.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
    RoleName=aws-cfn-tutorial-bootstrap-deploy-role \
    TrustedPrincipalArn="$TRUSTED_PRINCIPAL_ARN"
```

## 5. 作成結果を確認する

```bash
aws cloudformation describe-stacks \
    --profile "$AWS_PROFILE_NAME" \
    --stack-name aws-cfn-tutorial-bootstrap-deploy-role \
    --query "Stacks[0].StackStatus" \
    --output text

aws cloudformation describe-stacks \
    --profile "$AWS_PROFILE_NAME" \
    --stack-name aws-cfn-tutorial-bootstrap-deploy-role \
    --query "Stacks[0].Outputs[?OutputKey=='BootstrapDeployRoleArn'].OutputValue" \
    --output text
```

期待値:

- StackStatus が `CREATE_COMPLETE` になる
- `BootstrapDeployRoleArn` が返る

## 6. 作成したロールを assume-role で使う

ロール ARN が返ったら、それを `AWS_ROLE_ARN` に入れて引き受けます。

```bash
export AWS_ROLE_ARN="$(aws cloudformation describe-stacks \
    --profile "$AWS_PROFILE_NAME" \
    --stack-name aws-cfn-tutorial-bootstrap-deploy-role \
    --query "Stacks[0].Outputs[?OutputKey=='BootstrapDeployRoleArn'].OutputValue" \
    --output text)"

aws sts assume-role \
    --role-arn "$AWS_ROLE_ARN" \
    --role-session-name dev-session \
    --profile "$AWS_PROFILE_NAME"
```

## 7. 補足

- この手順では、SSO でログインした自分の権限を使って、最初のロールを CloudFormation で作ります
- `PowerUserAccess` をベースにし、IAM 関連の必要最小限の権限を追加しています
- bootstrap が安定してから、さらに権限を絞ることも可能です
