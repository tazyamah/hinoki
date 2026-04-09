# フレームワーク内部構造

## PL/SQL パッケージ構成

Hinoki は6つの PL/SQL パッケージで構成されます:

| パッケージ | 役割 |
|-----------|------|
| `hinoki_core` | リクエスト/レスポンス、セッション、Flash、CSRF、JSON/HTMLヘルパー |
| `hinoki_router` | ルーティング DSL → ORDS モジュール自動生成 |
| `hinoki_controller` | before_action、Strong Parameters、レンダリングショートカット |
| `hinoki_view` | テンプレートエンジン (変数展開、条件分岐、パーシャル、レイアウト) |
| `hinoki_model` | 動的 CRUD、バリデーション、ページネーション、JSON変換 |
| `hinoki_migrate` | スキーマバージョン管理、DDLヘルパー |

## フレームワークテーブル

`hinoki install` で以下のテーブルが作成されます:

| テーブル | 用途 |
|---------|------|
| `hinoki_config` | アプリ設定 (key-value) |
| `hinoki_migrations` | マイグレーション実行履歴 |
| `hinoki_routes` | ルート定義 |
| `hinoki_views` | ビューテンプレート格納 |
| `hinoki_sessions` | セッションデータ (JSON) |
| `hinoki_assets` | 静的アセット (BLOB) |

## アーキテクチャ

```
ブラウザ
  ↓ HTTP
ORDS (Oracle REST Data Services)
  ↓ PL/SQL 呼び出し
hinoki_router → コントローラ PACKAGE
  ↓
hinoki_controller / hinoki_model
  ↓
Oracle Database (テーブル)
  ↓ 結果
hinoki_view (テンプレートエンジン)
  ↓ HTML/JSON
ブラウザ
```

すべての処理が Oracle ADB の中で完結するため、アプリケーションサーバーや Web サーバーは不要です。
