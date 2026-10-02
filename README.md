# XFFChk

自分がフォロー中のアカウントについて、直近1年間に投稿がない候補をCSVに出す、読み取り専用のシェルスクリプトです。自動でフォロー解除はしません。X APIが返す「直近投稿」を使い、返信やリポストを除外する指定はしていません。投稿日時を取得できないアカウントは `unknown` と表示し、休止とは判定しません。

## 必要なもの

- Bash、`curl`、`jq`
- X Developer App のBearer Token、またはOAuth 2.0 User Contextのアクセストークン
- 自分のXユーザー名。数値のユーザーIDでも指定できます。

App-only Bearer TokenはDeveloper Consoleから取得できます。割安なOwned Readsを利用するには、App所有者本人の[OAuth 2.0 User Contextアクセストークン](https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code)を使います。その場合のスコープは `follows.read`、`users.read`、`tweet.read` です。通常のOAuth 2.0アクセストークンの有効期間は2時間です。トークンをリポジトリにコミットしないでください。

## 実行

```sh
export X_USERNAME='your_handle'
read -r -s X_ACCESS_TOKEN
export X_ACCESS_TOKEN
./xffchk.sh > report.csv
unset X_ACCESS_TOKEN
```

`read` のプロンプトでトークンを貼り付けてEnterを押します。ユーザー名の検索には追加のUser Readが1件発生するため、数値IDが分かる場合は `X_USER_ID` を指定すると省けます。標準出力はCSV、件数は標準エラー出力に表示されます。`inactive` と `no_posts` が解除の検討候補、`unknown` は手動確認が必要です。

特定の日付のUTC 00:00を基準にする場合:

```sh
./xffchk.sh --cutoff 2025-10-02 > report.csv
```

保存済みのAPIレスポンスでオフライン確認する場合は `--input responses.json` を指定します。JSONは単一レスポンスか、ページごとのレスポンスの配列です。

## APIと費用

`GET /2/users/{id}/following` を `max_results=1000` で全ページ取得し、`most_recent_post_id` と投稿の `created_at` を展開します。[フォロー中一覧API](https://docs.x.com/x-api/users/get-following) の仕様に基づきます。

料金は返されたリソース数に基づきます。2026年10月時点の[X公式料金表](https://docs.x.com/x-api/getting-started/pricing)では、フォロー中一覧は通常1件$0.010、App所有者本人のOAuthトークンによるOwned Readなら1件$0.001、投稿読み取りは1件$0.005です。500アカウントと直近投稿500件が返る場合、単純計算ではApp-only Tokenで約$7.50、Owned Readで約$3.00です。展開された投稿の実際の請求額はDeveloper Consoleで確認してください。少額の利用上限を設定してから実行することを推奨します。

このツールは `public_metrics.post_count` が0の場合だけ `no_posts` と判定します。直近投稿IDがあるのに投稿本体を取得できない場合は `unknown` です。APIがエラーや不完全なページを返した場合、CSVは生成しません。

## `client-not-enrolled` が返る場合

このエラーはBearer Tokenの文字列や `curl` の文法よりも、XFFChkアプリのAPI利用登録を確認する必要があることを示します。[X公式CLIのトラブルシューティング](https://github.com/xdevplatform/xurl#x-platform-enrollment-troubleshooting)では、[Developer Console](https://console.x.com/)で `Apps` → `Manage apps` → XFFChk → `Move to package` を開き、`Pay-per-use` パッケージと `Production` 環境に移すよう案内しています。エラー本文の「Project」は現行Consoleの操作名と異なる場合があります。

設定後、XFFChkアプリから発行されたBearer Tokenで同じAPIを再試行してください。解決しなければアプリのパッケージと環境を再確認し、必要に応じてトークンを再生成します。Bearer TokenやConsumer Secretをエラー報告やスクリーンショットに含めないでください。
