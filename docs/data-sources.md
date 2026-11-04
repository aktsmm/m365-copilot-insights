# 表示項目の取得元と自動化の境界

確認日: 2026-11-04。実装済みの方式、実測結果、公式にある別経路を区別します。
[公開ページの対応表](https://aktsmm.github.io/m365-copilot-insights/architecture.html#portal-map) と同じ整理です。

## 何をどこから取得するか

| # | 情報 | 取得元・方式 | 自動化と表示先 |
|---|---|---|---|
| 1 | Copilot の最終利用日・利用者一覧 | Microsoft Graph v1.0 `getMicrosoft365CopilotUsageUserDetail`（CSV） | OIDC のアプリ認証で取得。日別の対象者を確保する取得口であり、D28 を暦月の回数に置換しない |
| 2 | 日別アクション数 | Graph beta `getMicrosoft365CopilotUsageUserDetailByDate` の JSON `allAppsCopilotActionCount` | 通常 Actions が毎日 06:00 / 18:00 JST に収集、履歴を月次集計し非公開 SharePoint へ保存 |
| 3 | 日別プロンプト数 | 同じ beta API の CSV 列 `Prompts submitted for All Apps` | ブラウザの CSV ダウンロードではなく API 応答。アクション数とは別系列で取り込む |
| 4 | 氏名・UPN・部署 | Graph `users` の `displayName` / `userPrincipalName` / `department` | 利用レポートと突合。部門は取得時点の属性で、異動前を復元するものではない |
| 5 | 取得日・欠測日・観測回数・確定回数 | 上記の日別履歴をスクリプトで検査・合算 | 取得できた日だけが観測回数。月が終了し全日分を取得した場合のみ確定。欠測はゼロにしない |
| 6 | 公開 Pages の実測値 | 承認・加工済み `tests/fixtures/public-measured-monthly.json` | ハッシュと契約を検査した静的スナップショット。ライブ収集から公開への自動更新はない |
| 7 | 完全合成デモ | リポジトリの合成フィクスチャと `exports/synthetic` | 実測とは別入口。テスト用で、顧客やテナントの実績ではない |
| 8 | 日・アプリ・エージェント別の Copilot 監査操作件数・利用者数 | Purview 監査ログを Graph auditLog queries から専用アプリ / OIDC で取得 | 毎日 03:30 JST に無人集計。公開 Actions ログでは `Researcher`・`Analyst`・`Planner Agent` だけを表示し、その他の名前は集約、未記録は別扱い。監査の操作件数・利用者数であり、Viva のセッション数などとは別。月次 Pages の値には加えない |
| 9 | Viva の Copilot / エージェント CSV | Viva Insights のログイン済み画面のエクスポート | ブラウザ操作で取得済み。GitHub 単体の無人取得は未実装。月次 Pages の値には加えない |
| 10 | AI 解説 | 公開用実測値を部門・月・指標別に決定論的に集計した `measured-aggregate.json` | 手動起動の `measured-commentary` が集計だけを読み、検査後に Pages が自動配備。氏名・UPN・個票・ライブ原本を AI 入力にしない |
| 11 | 障害 Issue | Actions API の実行結果とワークフロー定義済みのジョブ名・ステップ名 | 失敗 / タイムアウトで自動記録。ログ本文や Graph 応答は読まない。原因究明・自動修復は別作業 |
| 12 | M365 メッセージセンターの通知 | 本リポジトリには収集処理なし | 取得・表示していない。管理センターの利用状況レポートとは異なる |

「Copilot アクション」は各アプリでの Copilot 操作を表す指標、
「プロンプト」は Copilot に送信した質問の指標です。両者の厳密な換算関係は確認できていません。
数の大小関係や一つの操作の数え方を推測せず、同じ月でも別系列として表示します。
Graph beta は応答が JSON / CSV の両方だった実測に対応しています。
日別の取得窓は最新更新日の七日前から更新日までで、窓外や 504 の欠測は復元済みと扱いません。
未取得日数には、当月内のレポート基準日後の日も含み、それ自体は障害ではありません。
AI 入力でも基準日後・窓外の未保存日・窓内で再取得できる日を区別し、古い月全体の回収を勧めません。

## Viva をクラウドで自動取得できるか

**製品全体として不可能ではありません。ただし本環境ではまだ実現していません。**

| # | 経路 | 公式に確認できること | 本環境で確認したこと・必要条件 |
|---|---|---|---|
| 1 | ダッシュボードから CSV エクスポート | Copilot のエクスポートはプレビュー。画面の Export data から週 / 日を選んで取得する手順 | Copilot とエージェントの CSV をブラウザで取得済み。このボタンを直接置換する公開 API は確認できていない |
| 2 | 高度分析 → Fabric Dataflow Gen2 | Viva クエリの自動更新、Dataflow の定期更新、Copy job による他のクラウドストレージへの自動転送が公式にある。Agent 365 のエクスポート表も記載されている | Partition ID / Query ID、組織アカウントの初回サインイン、Fabric ワークスペースと容量が必要。容量消費・費用が発生し得る。未接続・追加容量は作成していない |
| 3 | 現在の高度分析の入口 | デモテナントでは高度分析にアクセスできない旨の公式トラブルシュートがある | 11/4 も「分析」メニューなし、`AnalysisResults` はページが見つからない。単に「ポリシー反映待ち」とはもう記載しない。この環境のデモ種別による制約かは確定していない |

機能アクセスポリシーは以前に作成済みですが、設定の存在を分析機能の利用成功とはしません。
Fabric の再開条件は、高度分析の利用可否とクエリ ID を確認でき、容量・費用・接続先が承認されることです。
この経路は GitHub だけで取得する方式ではなく、クラウド側で集計・定期更新し、必要なら GitHub が出力を読む方式です。
ブラウザの Cookie の GitHub への移送、無人ログイン用の MFA 解除、認証の迂回は実装しません。

## AI と通常の Actions の分担

集計・収集・契約検査・失敗 Issue 記録・配備は通常のスクリプトです。
AI は公開承認済みデータの集計を解釈するだけで、欠測値の生成や Viva の取得はしません。
推論の成果物と入力の識別子が一致しなければ公開を止めます。
元の `synthetic-commentary` は合成入力のみの noop デモとして別に残します。
実測の更新は引き続き承認済み公開スナップショットの差し替えが必要です。

## 公式資料

- [Graph usage detail](https://learn.microsoft.com/ja-jp/microsoft-365/copilot/extensibility/api/admin-settings/reports/copilotreportroot-getmicrosoft365copilotusageuserdetail)
- [Graph 日別レポート（beta）](https://learn.microsoft.com/ja-jp/microsoft-365/copilot/extensibility/api/admin-settings/reports/copilotreportroot-getmicrosoft365copilotusageuserdetailbydate)
- [Copilot メトリックのエクスポート（プレビュー）](https://learn.microsoft.com/ja-jp/viva/insights/org-team-insights/export-copilot-metrics)
- [Viva から Fabric への出力・定期更新](https://learn.microsoft.com/ja-jp/viva/insights/advanced/analyst/export-query-data-microsoft-fabric)
- [Viva 高度分析のアクセスエラー](https://learn.microsoft.com/ja-jp/troubleshoot/viva/insights/error-messages/viva-insights-errors#advanced-analysis)
- [Viva から Power BI への接続](https://learn.microsoft.com/ja-jp/viva/insights/advanced/analyst/power-bi-connector)
