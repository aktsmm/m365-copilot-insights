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
| 1 | Graph から日別の Copilot 利用を取得し、履歴を足して暦月 JSON/CSV/日本語 HTML を生成。日別 API が JSON（アクション数）でも CSV（プロンプト数）でも取り込み、別の系列として保存 | 手動起動の無人実行は成功。毎日 2 回に定期設定しているが、11/4 18:00 JST の起動は履歴で未確認。日別 API の 504 が続く間は欠測日が残る |
| 2 | 部門別 CSV/HTML を SharePoint の専用サイトへ保存（上書きせず、履歴を保持） | 検証済み |
| 3 | 公開 Pages に、公開用に加工したデータだけを静的に公開 | 検証済み（更新は手動。ライブから公開への自動更新はない） |
| 4 | SharePoint ページ用 SPFx Web パーツ | アプリカタログ登録・デプロイ・専用サイトへのインストールまで完了。一般ユーザーでの閲覧確認は未実施 |
| 5 | Agentic Workflow による解説生成 | `Measured aggregate commentary` は公開承認済みの実測値の部門別集計のみを読む。GitHub 上で手動起動し、正式な安全出力と集計識別子の検査後に Pages を自動配備する。保存失敗時は公開を止める。氏名・個票やライブ原本は読ませない。元の合成用ワークフローは別の noop デモ |
| 6 | Purview 監査ログの集計（Copilot の操作を日・アプリ・エージェント名で件数集計。ユーザー名は出さない） | 専用アプリ・OIDC で毎日 1 回に設定。名前が取れる場合、公開ログには `Researcher`・`Analyst`・`Planner Agent` のみ表示し、他は「その他」にまとめる。名前が未記録の場合は「(なし)」とする |
| 7 | Viva Insights の Copilot / エージェント / 消費量ダッシュボード | 表示と CSV のブラウザ取得を確認。GitHub 単体の無人取得は未達。高度分析 → Fabric 定期更新の公式経路はあるが、本テナントでは分析結果ページに到達できず未接続 |
| 8 | デモ用の利用実績づくり（TAP と CDP の画面操作） | 動作する。人が操作する補助で、定期実行や無人運用の対象ではない（[docs/demo-usage-seeding.md](docs/demo-usage-seeding.md)） |
| 9 | 収集失敗の自動記録 | 月次収集・監査集計の失敗 / タイムアウトで Issue を作成・追記する設定。ジョブ名・ステップ名・実行 URL のみ。合成モックで処理を確認したが実イベントでの発火は未検証。起動自体の欠落検知、AI 原因調査や自動修復はない |

## 自動でできること・できないこと（2026-11-04 時点）

| # | 区分 | 内容 |
|---|------|------|
| 1 | 無人で動く | Graph の日別利用（アクション数／プロンプト数）の取得と履歴の蓄積（毎日 06:00 と 18:00 JST）、暦月の集計、SharePoint への保存、Purview 監査ログの件数集計（毎日 03:30 JST）、公開前の検査 |
| 2 | GitHub 上で手動起動する | 公開 Pages の更新、OIDC の確認、ライブ取得（`live-validation.yml`）、実測集計の Agentic 解説。解説の成功後は Pages が自動起動する。ローカル操作は不要 |
| 3 | 有人の画面操作が必要 | Viva Insights のダッシュボードの CSV エクスポート、デモ利用実績づくり、SharePoint Home のリンク追加などの画面設定 |
| 4 | この実装では未達 | Viva や管理センターのエージェント利用指標の無人取得（監査ログの件数集計とは別）、完全な暦月のプロンプト数（日別 API の窓外・504 は欠測）、Viva 高度分析（Power BI / Fabric）の無人取得、一般ユーザーでの SPFx 閲覧確認。M365 メッセージセンターの通知は取得・表示していない |
| 5 | 既知の制約 | 日別 API は報告日の 7 日前から報告日までしか取れない。Graph の利用状況レポートは 504 を返すことがあり、取れない日は「不明」として残す（0 にしない）。応答形式が JSON から CSV に変わった事例がある |

失敗時は、公開の実行ログに許可された段階名（例: `"failedStage":"probe"`）を出し、別の通常 Actions が失敗 Issue を記録します。Issue にログ本文や個人データは転記しません。詳しい手順は [docs/operations-notes.md](docs/operations-notes.md) を参照してください。

**収集するスクリプトと、解釈する AI は別工程です。** Graph の CSV 応答も Actions がブラウザなしで直接取得します。AI は公開用の集計 JSON に短い参考解説を付けるだけで、Viva の取得や欠測の補完はしません。取得元と表示先は [データ対応表](docs/data-sources.md)、解説の契約と起動方法は [運用メモ](docs/operations-notes.md#measured-aggregate-commentary) を参照してください。

AI 解説の正式成果物は 7 日保持します。期限後に Pages を手動更新する場合は、以前に公開した検査済み解説と出典を、同じ推論 run・attempt・集計に一致する場合だけ再利用します。新しい推論が保存に失敗した場合や、公開データが変わった場合は古い解説で代用せず配備を止めます。

## 見方の約束

- **不明（unknown）は 0 ではありません。** 取得できていない値は「不明」と表示します。
- 当月は不完全なため、確定の分類は「不明」のままです。「観測回数（参考）」の表示で、月の途中経過を確認できます。
- 指標は「Copilot アクション数」と「Copilot プロンプト数」の 2 系列で、互いに代用しません。アクション数は各アプリでの Copilot の操作の合計、プロンプト数は Copilot に送信した質問の数です。
## 公開データの境界

- 公開 Pages は、静的な公開用入力だけで作られます。**ライブの実データから公開への自動更新はありません。**
- 公開用 JSON は秘密情報・元のアカウント ID・完全な UPN・管理 ID を除去します。氏名・部署名は架空のデモ人物の値を公開し、UPN はドメイン部分を隠しています。Pages の SharePoint リンクはデモ用の要認証リンクであり、リンクから閲覧権限は付与されません。
- 実測の公開用データは `tests/fixtures/public-measured-monthly.json` です（承認済み・加工済み）。
- 監査集計の公開 Actions ログは名前の固定許可リストを集計前に適用します。許可外の名前は「その他」にまとめ、未記録は別扱いです。監査の操作件数・利用者数は Viva のセッション数などとは別の指標です。

## 構成

| 要素 | 場所 |
|------|------|
| 取得・集計・配信スクリプト | `scripts/` |
| ダッシュボード UI | `monthly-ui/`、`templates/` |
| ワークフロー | `.github/workflows/` |
| テスト | `tests/` |

定期実行は、月次の日別収集（`calendar-validation.yml`、毎日 06:00 と 18:00 JST）と、監査ログ集計（`audit-aggregate.yml`、毎日 03:30 JST）の 2 つです。これに加え、失敗時の Issue 記録と、実測集計の AI 解説成功後の Pages 配備がイベントで自動起動します。AI 推論自体に定期実行はありません。

## ローカルでのテスト

PowerShell 7.5 以上、Node.js、Git が必要です。

```powershell
& .\tests\Test-CopilotPipeline.ps1
& .\tests\Test-CopilotPublicExposure.ps1
& .\tests\Test-CopilotCommentaryProvenance.ps1
node --test .\tests\synthetic-pages.test.cjs .\tests\public-monthly.test.cjs .\tests\commentary.test.cjs
```

ローカルのテストが通っても、Graph・SharePoint・OIDC・Pages 配備・Agentic 推論・Viva の取得・SPFx のアクセスが成功した証拠にはなりません。完全な暦月のプロンプト数は未達です（日別 API の窓外と 504 の欠測があるため）。
