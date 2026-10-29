# M365 / Viva Insights の画面と、このダッシュボードのデータ取得方式

「Microsoft 365 管理センターや Viva Insights のあの画面の数字は、どこから・どの方式で取れているか（取れていないか）」の対応表です。公開ページ [仕組みとデータ元](https://aktsmm.github.io/m365-copilot-insights/architecture.html#portal-map) からもここへ飛べます。

確認日: 2026-10-29（Diamond デモテナントでの実機確認を含む）。

## 画面ごとの対応

| # | 見ている画面 | 同じ数字の取得口 | このリポジトリでの方式 | 状態 |
| --- | --- | --- | --- | --- |
| 1 | M365 管理センター > レポート > 使用状況 > Microsoft 365 Copilot | Microsoft Graph `copilot/reports/getMicrosoft365CopilotUsageUserDetail`（v1.0、CSV） | GitHub Actions が OIDC でアプリ認証し、Graph から直接取得（人のログイン不要） | 自動取得済み（無人で別 runner 2 回成功） |
| 2 | 同上の日別 | Graph beta `getMicrosoft365CopilotUsageUserDetailByDate` | 最新更新日の 7 日前から取得できる窓を使い、日別履歴を蓄積 | 取得口は実測済み。完全な暦月の全プロンプト数は窓外を復元できない |
| 3 | 部門（Entra のユーザー属性） | Graph `users`（department） | 同じアプリで取得し、UPN で突合 | 自動取得済み |
| 4 | Viva Insights > Copilot ダッシュボード（準備状況・導入・影響） | 画面は集計表示。個人別の無人 API は公式に未確認 | 取得していない。ダッシュボード右上の「データのエクスポート (プレビュー)」は人が UI で操作する CSV | ログイン済みブラウザの CDP 操作（`scripts/viva_export_cdp.py`）で自動取得に成功（2026-10-29、週×人×部署の CSV）。完全な無人化は未達 |
| 5 | Viva Insights 高度分析（Analysis results のクエリ） | Power BI コネクタ / Fabric Dataflow Gen2（Partition ID と Query ID が必要） | 公式の自動取得経路はこれ。未接続 | 対応中。管理者の機能アクセスポリシー（Copilot メトリックス エクスポート）を作成済みで反映待ち（最大 24 時間）。Analysis メニューが出れば接続する（下記の止まりどころ） |

## Viva Insights の自動取得が止まっている理由（実機で確認した事実）

- Insights Analyst ロールを付与しても、左ナビに「分析」「分析結果」がなく、`/AnalysisResults` などの URL も「ページが見つかりません」になる。
- 管理センターに「行動分析情報がオフ」が表示される。Partition ID / Query ID は分析結果のクエリから取るため、そこへ到達できていない。
- 行動分析情報の有効化は機能アクセス管理のポリシー（行動エクスペリエンス）で行う。デモテナントで 2026-10-29 12:08 にオンのポリシーを作成済み。反映まで最大 24 時間で、「分析」メニューが出るかは反映後に再確認する（未確認）。
- Graph だけで近似できるのはアプリ別のアクティブ日数まで（日次スナップショットを蓄積）。操作数・プロンプト数・習慣化割合・会議サマリーは Graph に無い。
- Fabric / Power BI 経路には容量（追加費用の可能性）が必要。

## 方式の違いの読み方

- Graph 取得は「アプリがトークンを取る無人方式」。人の Cookie やブラウザ操作は使わない。
- Viva の画面エクスポートは「人が操作する方式」。無人ジョブには持ち込まない。
- 指標も別物。Graph の `actions` と `prompts`、Viva の集計値は定義と期間が違うため足し合わせない。

## 原本・公式リンク

- [Graph usage detail](https://learn.microsoft.com/ja-jp/microsoft-365/copilot/extensibility/api/admin-settings/reports/copilotreportroot-getmicrosoft365copilotusageuserdetail)
- [Graph 日別 (beta)](https://learn.microsoft.com/ja-jp/microsoft-365/copilot/extensibility/api/admin-settings/reports/copilotreportroot-getmicrosoft365copilotusageuserdetailbydate)
- [Viva Copilot metrics export](https://learn.microsoft.com/ja-jp/viva/insights/org-team-insights/export-copilot-metrics)
- [Viva → Power BI コネクタ](https://learn.microsoft.com/ja-jp/viva/insights/advanced/analyst/power-bi-connector)
- [Viva → Fabric Dataflow Gen2](https://learn.microsoft.com/ja-jp/viva/insights/advanced/analyst/export-query-data-microsoft-fabric)
