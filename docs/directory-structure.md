# ディレクトリ構成の提案

## 1. 基本方針

このプロジェクトは、AWS 学習用でありながら、今後本格的に拡張しやすい構成にしておくことが重要です。 そのため、次の方針で整理するのがベストプラクティスです。

- インフラ定義とアプリケーションコードを分ける
- フロントエンド・バックエンド・CI/CD を分離する
- 1 つのディレクトリに責務を寄せすぎない
- 初心者でも「どこを直せばよいか」が分かる構成にする
- 将来の拡張（WAF、Cognito、レート制限、監視）に耐えるようにする

## 2. 推奨ディレクトリ構成

```text
aws-cfn-tutorial/
├─ README.md
├─ spec.md
├─ execution-plan.md
├─ directory-structure.md
├─ deploy-and-destroy-process.md
├─ docs/
│  ├─ architecture.md
│  ├─ operations.md
│  └─ troubleshooting.md
├─ infrastructure/
│  ├─ templates/
│  │  ├─ bootstrap/
│  │  │  └─ template.yaml
│  │  ├─ waf/
│  │  │  └─ template.yaml
│  │  ├─ application/
│  │  │  └─ template.yaml
│  │  └─ frontend-dispatch/
│  │     └─ template.yaml
│  ├─ parameters/
│  │  ├─ dev.json
│  │  └─ prod.json
│  ├─ scripts/
│  │  ├─ deploy.sh
│  │  ├─ destroy.sh
│  │  └─ cleanup.sh
│  └─ samconfig.toml
├─ backend/
│  ├─ functions/
│  │  └─ hello/
│  │     ├─ app.py
│  │     ├─ requirements.txt
│  │     └─ tests/
│  ├─ shared/
│  │  └─ utils.py
│  └─ tests/
├─ frontend/
│  ├─ src/
│  │  ├─ components/
│  │  ├─ pages/
│  │  ├─ auth/
│  │  └─ api/
│  ├─ public/
│  ├─ package.json
│  ├─ vite.config.ts
│  └─ tests/
├─ .github/
│  └─ workflows/
│     └─ deploy.yml
├─ tests/
│  ├─ integration/
│  └─ e2e/
└─ .gitignore
```

## 3. 各ディレクトリの役割

### ルート直下

- README.md: プロジェクト全体の概要
- spec.md: 仕様書
- execution-plan.md: 実行計画
- directory-structure.md: 構成方針
- deploy-and-destroy-process.md: CLI ベースのデプロイ/完全削除手順

### docs/

- 仕様・運用・トラブルシューティングなどの補助資料を置く
- 実装メモや学習ノートをまとめる場所

### infrastructure/

- CloudFormation / SAM のテンプレートを置く
- スタック単位でディレクトリを分ける
- パラメータファイルやデプロイスクリプトもここに置く

### backend/

- Lambda 関数や API 関連コードを置く
- 関数ごとにサブディレクトリを作ると管理しやすい
- tests/ を置いて、ユニットテストや統合テストを分ける

### frontend/

- React / Vue / Vanilla JS などのフロントエンドコードを置く
- src/ 配下は画面・コンポーネント・認証・API 通信に分ける
- public/ には静的ファイルを入れる

### .github/workflows/

- GitHub Actions のデプロイ設定を置く
- AWS への認証やデプロイ手順をここで管理する

### tests/

- 統合テストや E2E テストをまとめる
- インフラとアプリケーションの両方を検証しやすい

## 4. ベストプラクティス

### 4.1 インフラとコードを分離する

CloudFormation / SAM テンプレートは、アプリコードとは別の場所に置くことで、構成の見通しが良くなります。

### 4.2 スタックごとに分ける

Bootstrap、WAF、Application、Frontend-Dispatch など、責務ごとにテンプレートを分割すると保守しやすいです。

### 4.3 関数ごとに独立させる

Lambda 関数ごとにディレクトリを分けると、依存関係が明確になります。

### 4.4 テストを近くに置く

コードの近くに tests/ を置くことで、変更時の影響範囲が把握しやすくなります。

### 4.5 環境差分を明確にする

dev / prod など環境ごとにパラメータを分けると、運用時に混乱しにくくなります。

## 5. 初心者向けの簡易版

最初はこの構成をそのまま使うと少し大きく感じるため、最初の段階では次のように始めるのがおすすめです。

```text
aws-cfn-tutorial/
├─ docs/
├─ infra/
├─ backend/
├─ frontend/
└─ .github/
```

この形にしておけば、後から細かく分割できます。

## 6. 推奨する進め方

1. 最初は docs/ と infra/ をしっかり作る
2. backend/ で API を作る
3. frontend/ で画面を作る
4. CI/CD を .github/workflows/ に追加する
5. テストを tests/ に整理する

## 7. まとめ

このプロジェクトでは、「インフラ」「バックエンド」「フロントエンド」「CI/CD」「ドキュメント」を分ける構成が最も実践的です。 まずはシンプルに始め、必要に応じて細かく分割していくのが、AWS 学習プロジェクトとしてもおすすめです。
