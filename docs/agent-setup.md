# エージェントにセットアップさせる手順書

Copilot CLI / GitHub Copilot のエージェントなどに、このリポジトリのセットアップを任せるための手順です。**先に [setup-guide.md](setup-guide.md) の「前提条件チェックリスト」を人間が確認してください。**

## 1. 人間が先にやること（エージェントに任せない）

| # | 作業 | 理由 |
|---|------|------|
| 1 | `az login`（対象テナント）と `gh auth login` | パスワード・MFA は本人だけが入力する |
| 2 | Entra アプリのアプリケーション権限への管理者同意 | 管理者の判断が必要 |
| 3 | レポート匿名化設定の変更可否の判断 | 個人が特定される形になるため、組織の承認が要る |
| 4 | 実在従業員を含むデータの公開可否 | 公開 Pages に出す範囲を人が決める |
| 5 | Agentic 解説用 PAT の発行（任意） | トークンの値をチャットに出さないため |

## 2. 環境変数（ローカルで一度だけ設定）

値はチャットやコミットに書きません。ローカルシェルの環境変数か、`gh variable set` で渡します。

| 変数 | 内容 | 取得元 |
|------|------|--------|
| `TENANT_ID` | テナント ID | `az account show --query tenantId` |
| `COLLECTOR_CLIENT_ID` | collector アプリの（クライアント）ID | Entra アプリ登録の概要 |
| `PUBLISHER_CLIENT_ID` | publisher アプリの（クライアント）ID | 同上 |
| `SPO_SITE_ID` | 専用サイトの ID | Graph `GET /sites/{host}:/sites/{name}` |
| `SPO_LIBRARY_ID` | ドキュメントライブラリの ID | Graph `GET /sites/{id}/drives` |
| `SPO_SITE_PATH` | `/sites/<サイト名>` | サイト URL |
| `SPO_OWNERSHIP_MARKER` | サイト説明に入れた所有者マーカー | 自分で決める |

PowerShell の例（値は自分のものに置き換え）:

```powershell
$env:TENANT_ID = '<テナントID>'
$env:COLLECTOR_CLIENT_ID = '<collectorのID>'
$env:PUBLISHER_CLIENT_ID = '<publisherのID>'
$env:SPO_SITE_ID = '<サイトID>'
$env:SPO_LIBRARY_ID = '<ライブラリID>'
$env:SPO_SITE_PATH = '/sites/<サイト名>'
$env:SPO_OWNERSHIP_MARKER = '<マーカー>'
foreach ($n in 'TENANT_ID','COLLECTOR_CLIENT_ID','PUBLISHER_CLIENT_ID','SPO_SITE_ID','SPO_LIBRARY_ID','SPO_SITE_PATH','SPO_OWNERSHIP_MARKER') {
  gh variable set $n --body (Get-Item "Env:$n").Value -R <owner>/<repo>
}
```

## 3. エージェントに渡す依頼文（コピーして使う）

```text
このリポジトリの docs/setup-guide.md と docs/agent-setup.md に従い、手順 3 以降を進めてください。
- 先に oidc-probe.yml を手動実行し、ログの実際の sub を確認してからフェデレーション資格情報を作る。推測しない。
- リポジトリ変数は環境変数から gh variable set で登録する。値を出力・コミットしない。
- live-validation.yml → calendar-validation.yml の順に手動実行し、読み戻しまで確認する。
- 取得できない値を 0 や古い値で埋めず、停止して理由を報告する。
- 公開 Pages には加工済みの公開用データだけを載せる。個人の行・UPN・氏名は出さない。
- ログイン、MFA、管理者同意、PAT の値の入力が必要になったら止まり、何をしてほしいかを報告する。
```

## 4. 完了の確認

| # | 確認 | 期待 |
|---|------|------|
| 1 | `live-validation.yml` | 成功し、部門別の結果が SharePoint に保存される |
| 2 | `calendar-validation.yml` | 暦月の生成・保存・読み戻し照合まで成功 |
| 3 | publisher の権限 | 未付与のサイトのルートを読むと 403 |
| 4 | 公開 Pages | 個人の氏名・UPN・GUID・テナントドメインが出ていない |
