# Microsoft 365 Copilot insights

Microsoft 365 Copilot の利用状況（Graph の Copilot 利用レポート）を、**暦月単位**で集計して日本語の対話型ダッシュボード（単一 HTML）と CSV にするサンプルです。

- 公開デモ: https://aktsmm.github.io/m365-copilot-insights/
  - 実測版: デモ環境（人物・アカウントはすべて架空）の実測値。氏名・部門名は実データ、UPN はドメイン部分のみ非公開です
  - 合成版: 完全な合成データ。しきい値（5・10・15・30 未満、任意の整数）、部門フィルター、不明値の挙動を試せます
- 自分のテナントで動かす手順（**前提条件チェックリストと必要な権限を含む**）: [docs/setup-guide.md](docs/setup-guide.md)
- エージェントにセットアップを任せる手順（環境変数・依頼文つき）: [docs/agent-setup.md](docs/agent-setup.md)
- M365 / Viva Insights の画面ごとのデータ取得方式: [docs/data-sources.md](docs/data-sources.md)（公開ページ: [仕組みとデータ元](https://aktsmm.github.io/m365-copilot-insights/architecture.html#portal-map)）
- デモ用の利用実績を作る手順（任意・自分のデモテナントのみ）: [docs/demo-usage-seeding.md](docs/demo-usage-seeding.md)
- 運用メモ（詳細・英語）: [docs/operations-notes.md](docs/operations-notes.md)

## できること

| # | 機能 | 状態 |
|---|------|------|
| 1 | Graph から日別の Copilot 利用を取得し、履歴を足して暦月 JSON/CSV/日本語 HTML を生成。日別 API が JSON（アクション数）でも CSV（プロンプト数）でも取り込み、別の系列として保存 | 検証済み（GitHub Actions で無人実行、毎日 2 回の定期実行）。日別 API の 504 が続く間は欠測日が残る |
| 2 | 部門別 CSV/HTML を SharePoint の専用サイトへ保存（上書きせず、履歴を保持） | 検証済み |
| 3 | 公開 Pages に、公開用に加工したデータだけを静的に公開 | 検証済み（更新は手動。ライブから公開への自動更新はない） |
| 4 | SharePoint ページ用 SPFx Web パーツ | アプリカタログ登録・デプロイ・専用サイトへのインストールまで完了。一般ユーザーでの閲覧確認は未実施 |
| 5 | Agentic Workflow による解説生成 | 実行成功。ただし対象は合成データの要約だけで、出力は noop 設計のため解説文は公開されない。実データの解析は未実施 |
| 6 | Purview 監査ログの集計（Copilot の操作を日・アプリ・エージェント名で件数集計。ユーザー名は出さない） | 検証済み（専用アプリ・OIDC で無人実行、毎日 1 回）。ただし `AgentName` は空で、エージェント別の集計はまだ取れていない |
| 7 | Viva Insights の Copilot / エージェント / 消費量ダッシュボード | 管理センターに表示される（2026-11-03 確認）。エージェントダッシュボードの日単位 CSV は、ログイン済みブラウザの CDP 操作で取得できる。API はなく、**無人化は未達** |
| 8 | デモ用の利用実績づくり（TAP と CDP の画面操作） | 動作する。人が操作する補助で、定期実行や無人運用の対象ではない（[docs/demo-usage-seeding.md](docs/demo-usage-seeding.md)） |

## 自動でできること・できないこと（2026-11-04 時点）

| # | 区分 | 内容 |
|---|------|------|
| 1 | 無人で動く | Graph の日別利用（アクション数／プロンプト数）の取得と履歴の蓄積（毎日 06:00 と 18:00 JST）、暦月の集計、SharePoint への保存、Purview 監査ログの件数集計（毎日 03:30 JST）、公開前の検査 |
| 2 | 手動で起動する | 公開 Pages の更新、OIDC の確認、ライブ取得（`live-validation.yml`）、Agentic 解説 |
| 3 | 有人の画面操作が必要 | Viva Insights のダッシュボードの CSV エクスポート、デモ利用実績づくり、SharePoint Home のリンク追加などの画面設定 |
| 4 | 取れていない・できない | エージェント別の利用数（監査ログの `AgentName` が空。管理センターの「すべてのエージェント」の数字も画面のみ）、完全な暦月のプロンプト数（日別 API の取得窓外は復元できず、504 の日は欠測）、Viva 高度分析（Power BI / Fabric）の無人取得、Agentic による実データの解析、一般ユーザーでの SPFx 閲覧確認 |
| 5 | 既知の制約 | 日別 API は報告日の 7 日前から報告日までしか取れない。Graph の利用状況レポートは 504 を返すことがあり、取れない日は「不明」として残す（0 にしない）。応答形式が JSON から CSV に変わった事例がある |

失敗時は、公開の実行ログに失敗した段階名だけが出ます（例: `"failedStage":"probe"`）。詳しい確認手順は [docs/operations-notes.md](docs/operations-notes.md) を参照してください。

## 見方の約束

- **不明（unknown）は 0 ではありません。** 取得できていない値は「不明」と表示します。
- 当月は不完全なため、確定の分類は「不明」のままです。「観測回数（参考）」の表示で、月の途中経過を確認できます。
- 指標は「Copilot アクション数」と「Copilot プロンプト数」の 2 系列で、互いに代用しません。アクション数は各アプリでの Copilot の操作の合計、プロンプト数は Copilot に送信した質問の数です。
## 公開データの境界

- 公開 Pages は、静的な公開用入力だけで作られます。**ライブの実データから公開への自動更新はありません。**
- 公開リポジトリには、秘密情報・元のアカウント ID・完全な UPN・氏名・管理 ID・テナントのドメイン・社内 URL を含めません（氏名・部署名は架空の人物の実データで公開し、UPN はドメイン部分のみ非公開です）。
- 実測の公開用データは `tests/fixtures/public-measured-monthly.json` です（承認済み・加工済み）。

## 構成

| 要素 | 場所 |
|------|------|
| 取得・集計・配信スクリプト | `scripts/` |
| ダッシュボード UI | `monthly-ui/`、`templates/` |
| ワークフロー | `.github/workflows/` |
| テスト | `tests/` |

ワークフローは手動起動が基本です。定期実行は、月次の日別収集（`calendar-validation.yml`、毎日 06:00 と 18:00 JST）と、監査ログの集計（`audit-aggregate.yml`、毎日 03:30 JST）の 2 つだけです。

## ローカルでのテスト

PowerShell 7.5 以上、Node.js、Git が必要です。

```powershell
& .\tests\Test-CopilotPipeline.ps1
& .\tests\Test-CopilotPublicExposure.ps1
node --test .\tests\synthetic-pages.test.cjs .\tests\public-monthly.test.cjs
```

ローカルのテストが通っても、Graph・SharePoint・OIDC・Pages 配備・Agentic 推論・Viva の取得・SPFx のアクセスが成功した証拠にはなりません。完全な暦月のプロンプト数は未達です（日別 API の窓外と 504 の欠測があるため）。
