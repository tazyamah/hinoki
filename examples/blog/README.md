# Blog サンプルアプリ

Hinoki フレームワークの機能を一通り体験できるシンプルなブログアプリです。  
記事の作成・編集・削除・公開管理と、コメント投稿機能を備えています。

## 機能

- 記事の CRUD（作成・表示・編集・削除）
- 公開 / 下書き管理
- コメント投稿・削除
- ページネーション
- 閲覧数カウント
- JSON API（`/blog/api/articles`）

---

## ADB へのインストール手順

### 前提条件

- Python 3.9 以上がインストールされていること
- OCI Autonomous Database（Always Free でも可）が用意されていること
- ORDS が有効化されていること（ADB ではデフォルトで有効）
- Hinoki 本体がインストール済みであること

Hinoki がまだの場合はリポジトリルートで実行:

```bash
pip install -e .
```

### 1. 接続情報を設定する

`config/database.yml` を編集して ADB の接続情報を入力します。

```yaml
environment: development
development:
  username: ADMIN          # DBユーザー名
  password: YOUR_PASSWORD  # パスワード
  dsn: your_adb_high       # ウォレット内の接続サービス名
  wallet_location: /path/to/Wallet  # ウォレットフォルダのパス
```

> **ヒント**: ウォレット（`Wallet_xxx.zip`）は OCI コンソールの ADB 詳細画面からダウンロードできます。  
> `database.yml` にはパスワードが含まれるため、`.gitignore` に追加してバージョン管理に含めないよう注意してください。

### 2. フレームワーク本体を ADB にインストールする

Hinoki のランタイム（PL/SQL パッケージ）を ADB に登録します。  
**初回のみ**実行が必要です。

```bash
cd examples/blog
hinoki install
```

### 3. マイグレーションを実行する

テーブル（`articles`・`comments`）を作成します。

```bash
hinoki migrate
```

### 4. アプリを ADB にデプロイする

モデル・コントローラ・ルーティング・ビューをすべて ADB に登録します。

```bash
hinoki deploy
```

---

## アクセス方法

デプロイが完了したら、ブラウザで以下の URL にアクセスします。

```
https://<your-adb-hostname>/ords/blog/
```

`<your-adb-hostname>` は OCI コンソールの ADB 詳細画面に表示されている ORDS エンドポイントのホスト名です。

---

## 使い方

### 記事一覧

`/blog/articles` にアクセスすると、公開済みの記事が新しい順に一覧表示されます。

### 記事を書く

1. 記事一覧ページの **「新しい記事」** リンクをクリック
2. タイトル・本文・著者名を入力して **「投稿」** ボタンを押す
3. 「公開中」にチェックを入れると記事一覧に表示されます（未チェックは下書き）

### 記事を編集・削除する

記事一覧または詳細ページの **「編集」**/**「削除」** リンクから操作できます。

### JSON API を使う

`/blog/api/articles` で記事一覧を JSON 形式で取得できます。

```bash
curl https://<your-adb-hostname>/ords/blog/api/articles
```

---

## ファイル構成

```
examples/blog/
├── hinoki.yml                          # プロジェクト設定（アプリ名・ORDSモジュール名）
├── config/
│   ├── database.yml                    # ADB 接続情報（要編集）
│   └── routes.hk                       # ルーティング定義
├── app/
│   ├── controllers/
│   │   ├── articles.controller.hk      # 記事コントローラ
│   │   └── analytics_controller.sql    # アナリティクス（生PL/SQL）
│   ├── models/
│   │   └── article.model.hk            # 記事モデル
│   └── views/
│       └── articles/
│           ├── index.html              # 記事一覧
│           ├── show.html               # 記事詳細
│           ├── new.html                # 新規作成フォーム
│           └── edit.html               # 編集フォーム
└── db/
    └── migrate/
        ├── 20260404000001_create_articles.hk   # articlesテーブル作成
        └── 20260404000002_create_comments.hk   # commentsテーブル作成
```

---

## よくある問題

### `hinoki install` や `hinoki deploy` でエラーが出る

- `database.yml` の接続情報（ユーザー名・パスワード・DSN・ウォレットパス）が正しいか確認してください。
- ウォレットフォルダのパスは絶対パスで指定することをお勧めします。

### ブラウザでアクセスしても何も表示されない

- ORDS が有効になっているか OCI コンソールで確認してください。
- `hinoki deploy` が正常に完了しているか確認してください。
- URL の `blog` 部分は `hinoki.yml` の `ords.module_name` と一致している必要があります。

### マイグレーションをやり直したい

直前のマイグレーションを元に戻す場合:

```bash
hinoki migrate:rollback
```
