# 🌲 Hinoki — Full-Stack Web Framework for OCI Autonomous Database

**Hinoki（檜）** は、OCI Autonomous Database（ADB）のみで完結するフルスタック Web フレームワークです。

- **ORDS** がHTTPサーバー（Webサーバー/APサーバー不要）
- **PL/SQL** がアプリケーションロジック（MVC）
- **Oracle Database** がデータストア + テンプレート + セッション

Ruby-like な `.hk` DSL で記述し、PL/SQL にトランスパイルして ADB にデプロイします。  
もちろん、生の PL/SQL（`.sql`）でも書けます。**両方が同じプロジェクト内で共存可能**です。

```
.hk ファイル ──→ [トランスパイラ] ──→ PL/SQL ──→ ADB
                                        ↑
.sql ファイル ──────────────────────────┘ (そのまま)
```

---

## 目次

- [クイックスタート](#クイックスタート)
- [インストール](#インストール)
- [プロジェクト構成](#プロジェクト構成)
- [.hk DSL リファレンス](#hk-dsl-リファレンス)
  - [Model](#model)
  - [Controller](#controller)
  - [Routes](#routes)
  - [Migration](#migration)
  - [View テンプレート](#view-テンプレート)
- [CLI コマンド一覧](#cli-コマンド一覧)
- [.hk と .sql の共存](#hk-と-sql-の共存)
- [トランスパイラの使い方](#トランスパイラの使い方)
- [ADB 接続設定](#adb-接続設定)
- [ORDS とデプロイ](#ords-とデプロイ)
- [フレームワーク内部構造](#フレームワーク内部構造)
- [サンプルアプリ: ブログ](#サンプルアプリ-ブログ)
- [Rails との対応表](#rails-との対応表)
- [制限事項・既知の問題](#制限事項既知の問題)
- [ライセンス](#ライセンス)

---

## クイックスタート

```bash
# 1. インストール
pip install -e .

# 2. 新規アプリ作成
hinoki new myblog
cd myblog

# 3. config/database.yml を編集 (ADB接続情報)
vi config/database.yml

# 4. フレームワークを ADB にインストール
hinoki install

# 5. scaffold で CRUD 一式を生成
hinoki generate scaffold post title:string body:text author:string published:boolean

# 6. マイグレーション実行
hinoki migrate

# 7. routes.hk にリソースを追加
echo 'routes "myblog" do
  root "posts#index"
  resources :posts
end' > config/routes.hk

# 8. ADB にデプロイ
hinoki deploy

# 9. ブラウザでアクセス
# → https://<your-adb>.adb.<region>.oraclecloudapps.com/ords/myblog/posts
```

---

## インストール

### 前提条件

- Python 3.9+
- OCI Autonomous Database（Always Free でも可）
- ORDS が有効化されていること（ADB ではデフォルトで有効）
- DB ユーザーに `ORDS_PUBLIC_USER` ロールが付与されていること

### pip でインストール

```bash
git clone https://github.com/hinoki-framework/hinoki.git
cd hinoki
pip install -e .
```

### 依存パッケージ

| パッケージ | 用途 |
|-----------|------|
| `oracledb` | Oracle Database 接続 (python-oracledb) |
| `click` | CLI フレームワーク |
| `pyyaml` | 設定ファイル読み込み |

---

## プロジェクト構成

`hinoki new myapp` で以下の構成が生成されます:

```
myapp/
├── hinoki.yml                # プロジェクト設定
├── config/
│   ├── database.yml          # DB接続情報 (.gitignore推奨)
│   └── routes.hk             # ルーティング定義
├── app/
│   ├── controllers/          # コントローラ (.hk または .sql)
│   ├── models/               # モデル (.hk または .sql)
│   └── views/
│       ├── layouts/           # レイアウトテンプレート
│       │   └── application.html
│       ├── posts/             # リソースごとのビュー
│       │   ├── index.html
│       │   ├── show.html
│       │   ├── new.html
│       │   └── edit.html
│       └── shared/            # 共有パーシャル
├── db/
│   └── migrate/              # マイグレーション (.hk または .sql)
├── public/                   # 静的ファイル
│   ├── css/
│   └── js/
└── test/
```

---

## .hk DSL リファレンス

### Model

モデルは `model` キーワードで定義します。ActiveRecord に似た宣言的構文で、CRUD・バリデーション・スコープ・関連付けを記述できます。

**ファイル名規約**: `app/models/<singular>.model.hk`

```ruby
# app/models/article.model.hk

model Article
  table :articles                                    # テーブル名 (省略時は自動複数形)

  permit :title, :body, :author, :published          # Strong Parameters

  # バリデーション
  validates :title, presence: true, length: { max: 500 }
  validates :body,  presence: true
  validates :email, uniqueness: true                 # ユニーク制約
  validates :age,   numericality: true               # 数値チェック

  # 関連付け
  has_many   :comments, foreign_key: :article_id
  belongs_to :category
  has_one    :metadata

  # スコープ (名前付きクエリ)
  scope :published,  -> { where "published = 1" }
  scope :recent,     -> { order "created_at DESC".limit 10 }
  scope :by_author,  -> { where "author = :author".order "title ASC" }

  # コールバック
  before_save   :set_defaults
  after_save    :update_cache
  before_delete :cleanup

  # カスタムメソッド
  def set_defaults
    self.view_count = 0
  end

  # 複雑なロジックは raw_plsql で生PL/SQL を記述
  def daily_summary(target_date)
    raw_plsql <<~SQL
      DECLARE
        v_cursor SYS_REFCURSOR;
      BEGIN
        OPEN v_cursor FOR
          SELECT author, COUNT(*) AS cnt,
                 SUM(view_count) AS total_views
          FROM articles
          WHERE TRUNC(created_at) = target_date
            AND published = 1
          GROUP BY author
          ORDER BY cnt DESC;
        RETURN v_cursor;
      END;
    SQL
  end
end
```

**自動生成される機能:**

| DSL | 生成される PL/SQL |
|-----|-----------------|
| `permit :title, :body` | `c_permitted CONSTANT := 'title,body'` + Strong Parameters |
| `validates :title, presence: true` | `hinoki_model.validates_presence('title', ...)` |
| `has_many :comments` | `FUNCTION comments(p_id) RETURN SYS_REFCURSOR` |
| `scope :published, ...` | `FUNCTION published(...) RETURN SYS_REFCURSOR` |
| `before_save :method` | コールバック呼び出しを create/update に挿入 |

すべてのモデルに自動で以下が生成されます:

- `all_records(p_page, p_per_page)` — ページネーション付き全件取得
- `find(p_id)` — ID で1件取得
- `create_record(p_params)` — バリデーション + INSERT
- `update_record(p_id, p_params)` — バリデーション + UPDATE
- `delete_record(p_id)` — DELETE
- `validate(p_params)` — バリデーション実行
- `all_as_json` / `find_as_json(p_id)` — JSON 出力

---

### Controller

コントローラは `controller` キーワードで定義します。Rails コントローラに似た直感的な構文です。

**ファイル名規約**: `app/controllers/<plural>.controller.hk`

```ruby
# app/controllers/articles.controller.hk

controller Articles
  before_action :require_login, except: [:index, :show]

  def index
    @posts = Article.published.paginate(params[:page])
    @pagination = Article.pagination_info(params[:page])
    render "articles/index"
  end

  def show
    @article = Article.find(params[:id])
    render "articles/show"
  end

  def new_form
    @page_title = "新しい記事"
    render "articles/new"
  end

  def create_action
    @article = Article.new(permit(:title, :body, :author))
    if @article.save
      redirect_to "/articles/#{@article.id}", flash: "作成しました！"
    else
      render "articles/new"
    end
  end

  def edit_form
    @article = Article.find(params[:id])
    render "articles/edit"
  end

  def update_action
    @article = Article.find(params[:id])
    @article.update(permit(:title, :body, :author, :published))
    redirect_to "/articles/#{@article.id}", flash: "更新しました"
  end

  def delete_action
    Article.delete(params[:id])
    redirect_to "/articles", flash: "削除しました"
  end
end
```

**DSL → PL/SQL 変換表:**

| DSL 構文 | 生成される PL/SQL |
|---------|-----------------|
| `params[:id]` | `hinoki_core.param_int('id')` |
| `params[:title]` | `hinoki_core.param('title')` |
| `@var = "text"` | `hinoki_view.assign('var', 'text')` |
| `Article.find(params[:id])` | カーソル → fetch → ビュー変数セット一式 |
| `Article.new(permit(...))` | `hinoki_controller.permit(...)` |
| `@obj.save` | `model.create_record(v_params)` + NULL チェック |
| `@obj.update(permit(...))` | `model.update_record(v_id, v_params)` |
| `Model.delete(params[:id])` | `model.delete_record(v_id)` |
| `render "template"` | `hinoki_view.render_to('template')` |
| `redirect_to "/path", flash: "msg"` | `hinoki_controller.redirect_to(...)` |
| `"...#{expr}..."` | `'...' \|\| expr \|\| '...'` (PL/SQL連結) |
| `if ... else ... end` | `IF ... ELSE ... END IF;` |

---

### Routes

ルーティングは `routes` ブロックで定義します。

**ファイル**: `config/routes.hk`

```ruby
routes "myapp" do
  # ルートパス
  root "home#index"

  # RESTful リソース (7つのルートを自動生成)
  resources :articles

  # ネストしたリソース
  resources :articles do
    resources :comments, only: [:create, :destroy]
  end

  # 個別ルート
  get  "/about"     => "pages#about"
  post "/contact"   => "pages#contact"
  get  "/search"    => "search#index"

  # 名前空間 (URLプレフィックス + コントローラ名プレフィックス)
  namespace :admin do
    resources :articles
    resources :users
  end

  # API 名前空間
  namespace :api do
    resources :articles, only: [:index, :show]
  end
end
```

**`resources :articles` が生成するルート:**

| Method | Path | Controller | Action |
|--------|------|-----------|--------|
| GET | /articles | articles_controller | index_action |
| GET | /articles/new | articles_controller | new_form |
| POST | /articles | articles_controller | create_action |
| GET | /articles/:id | articles_controller | show |
| GET | /articles/:id/edit | articles_controller | edit_form |
| PUT | /articles/:id | articles_controller | update_action |
| DELETE | /articles/:id | articles_controller | delete_action |
| POST | /articles/:id | articles_controller | update_action *(HTML form用)* |
| POST | /articles/:id/delete | articles_controller | delete_action *(HTML form用)* |

**`only` / `except` でフィルタ:**

```ruby
resources :comments, only: [:index, :create, :destroy]
resources :articles, except: [:destroy]
```

**`namespace` で生成されるルート例:**

```ruby
namespace :admin do
  resources :articles
end
# → GET /admin/articles → admin_articles_controller.index_action
```

---

### Migration

マイグレーションでスキーマを段階的に管理します。

**ファイル名規約**: `db/migrate/<timestamp>_<name>.hk`

```ruby
# db/migrate/20260404000001_create_articles.hk

migration "create_articles" do
  create_table :articles do
    string    :title, null: false, limit: 500      # VARCHAR2(500) NOT NULL
    text      :body                                  # CLOB
    string    :author, limit: 200                    # VARCHAR2(200)
    boolean   :published, default: false             # NUMBER(1) DEFAULT 0
    integer   :view_count, default: 0                # NUMBER(10) DEFAULT 0
    decimal   :price, precision: 10, scale: 2        # NUMBER(10,2)
    date      :published_on                          # DATE
    datetime  :last_viewed_at                        # TIMESTAMP
    references :category                             # category_id NUMBER + FK

    index     :published                             # CREATE INDEX ...
    index     [:author, :published], unique: true    # CREATE UNIQUE INDEX ...
  end
end
```

**型マッピング表:**

| DSL型 | Oracle 型 | オプション |
|------|----------|----------|
| `string` | `VARCHAR2(200)` | `limit:` で長さ指定 |
| `text` | `CLOB` | — |
| `integer` | `NUMBER(10)` | `limit:` で桁数指定 |
| `number` | `NUMBER` | — |
| `float` | `NUMBER(15,5)` | — |
| `decimal` | `NUMBER(20,8)` | `precision:`, `scale:` |
| `boolean` | `NUMBER(1)` | `default:` true/false → 1/0 |
| `date` | `DATE` | — |
| `datetime` | `TIMESTAMP` | — |
| `binary`/`blob` | `BLOB` | — |
| `references` | `NUMBER` + FK | `foreign_key:` でカラム名指定 |

**`id`, `created_at`, `updated_at` は自動付与されます。**

**その他の操作:**

```ruby
migration "add_slug_to_articles" do
  add_column    :articles, :slug, :string, limit: 300
  add_index     :articles, :slug, unique: true
  remove_column :articles, :old_field
  change_column :articles, :title, :text
  add_foreign_key :comments, :article_id, :articles
  execute "UPDATE articles SET slug = LOWER(REPLACE(title, ' ', '-'))"
end
```

---

### View テンプレート

ビューは HTML + Hinoki テンプレート構文で記述します。`.hk` 変換は不要（そのまま HTML）。

**ファイル名規約**: `app/views/<controller>/<action>.html`

#### {% for %} ループ

コレクション（JSON配列）をループして、自由なHTMLレイアウトで表示できます:

```html
<!-- app/views/articles/index.html -->
<h2>記事一覧</h2>

{% for post in posts %}
<article class="hinoki-card">
  <h3>
    <a href="/articles/{{ post.id }}">{{ post.title }}</a>
  </h3>
  <p class="meta">
    {{ post.author | default "匿名" }} · {{ post.created_at | time_ago }}
    · 閲覧数: {{ post.view_count | number_format }}
  </p>

  {% if post.published %}
    <span class="badge green">公開中</span>
  {% else %}
    <span class="badge gray">下書き</span>
  {% endif %}

  <p>{{ post.body | truncate 200 }}</p>

  <div class="actions">
    <a href="/articles/{{ post.id }}">詳細</a>
    <a href="/articles/{{ post.id }}/edit">編集</a>
  </div>
</article>
{% endfor %}

{{ pagination }}
```

**コントローラ側:**

```ruby
# .hk
def index
  @posts = Article.published.paginate(params[:page])
  render "articles/index"
end
```

これだけで `posts` コレクションがビューに渡り、`{% for %}` で自由にレイアウトできます。内部的にはカーソルが JSON 配列に変換され、ADB の `JSON_TABLE` で各行が展開されます。

#### ループ内で使えるヘルパー変数

| 変数 | 説明 |
|------|------|
| `{{ item._index }}` | 0始まりインデックス |
| `{{ item._number }}` | 1始まり番号 |
| `{{ item._first }}` | 最初の要素なら `1` |
| `{{ item._last }}` | 最後の要素なら `1` |

```html
{% for post in posts %}
  {{ post._number }}. {{ post.title }}
  {% if post._last %}
    <hr>以上 {{ post._number }} 件
  {% endif %}
{% endfor %}
```

#### パイプフィルター

`{{ value | filter }}` 構文で値を変換できます。ループ内でも通常変数でも使用可能です。

| フィルター | 説明 | 例 |
|-----------|------|---|
| `upcase` | 大文字変換 | `{{ name \| upcase }}` → `TARO` |
| `downcase` | 小文字変換 | `{{ name \| downcase }}` → `taro` |
| `capitalize` | 先頭大文字 | `{{ name \| capitalize }}` → `Taro` |
| `truncate N` | N文字で切り詰め | `{{ body \| truncate 100 }}` → `本文の最初の100文字...` |
| `time_ago` | 相対時間表示 | `{{ created_at \| time_ago }}` → `3日前` |
| `number_format` | 3桁カンマ区切り | `{{ price \| number_format }}` → `1,234,567` |
| `default "値"` | NULL時のデフォルト | `{{ author \| default "匿名" }}` → `匿名` |
| `strip_tags` | HTMLタグ除去 | `{{ html \| strip_tags }}` → テキストのみ |
| `h` | HTMLエスケープ | `{{ raw \| h }}` → `&lt;script&gt;` |

#### 単一レコードの表示

```html
<!-- app/views/articles/show.html -->
<h2>{{ title }}</h2>
<p class="meta">{{ author }} · {{ created_at }}</p>

{% if published %}
  <span class="badge">公開中</span>
{% else %}
  <span class="badge draft">下書き</span>
{% endif %}

<!-- エスケープなし (raw HTML) -->
<div class="body">{{{ body }}}</div>

<!-- パーシャル読み込み -->
{% partial "comments" %}
```

#### テンプレート構文一覧

| 構文 | 説明 |
|------|------|
| `{{ var }}` | HTMLエスケープ付き変数展開 |
| `{{{ var }}}` | エスケープなし (raw) 変数展開 |
| `{{ var \| filter }}` | フィルター適用 |
| `{% for item in coll %}...{% endfor %}` | コレクションループ |
| `{{ item.field }}` | ループ内フィールドアクセス |
| `{{ item.field \| filter }}` | ループ内フィルター |
| `{% if var %}...{% endif %}` | 条件分岐 |
| `{% if var %}...{% else %}...{% endif %}` | 条件分岐 + else |
| `{% if item.field %}...{% endif %}` | ループ内条件分岐 |
| `{% partial "name" %}` | パーシャル読み込み (`_name` テンプレート) |
| `{% yield %}` | レイアウト内でコンテンツ挿入位置 |

**レイアウト** (`app/views/layouts/application.html`):

```html
<!DOCTYPE html>
<html>
<head>
  <title>{{ page_title }} - MyApp</title>
</head>
<body>
  {{{ flash }}}
  {% yield %}
</body>
</html>
```

---

## CLI コマンド一覧

```bash
# プロジェクト管理
hinoki new <app_name>           # 新規プロジェクト作成
hinoki install                   # ADBにフレームワークをインストール
hinoki deploy                    # 全ファイルをADBにデプロイ

# コード生成
hinoki generate scaffold <name> <columns...>    # CRUD一式 (.hk)
hinoki generate scaffold <name> <columns...> --sql  # CRUD一式 (.sql)
hinoki generate migration <name>                # 空のマイグレーション

# データベース
hinoki migrate                   # 未実行マイグレーションを実行
hinoki migrate:rollback          # 直前のマイグレーションをロールバック

# 情報表示
hinoki routes                    # 登録済みルート一覧

# トランスパイラ
hinoki compile <file.hk>              # .hk → PL/SQL を標準出力
hinoki compile <file.hk> -o out.sql   # .hk → PL/SQL をファイル出力

# デバッグ
hinoki console                   # PL/SQL 対話コンソール
```

### カラム型の指定方法

`hinoki generate scaffold` で使える型:

```bash
hinoki generate scaffold product \
  name:string \          # VARCHAR2(200)
  description:text \     # CLOB
  price:number \         # NUMBER
  quantity:integer \     # NUMBER(10)
  active:boolean \       # NUMBER(1) DEFAULT 0
  released_on:date \     # DATE
  updated_at:timestamp   # TIMESTAMP
```

---

## .hk と .sql の共存

Hinoki の最大の特徴の一つは、**同じプロジェクト内で `.hk` と `.sql` を自由に混在**させられることです。

```
app/
├── controllers/
│   ├── articles.controller.hk      ← DSLで書いた軽量版
│   ├── comments.controller.hk      ← DSLで書いた軽量版
│   └── analytics_controller.sql    ← 複雑な集計は生PL/SQL
├── models/
│   ├── article.model.hk            ← DSL
│   ├── comment.model.hk            ← DSL
│   └── analytics_model.sql         ← ウィンドウ関数多用で生SQL
└── ...
```

`hinoki deploy` 時、CLI は拡張子を見て自動判別します:

- `.hk` → トランスパイラで PL/SQL に変換してから実行
- `.sql` → そのまま実行

### こんな使い分けがおすすめ

| ユースケース | 推奨形式 |
|------------|---------|
| 標準的な CRUD コントローラ | `.hk` |
| 単純なモデル | `.hk` |
| 複雑な分析クエリ | `.sql` |
| ウィンドウ関数・再帰CTE | `.sql` |
| バッチ処理・ETL | `.sql` |
| ルーティング | `.hk` |
| マイグレーション | `.hk` (シンプルな場合) / `.sql` (複雑な場合) |

### `.hk` 内での生PL/SQL埋め込み

ファイル単位だけでなく、`.hk` ファイルの**中**でも生 PL/SQL を書けます:

```ruby
model Analytics
  table :analytics_events

  # ここはDSL
  permit :event_type, :payload
  validates :event_type, presence: true

  # ここは生PL/SQL
  def complex_report(start_date)
    raw_plsql <<~SQL
      DECLARE
        v_cursor SYS_REFCURSOR;
      BEGIN
        OPEN v_cursor FOR
          SELECT event_type,
                 COUNT(*) AS cnt,
                 COUNT(DISTINCT session_id) AS uniq,
                 PERCENTILE_CONT(0.95) WITHIN GROUP
                   (ORDER BY response_ms) AS p95
          FROM analytics_events
          WHERE created_at >= start_date
          GROUP BY ROLLUP(event_type);
        RETURN v_cursor;
      END;
    SQL
  end
end
```

---

## トランスパイラの使い方

### コマンドラインで変換結果を確認

```bash
# 標準出力に PL/SQL を表示
hinoki compile app/models/article.model.hk

# ファイルに出力
hinoki compile app/models/article.model.hk -o article_model.sql

# コントローラも同様
hinoki compile app/controllers/articles.controller.hk
```

### Python API として使用

```python
from hinoki.transpiler import transpile, transpile_file
from pathlib import Path

# 文字列から変換
source = '''
model Post
  table :posts
  permit :title, :body
  validates :title, presence: true
end
'''
plsql = transpile(source, "post.model.hk")
print(plsql)

# ファイルから変換
plsql = transpile_file(Path("app/models/article.model.hk"))
```

---

## ADB 接続設定

### database.yml

```yaml
environment: development

development:
  username: ADMIN
  password: YourSecurePassword123!
  dsn: myatp_high                       # tnsnames.ora のサービス名
  wallet_location: /path/to/Wallet_myatp # Wallet展開先ディレクトリ

production:
  username: APP_USER
  password: YourSecurePassword123!
  dsn: myatp_high
  wallet_location: /path/to/Wallet_myatp
```

### Wallet のダウンロード

1. OCI Console → Autonomous Database → 対象DB → 「データベース接続」
2. 「ウォレットのダウンロード」→ パスワード設定 → ZIP ダウンロード
3. 任意のディレクトリに展開
4. `wallet_location` にそのディレクトリパスを設定

### mTLS なしの接続 (TLS)

ADB で mTLS 不要設定にしている場合:

```yaml
development:
  username: ADMIN
  password: YourSecurePassword123!
  dsn: "(description=(address=(protocol=tcps)(host=xxx.adb.ap-tokyo-1.oraclecloud.com)(port=1522))(connect_data=(service_name=xxx_myatp_high.adb.oraclecloud.com)))"
```

---

## ORDS とデプロイ

### デプロイの仕組み

`hinoki deploy` は以下を実行します:

1. `app/models/*.hk` → トランスパイル → `CREATE OR REPLACE PACKAGE` 実行
2. `app/models/*.sql` → そのまま実行
3. `app/controllers/*.hk` → トランスパイル → 実行
4. `app/controllers/*.sql` → そのまま実行
5. `app/views/**/*.html` → `hinoki_views` テーブルに MERGE
6. `config/routes.hk` → トランスパイル → ORDS モジュール登録

### ORDS URL

デプロイ後のURLは:

```
https://<your-adb>.adb.<region>.oraclecloudapps.com/ords/<schema>/<module_base_path>/<route>
```

例: `hinoki.yml` の `ords.base_path` が `/myblog/` の場合:

```
https://xxx.adb.ap-tokyo-1.oraclecloudapps.com/ords/admin/myblog/articles
```

### ORDS ユーザー設定

ADB の ADMIN ユーザーで以下を実行:

```sql
-- ORDS を有効化（通常は不要・デフォルトで有効）
BEGIN
    ORDS.enable_schema(
        p_enabled => TRUE,
        p_schema  => 'ADMIN',
        p_url_mapping_type => 'BASE_PATH',
        p_url_mapping_pattern => 'admin'
    );
    COMMIT;
END;
/
```

---

## フレームワーク内部構造

Hinoki は6つの PL/SQL パッケージで構成されます:

| パッケージ | 役割 |
|-----------|------|
| `hinoki_core` | リクエスト/レスポンス、セッション、Flash、CSRF、JSON/HTMLヘルパー |
| `hinoki_router` | ルーティング DSL → ORDS モジュール自動生成 |
| `hinoki_controller` | before_action、Strong Parameters、レンダリングショートカット |
| `hinoki_view` | テンプレートエンジン (変数展開、条件分岐、パーシャル、レイアウト) |
| `hinoki_model` | 動的 CRUD、バリデーション、ページネーション、JSON変換 |
| `hinoki_migrate` | スキーマバージョン管理、DDLヘルパー |

### フレームワークテーブル

`hinoki install` で以下のテーブルが作成されます:

| テーブル | 用途 |
|---------|------|
| `hinoki_config` | アプリ設定 (key-value) |
| `hinoki_migrations` | マイグレーション実行履歴 |
| `hinoki_routes` | ルート定義 |
| `hinoki_views` | ビューテンプレート格納 |
| `hinoki_sessions` | セッションデータ (JSON) |
| `hinoki_assets` | 静的アセット (BLOB) |

---

## サンプルアプリ: ブログ

`examples/blog/` に完全なブログアプリのサンプルがあります。

```
examples/blog/
├── config/routes.hk                              # ルーティング
├── app/
│   ├── models/article.model.hk                   # 記事モデル (DSL)
│   ├── controllers/
│   │   ├── articles.controller.hk                # 記事コントローラ (DSL)
│   │   └── analytics_controller.sql              # 分析コントローラ (生PL/SQL)
│   └── views/...
└── db/migrate/
    ├── 20260404000001_create_articles.hk          # 記事テーブル
    └── 20260404000002_create_comments.hk          # コメントテーブル
```

### サンプルの実行

```bash
cd examples/blog
# database.yml を設定後:
hinoki install
hinoki migrate
hinoki deploy
```

---

## Rails との対応表

| 概念 | Rails | Hinoki |
|------|-------|--------|
| 新規アプリ | `rails new app` | `hinoki new app` |
| Scaffold | `rails g scaffold` | `hinoki generate scaffold` |
| マイグレーション | `rails db:migrate` | `hinoki migrate` |
| ルーティング | `config/routes.rb` | `config/routes.hk` |
| コントローラ | `app/controllers/*.rb` | `app/controllers/*.hk` |
| モデル | `app/models/*.rb` | `app/models/*.hk` |
| ビュー | `app/views/*.erb` | `app/views/*.html` |
| レイアウト | `application.html.erb` | `layouts/application.html` |
| パーシャル | `_partial.html.erb` | `{% partial "name" %}` |
| Strong Params | `params.require().permit()` | `permit(:col1, :col2)` |
| コンソール | `rails console` | `hinoki console` |
| デプロイ | `cap deploy` / `git push heroku` | `hinoki deploy` |
| Webサーバー | Puma + Nginx | ORDS (ADB内蔵) |
| DB | PostgreSQL / MySQL | Oracle ADB |
| 言語 | Ruby | `.hk` DSL → PL/SQL |
| ORM | ActiveRecord | hinoki_model (Dynamic SQL) |
| テンプレート | ERB `<%= %>` | `{{ }}` / `{{{ }}}` |

### 最大の違い

Rails は **Ruby + Puma + PostgreSQL + Nginx** と複数のコンポーネントが必要ですが、Hinoki は **OCI Autonomous Database ひとつだけ** で完結します。

---

## 規約 (Convention over Configuration)

| 規約 | 例 |
|------|---|
| テーブル名は複数形 | `posts`, `comments`, `categories` |
| モデルパッケージは `<singular>_model` | `post_model`, `comment_model` |
| コントローラは `<plural>_controller` | `posts_controller` |
| ビューは `views/<plural>/<action>.html` | `views/posts/index.html` |
| パーシャルは `_` プレフィックス | `_comment.html` → `{% partial "comment" %}` |
| PK は `id` (IDENTITY) | 自動生成 |
| タイムスタンプ自動付与 | `created_at`, `updated_at` |
| マイグレーションファイルはタイムスタンプ順 | `20260404120000_create_posts.hk` |

---

## 制限事項・既知の問題

### 現在の制限

- **N+1 対策**: eager loading 相当の機能は未実装
- **ファイルアップロード**: OCI Object Storage 連携は未実装
- **WebSocket**: ORDS は WebSocket 非対応
- **ホットリロード**: `hinoki deploy` で手動デプロイが必要
- **テストフレームワーク**: 未実装（utPLSQL との連携を計画中）
- **コレクションサイズ**: `{% for %}` ループの JSON は 32KB まで（約100〜500行程度）。それ以上はページネーションで対応

### トランスパイラの制限

- `.hk` DSL はすべての PL/SQL 構文をカバーしていません。複雑なロジックは `raw_plsql` ブロックか `.sql` ファイルを使用してください
- コントローラの `if/else` ネストは1階層まで
- テンプレート内の式評価は単純な変数展開のみ

### ORDS の制限

- リクエストボディのサイズ上限あり（デフォルト約10MB）
- 同時接続数は ADB の設定に依存
- Basic認証 / OAuth2 は ORDS の機能として利用可能だが、Hinoki CLI からの設定は未対応

---

## ライセンス

MIT License. 詳細は [LICENSE](LICENSE) を参照してください。
