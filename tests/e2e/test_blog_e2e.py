"""
Blog アプリ e2e テスト（ADB不要）

examples/blog の全ファイルをトランスパイルし、
実際のアプリ仕様に沿った詳細な構造検証を行う。
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from hinoki.transpiler import transpile

BLOG_DIR = Path(__file__).parent.parent.parent / "examples" / "blog"


def read_hk(relative_path: str) -> str:
    return (BLOG_DIR / relative_path).read_text()


# ============================================================
# article.model.hk
# ============================================================

class TestArticleModel:

    def setup_method(self):
        self.sql = transpile(
            read_hk("app/models/article.model.hk"),
            "article.model.hk",
        )

    def test_package_name(self):
        assert "article_model" in self.sql

    def test_table_name(self):
        assert "'articles'" in self.sql

    def test_permitted_fields(self):
        # permit :title, :body, :author, :published
        assert "title" in self.sql
        assert "body" in self.sql
        assert "author" in self.sql
        assert "published" in self.sql

    def test_validates_title_presence(self):
        assert "validates_presence" in self.sql

    def test_validates_title_length(self):
        # validates :title, length: { max: 500 }
        assert "validates_length" in self.sql
        assert "500" in self.sql

    def test_scope_published(self):
        assert "FUNCTION published" in self.sql
        assert "published = 1" in self.sql

    def test_scope_recent(self):
        assert "FUNCTION recent" in self.sql

    def test_scope_by_author(self):
        assert "FUNCTION by_author" in self.sql

    def test_has_many_comments(self):
        assert "FUNCTION comments" in self.sql
        assert "article_id" in self.sql

    def test_before_save_callback(self):
        assert "set_defaults" in self.sql

    def test_custom_method_increment_views(self):
        assert "increment_views" in self.sql
        assert "view_count" in self.sql

    def test_standard_crud_methods(self):
        for method in ["all_records", "find", "create_record",
                       "update_record", "delete_record", "validate"]:
            assert method in self.sql, f"標準メソッド不足: {method}"

    def test_json_methods(self):
        assert "all_as_json" in self.sql
        assert "find_as_json" in self.sql


# ============================================================
# articles.controller.hk
# ============================================================

class TestArticlesController:

    def setup_method(self):
        self.sql = transpile(
            read_hk("app/controllers/articles.controller.hk"),
            "articles.controller.hk",
        )

    def test_package_name(self):
        assert "articles_controller" in self.sql

    def test_all_actions_declared(self):
        spec = self.sql.split("CREATE OR REPLACE PACKAGE BODY")[0]
        for action in ["index", "show", "new_form", "create_action",
                       "edit_form", "update_action", "delete_action"]:
            assert f"PROCEDURE {action};" in spec, f"SPEC に宣言なし: {action}"

    def test_index_renders_template(self):
        assert "articles/index" in self.sql

    def test_index_uses_published_scope(self):
        assert "article_model.published" in self.sql

    def test_index_uses_paginate(self):
        assert "assign_collection" in self.sql

    def test_show_finds_article(self):
        assert "article_model.find" in self.sql

    def test_create_uses_permit(self):
        assert "hinoki_controller.permit" in self.sql

    def test_create_redirects_on_success(self):
        assert "hinoki_controller.redirect_to" in self.sql
        assert "記事を作成しました" in self.sql

    def test_update_redirects(self):
        assert "記事を更新しました" in self.sql

    def test_delete_redirects(self):
        assert "記事を削除しました" in self.sql


# ============================================================
# config/routes.hk
# ============================================================

class TestBlogRoutes:

    def setup_method(self):
        self.sql = transpile(
            read_hk("config/routes.hk"),
            "routes.hk",
        )

    def test_deploy_routes_blog(self):
        assert "deploy_routes('blog')" in self.sql

    def test_root_route(self):
        assert "hinoki_router.root" in self.sql

    def test_articles_index(self):
        assert "hinoki_router.get('/articles'" in self.sql

    def test_articles_create(self):
        assert "hinoki_router.post('/articles'" in self.sql

    def test_articles_show(self):
        assert "hinoki_router.get('/articles/:id'" in self.sql

    def test_nested_comments_create(self):
        assert "/articles/:id/comments" in self.sql

    def test_api_namespace(self):
        assert "/api/articles" in self.sql
        assert "api_articles_controller" in self.sql

    def test_custom_get_route(self):
        assert "hinoki_router.get('/about'" in self.sql

    def test_custom_post_route(self):
        assert "hinoki_router.post('/contact'" in self.sql


# ============================================================
# db/migrate/
# ============================================================

class TestBlogMigrations:

    def test_create_articles_table(self):
        sql = transpile(
            read_hk("db/migrate/20260404000001_create_articles.hk"),
            "20260404000001_create_articles.hk",
        )
        assert "hinoki_migrate.create_table" in sql
        assert "'articles'" in sql
        # カラム型の検証
        assert "VARCHAR2(500)" in sql    # title limit: 500
        assert "CLOB" in sql            # body text
        assert "NUMBER(1)" in sql       # published boolean
        # インデックス
        assert "hinoki_migrate.add_index" in sql

    def test_create_articles_columns(self):
        sql = transpile(
            read_hk("db/migrate/20260404000001_create_articles.hk"),
            "20260404000001_create_articles.hk",
        )
        # カラム名は SQL 文字列中に埋め込まれる（例: 'title VARCHAR2(500) NOT NULL, ...'）
        assert "title" in sql
        assert "body" in sql
        assert "author" in sql
        assert "published" in sql
        assert "view_count" in sql

    def test_create_comments_table(self):
        sql = transpile(
            read_hk("db/migrate/20260404000002_create_comments.hk"),
            "20260404000002_create_comments.hk",
        )
        assert "hinoki_migrate.create_table" in sql
        assert "'comments'" in sql
        assert "hinoki_migrate.add_index" in sql

    def test_create_comments_references_articles(self):
        sql = transpile(
            read_hk("db/migrate/20260404000002_create_comments.hk"),
            "20260404000002_create_comments.hk",
        )
        # references :articles → article_id カラム + インデックス
        assert "article_id" in sql
