# Microsoft 365 Copilot insights

Microsoft 365 Copilot の利用状況（Graph の Copilot 利用レポート）を、**暦月単位**で集計して日本語の対話型ダッシュボード（単一 HTML）と CSV にするサンプルです。

- 公開デモ: https://aktsmm.github.io/m365-copilot-insights/
  - 実測版: デモ環境（人物・アカウントはすべて架空）の実測値。氏名・UPN は * で一部伏せ字、部門名は実データです
  - 合成版: 完全な合成データ。しきい値（5・10・15・30 未満、任意の整数）、部門フィルター、不明値の挙動を試せます
- 自分のテナントで動かす手順（**事前に必要な権限を含む**）: [docs/setup-guide.md](docs/setup-guide.md)
- 運用メモ（詳細・英語）: [docs/operations-notes.md](docs/operations-notes.md)

## できること

| # | 機能 | 状態 |
|---|------|------|
| 1 | Graph から日別の Copilot 利用（actions）を取得し、履歴を足して暦月 JSON/CSV/日本語 HTML を生成 | 検証済み（GitHub Actions で無人実行） |
| 2 | 部門別 CSV/HTML を SharePoint の専用サイトへ保存（上書きせず、履歴を保持） | 検証済み |
| 3 | 公開 Pages に、公開用に加工したデータだけを静的に公開 | 検証済み |
| 4 | SharePoint ページ用 SPFx Web パーツ | アプリカタログ登録・デプロイ・専用サイトへのインストールまで完了。一般ユーザーでの閲覧確認は未実施 |
| 5 | Agentic Workflow による解説生成 | 実行成功（出力は noop 設計で、解説文は公開されません） |
| 6 | Viva Insights の自動取得 | 未達 |

## 見方の約束

- **不明（unknown）は 0 ではありません。** 取得できていない値は「不明」と表示します。
- 当月は不完全なため、確定の分類は「不明」のままです。「観測回数（参考）」の表示で、月の途中経過を確認できます。
- 数値は prompts ではなく actions です。Graph の指標の定義に従います。

## 公開データの境界

- 公開 Pages は、静的な公開用入力だけで作られます。**ライブの実データから公開への自動更新はありません。**
- 公開リポジトリには、秘密情報・元のアカウント ID・完全な UPN・氏名・管理 ID・テナントのドメイン・社内 URL を含めません（氏名・UPN は一部伏せ字、部署名は実データで公開しています）。
- 実測の公開用データは `tests/fixtures/public-measured-monthly.json` です（承認済み・加工済み）。

## 構成

| 要素 | 場所 |
|------|------|
| 取得・集計・配信スクリプト | `scripts/` |
| ダッシュボード UI | `monthly-ui/`、`templates/` |
| ワークフロー（すべて手動起動） | `.github/workflows/` |
| テスト | `tests/` |

ワークフローはすべて手動起動で、定期実行は設定していません。

## ローカルでのテスト

PowerShell 7.5 以上、Node.js、Git が必要です。

```powershell
& .\tests\Test-CopilotPipeline.ps1
& .\tests\Test-CopilotPublicExposure.ps1
node --test .\tests\synthetic-pages.test.cjs .\tests\public-monthly.test.cjs
```

ローカルのテストが通っても、Graph・SharePoint・OIDC・Pages 配備・Agentic 推論・Viva の取得・SPFx のアクセスが成功した証拠にはなりません。完全な暦月の prompts 取得は未達です。
