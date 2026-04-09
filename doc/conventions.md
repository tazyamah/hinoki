# 規約・Rails との対応表・制限事項

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

**最大の違い**: Rails は **Ruby + Puma + PostgreSQL + Nginx** と複数コンポーネントが必要ですが、Hinoki は **OCI Autonomous Database ひとつだけ** で完結します。

---

## 制限事項・既知の問題

### 現在の制限

- **N+1 対策**: eager loading 相当の機能は未実装
- **ファイルアップロード**: OCI Object Storage 連携は未実装
- **WebSocket**: ORDS は WebSocket 非対応
- **ホットリロード**: `hinoki deploy` で手動デプロイが必要
- **ADB上のPL/SQL単体テスト**: utPLSQL 連携は未実装
- **コレクションサイズ**: `{% for %}` ループの JSON は 32KB まで（約100〜500行程度）。それ以上はページネーションで対応

### トランスパイラの制限

- `.hk` DSL はすべての PL/SQL 構文をカバーしていません。複雑なロジックは `raw_plsql` ブロックか `.sql` ファイルを使用してください
- コントローラの `if/else` ネストは1階層まで
- テンプレート内の式評価は単純な変数展開のみ

### ORDS の制限

- リクエストボディのサイズ上限あり（デフォルト約10MB）
- 同時接続数は ADB の設定に依存
- Basic認証 / OAuth2 は ORDS の機能として利用可能だが、Hinoki CLI からの設定は未対応
