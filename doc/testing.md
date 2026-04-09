# テスト

Hinoki のテストは **2つのレベル** に分かれています。

## Level 1: トランスパイラ e2e テスト（ADB不要）

`.hk` ファイルを PL/SQL にトランスパイルし、生成された SQL の構造を検証します。  
**Oracle への接続不要**でローカルのみで実行できます。

```bash
# 全テスト実行（unit + Level 1 e2e）
uv run pytest

# blog サンプルアプリのテストだけ実行
uv run pytest tests/e2e/test_blog_e2e.py -v

# ユニットテストだけ実行
uv run pytest tests/test_transpiler.py -v
```

**blog サンプルアプリのテスト内容:**

| テストクラス | 対象ファイル | 検証内容 |
|-------------|------------|---------|
| `TestArticleModel` | `app/models/article.model.hk` | スコープ・バリデーション・アソシエーション・カスタムメソッド |
| `TestArticlesController` | `app/controllers/articles.controller.hk` | 全アクション宣言・render/redirect・permit |
| `TestBlogRoutes` | `config/routes.hk` | ルート生成・ネスト・API名前空間 |
| `TestBlogMigrations` | `db/migrate/*.hk` | テーブル構造・カラム型・インデックス |

## Level 2: フルスタック e2e テスト（ADB + ORDS 必要）

実際の ADB にデプロイして ORDS 経由の HTTP レスポンスまで確認します。  
`@pytest.mark.e2e` が付いたテストで、`--run-e2e` オプション付きのときのみ実行されます。

**前提条件:**
- ADB に Hinoki フレームワークがインストール済みであること（`hinoki install`）
- Blog アプリがデプロイ済みであること（`hinoki deploy`）

```bash
HINOKI_TEST_DSN=myadb_high \
HINOKI_TEST_USER=ADMIN \
HINOKI_TEST_PASSWORD=YourPassword! \
HINOKI_TEST_WALLET=/path/to/Wallet \
HINOKI_TEST_ORDS_URL=https://xxx.adb.region.oraclecloudapps.com/ords \
uv run pytest --run-e2e -v
```

**環境変数一覧:**

| 環境変数 | 説明 | 必須 |
|---------|------|------|
| `HINOKI_TEST_DSN` | ADB 接続サービス名（例: `myadb_high`） | ○ |
| `HINOKI_TEST_USER` | DB ユーザー名（デフォルト: `ADMIN`） | |
| `HINOKI_TEST_PASSWORD` | DB パスワード | ○ |
| `HINOKI_TEST_WALLET` | ウォレットフォルダのパス | |
| `HINOKI_TEST_ORDS_URL` | ORDS のベース URL | ○ |

## テストファイル構成

```
tests/
├── conftest.py                   # 共有フィクスチャ・--run-e2e オプション定義
├── test_transpiler.py            # トランスパイラのユニットテスト
└── e2e/
    ├── test_blog_e2e.py          # blog サンプルアプリの詳細テスト（ADB不要）
    ├── test_transpiler_e2e.py    # トランスパイラ汎用テスト（ADB不要）
    └── test_adb_e2e.py           # ADB デプロイ・HTTP テスト（--run-e2e 必要）
```
