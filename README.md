# 🌲 Hinoki — Full-Stack Web Framework for OCI Autonomous Database

**Hinoki（檜）** は、OCI Autonomous Database（ADB）のみで完結するフルスタック Web フレームワークです。

- **ORDS** が HTTP サーバー（Web サーバー/AP サーバー不要）
- **PL/SQL** がアプリケーションロジック（MVC）
- **Oracle Database** がデータストア + テンプレート + セッション

Ruby-like な `.hk` DSL で記述し、PL/SQL にトランスパイルして ADB にデプロイします。

```
.hk ファイル ──→ [トランスパイラ] ──→ PL/SQL ──→ ADB
                                        ↑
.sql ファイル ──────────────────────────┘ (そのまま)
```

---

## インストール

**前提条件:**
- Python 3.9+
- OCI Autonomous Database（Always Free でも可）
- ORDS が有効化されていること（ADB ではデフォルトで有効）

```bash
git clone https://github.com/hinoki-framework/hinoki.git
cd hinoki
pip install -e .
```

---

## クイックスタート

```bash
# 1. 新規アプリ作成
hinoki new myblog
cd myblog

# 2. ADB 接続情報を設定（対話形式）
hinoki db:init

# 3. フレームワークを ADB にインストール（初回のみ）
hinoki install

# 4. scaffold で CRUD 一式を生成
hinoki generate scaffold post title:string body:text author:string published:boolean

# 5. マイグレーション実行
hinoki migrate

# 6. routes.hk にリソースを追加
echo 'routes "myblog" do
  root "posts#index"
  resources :posts
end' > config/routes.hk

# 7. ADB にデプロイ
hinoki deploy

# 8. ブラウザでアクセス
# → https://<your-adb>.adb.<region>.oraclecloudapps.com/ords/myblog/posts
```

---

## ドキュメント

| ドキュメント | 内容 |
|------------|------|
| [DSL リファレンス](doc/dsl-reference.md) | Model / Controller / Routes / Migration / View テンプレートの書き方 |
| [CLI コマンド一覧](doc/cli.md) | hinoki コマンドの全オプション・scaffold の型指定・Python API |
| [ADB 接続設定](doc/adb-connection.md) | database.yml の生成・Wallet のダウンロード・プロジェクト構成 |
| [デプロイ・ORDS](doc/deploy.md) | デプロイの仕組み・ORDS URL・ユーザー設定 |
| [テスト](doc/testing.md) | pytest によるトランスパイラ検証・ADB フルスタック e2e テスト |
| [フレームワーク内部構造](doc/internals.md) | PL/SQL パッケージ構成・フレームワークテーブル |
| [規約・Rails 対応表・制限事項](doc/conventions.md) | 命名規約・Rails との違い・既知の制限 |

サンプルアプリ（ブログ）は [`examples/blog/`](examples/blog/) にあります。

---

## ライセンス

MIT License. 詳細は [LICENSE](LICENSE) を参照してください。
