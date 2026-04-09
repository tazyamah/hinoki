"""
Level 2: フルスタック e2e テスト（ADB + ORDS 必要）

実行方法:
  HINOKI_TEST_DSN=myadb_high \\
  HINOKI_TEST_USER=ADMIN \\
  HINOKI_TEST_PASSWORD=xxx \\
  HINOKI_TEST_WALLET=/path/to/Wallet \\
  HINOKI_TEST_ORDS_URL=https://xxx.adb.region.oraclecloudapps.com/ords \\
  pytest tests/e2e/test_adb_e2e.py --run-e2e -v

前提条件:
  - ADB に Hinoki フレームワークがインストール済みであること（hinoki install）
  - Blog アプリがデプロイ済みであること（hinoki deploy）
"""

import pytest
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from hinoki.transpiler import transpile


# ============================================================
# SQL実行ヘルパー（cli.py の execute_sql_file と同じロジック）
# ============================================================

def execute_sql(cursor, sql: str):
    """
    PL/SQL ブロックや DDL を含む SQL 文字列を実行する。
    - "\n/\n" でブロックを分割
    - コメント行・PROMPT 行を除去
    - 末尾の "/" を除去してから cursor.execute()
    """
    blocks = [b.strip() for b in sql.split("\n/\n") if b.strip()]
    if not blocks:
        blocks = [sql.strip()]

    for block in blocks:
        lines = [
            line for line in block.split("\n")
            if line.strip()
            and not line.strip().startswith("--")
            and not line.strip().startswith("PROMPT")
        ]
        clean = "\n".join(lines).strip()
        if clean.endswith("/"):
            clean = clean[:-1].strip()
        if not clean:
            continue
        cursor.execute(clean)


def framework_installed(db_connection) -> bool:
    """Hinoki フレームワークが ADB にインストールされているか確認"""
    cursor = db_connection.cursor()
    cursor.execute(
        "SELECT COUNT(*) FROM user_objects WHERE object_name = 'HINOKI_CORE' AND object_type = 'PACKAGE'"
    )
    (count,) = cursor.fetchone()
    return count > 0


# ============================================================
# ADB デプロイ検証テスト
# ============================================================

@pytest.mark.e2e
class TestAdbDeploy:
    """トランスパイルした SQL を ADB に実際にデプロイして検証"""

    @pytest.fixture(autouse=True)
    def check_framework(self, db_connection):
        """フレームワーク未インストールならテストをスキップ"""
        if not framework_installed(db_connection):
            pytest.skip(
                "Hinoki フレームワークが ADB にインストールされていません。"
                "先に `hinoki install` を実行してください。"
            )

    def test_model_package_deployable(self, db_connection):
        """
        .hk ファイルをトランスパイルした SQL が ADB にデプロイできること。
        テスト後にパッケージを削除してクリーンアップする。
        """
        source = """
model E2eTestArticle
  table :e2e_test_articles
  permit :title, :body
end
"""
        sql = transpile(source, "e2e_test_article.model.hk")
        cursor = db_connection.cursor()

        try:
            execute_sql(cursor, sql)
            db_connection.commit()

            # SPEC・BODY 両方が作成されているか確認
            cursor.execute(
                """
                SELECT object_type FROM user_objects
                WHERE object_name = 'E2E_TEST_ARTICLE_MODEL'
                ORDER BY object_type
                """
            )
            types = {row[0] for row in cursor.fetchall()}
            assert "PACKAGE" in types, "PACKAGE SPEC が作成されていません"
            assert "PACKAGE BODY" in types, "PACKAGE BODY が作成されていません"

        finally:
            # クリーンアップ
            for obj_type in ("PACKAGE BODY", "PACKAGE"):
                try:
                    cursor.execute(f"DROP {obj_type} e2e_test_article_model")
                    db_connection.commit()
                except Exception:
                    pass

    def test_migration_creates_table(self, db_connection):
        """
        マイグレーション SQL が実際にテーブルを作成できること。
        テスト後にテーブルを削除してクリーンアップする。
        """
        source = """
migration "create_e2e_test_items" do
  create_table :e2e_test_items do
    string :name, null: false
    integer :qty, default: 0
  end
end
"""
        sql = transpile(source, "migration.hk")
        cursor = db_connection.cursor()

        # 既存テーブルを削除してからテスト
        try:
            cursor.execute("DROP TABLE e2e_test_items")
            db_connection.commit()
        except Exception:
            pass

        try:
            execute_sql(cursor, sql)
            db_connection.commit()

            # テーブル存在確認
            cursor.execute(
                "SELECT table_name FROM user_tables WHERE table_name = 'E2E_TEST_ITEMS'"
            )
            assert cursor.fetchone(), "e2e_test_items テーブルが作成されていません"

            # カラム確認
            cursor.execute(
                """
                SELECT column_name, data_type, nullable
                FROM user_tab_columns
                WHERE table_name = 'E2E_TEST_ITEMS'
                ORDER BY column_id
                """
            )
            columns = {row[0]: {"type": row[1], "nullable": row[2]} for row in cursor.fetchall()}
            assert "NAME" in columns, "name カラムがありません"
            assert columns["NAME"]["nullable"] == "N", "name は NOT NULL のはずです"
            assert "QTY" in columns, "qty カラムがありません"

        finally:
            try:
                cursor.execute("DROP TABLE e2e_test_items")
                db_connection.commit()
            except Exception:
                pass

    def test_blog_model_deployable(self, db_connection):
        """
        blog サンプルの article.model.hk が ADB にデプロイできること。
        """
        blog_dir = Path(__file__).parent.parent.parent / "examples" / "blog"
        source = (blog_dir / "app" / "models" / "article.model.hk").read_text()
        sql = transpile(source, "article.model.hk")
        cursor = db_connection.cursor()

        # デプロイ実行（既存パッケージは上書き）
        execute_sql(cursor, sql)
        db_connection.commit()

        # パッケージが有効な状態（VALID）か確認
        cursor.execute(
            """
            SELECT object_type, status FROM user_objects
            WHERE object_name = 'ARTICLE_MODEL'
            ORDER BY object_type
            """
        )
        rows = {row[0]: row[1] for row in cursor.fetchall()}
        assert rows.get("PACKAGE") == "VALID", f"PACKAGE が VALID ではありません: {rows}"
        assert rows.get("PACKAGE BODY") == "VALID", f"PACKAGE BODY が VALID ではありません: {rows}"


# ============================================================
# ORDS HTTP テスト
# ============================================================

@pytest.fixture
def http(request):
    """requests.Session を提供。なければスキップ。"""
    try:
        import requests
        session = requests.Session()
        session.max_redirects = 5
        return session
    except ImportError:
        pytest.skip("requests がインストールされていません: pip install requests")


@pytest.mark.e2e
class TestOrdsHttp:
    """ORDS 経由で HTTP リクエストを送り、アプリの動作を検証"""

    def test_root_returns_200(self, http, ords_base_url):
        resp = http.get(f"{ords_base_url}/blog/", timeout=10)
        assert resp.status_code == 200, f"ルートが 200 を返しません: {resp.status_code}"

    def test_articles_index_returns_200(self, http, ords_base_url):
        resp = http.get(f"{ords_base_url}/blog/articles", timeout=10)
        assert resp.status_code == 200, f"記事一覧が {resp.status_code} を返しました"

    def test_api_articles_returns_json(self, http, ords_base_url):
        resp = http.get(
            f"{ords_base_url}/blog/api/articles",
            headers={"Accept": "application/json"},
            timeout=10,
        )
        assert resp.status_code == 200, f"ステータス: {resp.status_code}"
        data = resp.json()
        # Hinoki の JSON レスポンスは {"items": [...], "total": N} 形式
        assert "items" in data or isinstance(data, list), \
            f"予期しない JSON 構造: {list(data.keys()) if isinstance(data, dict) else type(data)}"


@pytest.mark.e2e
class TestArticleCrudFlow:
    """
    記事の CRUD フロー全体をテスト。

    フロー: 作成 → API で確認 → 更新 → API で確認 → 削除 → API で確認
    ユニークなタイトルを使って他テストと干渉しないようにする。
    """

    # テスト用にユニークなタイトルプレフィックスを使用
    TITLE_PREFIX = "[e2e-test]"

    @pytest.fixture(autouse=True)
    def cleanup(self, http, ords_base_url):
        """テスト後に e2e テスト記事を削除する"""
        yield
        # テスト後のクリーンアップ：e2e タイトルの記事を全削除
        try:
            resp = http.get(
                f"{ords_base_url}/blog/api/articles",
                headers={"Accept": "application/json"},
                timeout=10,
            )
            if resp.status_code == 200:
                data = resp.json()
                items = data.get("items", data) if isinstance(data, dict) else data
                for item in items:
                    if self.TITLE_PREFIX in str(item.get("title", "")):
                        article_id = item.get("id")
                        if article_id:
                            http.post(
                                f"{ords_base_url}/blog/articles/{article_id}/delete",
                                timeout=10,
                            )
        except Exception:
            pass  # クリーンアップ失敗はテスト結果に影響させない

    def _get_articles_json(self, http, ords_base_url):
        resp = http.get(
            f"{ords_base_url}/blog/api/articles",
            headers={"Accept": "application/json"},
            timeout=10,
        )
        assert resp.status_code == 200, f"API 取得失敗: {resp.status_code}"
        data = resp.json()
        return data.get("items", data) if isinstance(data, dict) else data

    def test_create_article(self, http, ords_base_url):
        """記事を作成できること"""
        unique_title = f"{self.TITLE_PREFIX} 作成テスト {uuid.uuid4().hex[:8]}"

        resp = http.post(
            f"{ords_base_url}/blog/articles",
            data={
                "title": unique_title,
                "body": "e2e テストで作成した記事です。",
                "author": "e2e-tester",
            },
            timeout=10,
        )
        assert resp.status_code == 200, f"作成後のページが返りませんでした: {resp.status_code}"

        # API で作成された記事を確認
        items = self._get_articles_json(http, ords_base_url)
        titles = [item.get("title", "") for item in items]
        assert unique_title in titles, \
            f"作成した記事がAPIに反映されていません。一覧: {titles}"

    def test_update_article(self, http, ords_base_url):
        """記事を更新できること"""
        unique_title = f"{self.TITLE_PREFIX} 更新テスト {uuid.uuid4().hex[:8]}"
        updated_title = unique_title + " (更新済)"

        # まず作成
        http.post(
            f"{ords_base_url}/blog/articles",
            data={"title": unique_title, "body": "更新前の本文", "author": "e2e-tester"},
            timeout=10,
        )

        # API で ID を取得
        items = self._get_articles_json(http, ords_base_url)
        article = next((i for i in items if i.get("title") == unique_title), None)
        assert article, f"作成した記事が見つかりません。一覧: {[i.get('title') for i in items]}"
        article_id = article["id"]

        # 更新
        resp = http.post(
            f"{ords_base_url}/blog/articles/{article_id}",
            data={"title": updated_title, "body": "更新後の本文", "author": "e2e-tester"},
            timeout=10,
        )
        assert resp.status_code == 200, f"更新後のページが返りませんでした: {resp.status_code}"

        # API で更新後の内容を確認
        resp = http.get(
            f"{ords_base_url}/blog/api/articles/{article_id}",
            headers={"Accept": "application/json"},
            timeout=10,
        )
        assert resp.status_code == 200
        updated = resp.json()
        assert updated.get("title") == updated_title, \
            f"タイトルが更新されていません: {updated.get('title')}"

    def test_delete_article(self, http, ords_base_url):
        """記事を削除できること"""
        unique_title = f"{self.TITLE_PREFIX} 削除テスト {uuid.uuid4().hex[:8]}"

        # 作成
        http.post(
            f"{ords_base_url}/blog/articles",
            data={"title": unique_title, "body": "削除される記事", "author": "e2e-tester"},
            timeout=10,
        )

        # ID 取得
        items = self._get_articles_json(http, ords_base_url)
        article = next((i for i in items if i.get("title") == unique_title), None)
        assert article, "削除対象の記事が見つかりません"
        article_id = article["id"]

        # 削除
        resp = http.post(
            f"{ords_base_url}/blog/articles/{article_id}/delete",
            timeout=10,
        )
        assert resp.status_code == 200, f"削除後のページが返りませんでした: {resp.status_code}"

        # API で消えているか確認
        resp = http.get(
            f"{ords_base_url}/blog/api/articles/{article_id}",
            headers={"Accept": "application/json"},
            timeout=10,
        )
        assert resp.status_code in (404, 200), f"予期しないステータス: {resp.status_code}"
        if resp.status_code == 200:
            data = resp.json()
            # 空レスポンスまたは null であれば削除成功
            assert not data or data.get("id") is None, \
                f"記事が削除されていません: {data}"

    def test_full_crud_flow(self, http, ords_base_url):
        """作成→更新→削除の一連フローを1テストで確認"""
        unique_id = uuid.uuid4().hex[:8]
        title_v1 = f"{self.TITLE_PREFIX} フロー {unique_id} v1"
        title_v2 = f"{self.TITLE_PREFIX} フロー {unique_id} v2"

        # 1. 作成
        http.post(
            f"{ords_base_url}/blog/articles",
            data={"title": title_v1, "body": "初版", "author": "e2e-tester"},
            timeout=10,
        )
        items = self._get_articles_json(http, ords_base_url)
        article = next((i for i in items if i.get("title") == title_v1), None)
        assert article, f"作成失敗: {[i.get('title') for i in items]}"
        article_id = article["id"]

        # 2. 更新
        http.post(
            f"{ords_base_url}/blog/articles/{article_id}",
            data={"title": title_v2, "body": "改訂版", "author": "e2e-tester"},
            timeout=10,
        )
        resp = http.get(
            f"{ords_base_url}/blog/api/articles/{article_id}",
            headers={"Accept": "application/json"},
            timeout=10,
        )
        assert resp.json().get("title") == title_v2, "更新が反映されていません"

        # 3. 削除
        http.post(f"{ords_base_url}/blog/articles/{article_id}/delete", timeout=10)
        resp = http.get(
            f"{ords_base_url}/blog/api/articles/{article_id}",
            headers={"Accept": "application/json"},
            timeout=10,
        )
        data = resp.json()
        assert not data or data.get("id") is None, "削除が反映されていません"
