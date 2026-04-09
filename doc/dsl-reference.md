# .hk DSL リファレンス

- [Model](#model)
- [Controller](#controller)
- [Routes](#routes)
- [Migration](#migration)
- [View テンプレート](#view-テンプレート)
- [.hk と .sql の共存](#hk-と-sql-の共存)

---

## Model

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

## Controller

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

## Routes

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

---

## Migration

マイグレーションでスキーマを管理します。

**ファイル名規約**: `db/migrate/<timestamp>_<name>.hk`

```ruby
migration "create_articles" do
  create_table :articles do
    string    :title, null: false, limit: 500
    text      :body
    string    :author, limit: 200
    boolean   :published, default: false
    integer   :view_count, default: 0
    index     :published
    index     [:author, :published]
  end
end
```

**カラム型対応表:**

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

## View テンプレート

ビューは HTML + Hinoki テンプレート構文で記述します。`.hk` 変換は不要（そのまま HTML）。

**ファイル名規約**: `app/views/<controller>/<action>.html`

### {% for %} ループ

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

**ループ内で使えるヘルパー変数:**

| 変数 | 説明 |
|------|------|
| `{{ item._index }}` | 0始まりインデックス |
| `{{ item._number }}` | 1始まり番号 |
| `{{ item._first }}` | 最初の要素なら `1` |
| `{{ item._last }}` | 最後の要素なら `1` |

### パイプフィルター

`{{ value | filter }}` 構文で値を変換できます。

| フィルター | 説明 | 例 |
|-----------|------|---|
| `upcase` | 大文字変換 | `{{ name \| upcase }}` → `TARO` |
| `downcase` | 小文字変換 | `{{ name \| downcase }}` → `taro` |
| `capitalize` | 先頭大文字 | `{{ name \| capitalize }}` → `Taro` |
| `truncate N` | N文字で切り詰め | `{{ body \| truncate 100 }}` |
| `time_ago` | 相対時間表示 | `{{ created_at \| time_ago }}` → `3日前` |
| `number_format` | 3桁カンマ区切り | `{{ price \| number_format }}` → `1,234,567` |
| `default "値"` | NULL時のデフォルト | `{{ author \| default "匿名" }}` |
| `strip_tags` | HTMLタグ除去 | — |
| `h` | HTMLエスケープ | `{{ raw \| h }}` → `&lt;script&gt;` |

### テンプレート構文一覧

| 構文 | 説明 |
|------|------|
| `{{ var }}` | HTMLエスケープ付き変数展開 |
| `{{{ var }}}` | エスケープなし (raw) 変数展開 |
| `{{ var \| filter }}` | フィルター適用 |
| `{% for item in coll %}...{% endfor %}` | コレクションループ |
| `{% if var %}...{% endif %}` | 条件分岐 |
| `{% if var %}...{% else %}...{% endif %}` | 条件分岐 + else |
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

## .hk と .sql の共存

同じプロジェクト内で `.hk` と `.sql` を自由に混在させられます。

```
app/
├── controllers/
│   ├── articles.controller.hk      ← DSLで書いた軽量版
│   └── analytics_controller.sql    ← 複雑な集計は生PL/SQL
├── models/
│   ├── article.model.hk            ← DSL
│   └── analytics_model.sql         ← ウィンドウ関数多用で生SQL
```

`hinoki deploy` 時、CLI は拡張子を見て自動判別します:

- `.hk` → トランスパイラで PL/SQL に変換してから実行
- `.sql` → そのまま実行

**こんな使い分けがおすすめ:**

| ユースケース | 推奨形式 |
|------------|---------|
| 標準的な CRUD コントローラ | `.hk` |
| 単純なモデル | `.hk` |
| 複雑な分析クエリ・ウィンドウ関数 | `.sql` |
| バッチ処理・ETL | `.sql` |

**`.hk` ファイルの中でも生 PL/SQL を書けます:**

```ruby
model Analytics
  table :analytics_events
  permit :event_type, :payload
  validates :event_type, presence: true

  def complex_report(start_date)
    raw_plsql <<~SQL
      DECLARE
        v_cursor SYS_REFCURSOR;
      BEGIN
        OPEN v_cursor FOR
          SELECT event_type, COUNT(*) AS cnt
          FROM analytics_events
          WHERE created_at >= start_date
          GROUP BY ROLLUP(event_type);
        RETURN v_cursor;
      END;
    SQL
  end
end
```
