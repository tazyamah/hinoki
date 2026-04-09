"""
Level 1: トランスパイラ e2e テスト（ADB不要）

実際の .hk ファイルを読み込み、トランスパイル → SQL検証まで一気通貫でテストする。
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from hinoki.transpiler import transpile


class TestBlogExampleTranspilation:
    """examples/blog の全ファイルをトランスパイルして構造を検証"""

    def test_article_model_transpiles(self, examples_blog_dir):
        hk_file = examples_blog_dir / "app" / "models" / "article.model.hk"
        source = hk_file.read_text()
        result = transpile(source, str(hk_file))

        assert result, "出力が空です"
        assert "CREATE OR REPLACE PACKAGE article_model" in result
        assert "CREATE OR REPLACE PACKAGE BODY article_model" in result
        # 標準CRUDメソッドが揃っているか
        for method in ["all_records", "find", "create_record", "update_record", "delete_record"]:
            assert method in result, f"メソッド不足: {method}"

    def test_articles_controller_transpiles(self, examples_blog_dir):
        hk_file = examples_blog_dir / "app" / "controllers" / "articles.controller.hk"
        source = hk_file.read_text()
        result = transpile(source, str(hk_file))

        assert result, "出力が空です"
        assert "CREATE OR REPLACE PACKAGE articles_controller" in result

    def test_routes_transpiles(self, examples_blog_dir):
        hk_file = examples_blog_dir / "config" / "routes.hk"
        source = hk_file.read_text()
        result = transpile(source, str(hk_file))

        assert result, "出力が空です"
        assert "hinoki_router" in result
        assert "deploy_routes" in result

    def test_migrations_transpile(self, examples_blog_dir):
        migrate_dir = examples_blog_dir / "db" / "migrate"
        hk_files = list(migrate_dir.glob("*.hk"))
        assert hk_files, "マイグレーションファイルが見つかりません"

        for hk_file in hk_files:
            source = hk_file.read_text()
            result = transpile(source, str(hk_file))
            assert result, f"{hk_file.name} の出力が空です"
            assert "hinoki_migrate" in result, f"{hk_file.name} に hinoki_migrate が含まれていません"

    def test_all_hk_files_produce_output(self, examples_blog_dir):
        """examples/blog 内の全 .hk ファイルがエラーなしにトランスパイルされること"""
        hk_files = list(examples_blog_dir.rglob("*.hk"))
        assert hk_files, ".hk ファイルが見つかりません"

        failed = []
        for hk_file in hk_files:
            try:
                result = transpile(hk_file.read_text(), str(hk_file))
                if not result:
                    failed.append(f"{hk_file.name}: 出力が空")
            except Exception as e:
                failed.append(f"{hk_file.name}: {e}")

        assert not failed, "トランスパイル失敗:\n" + "\n".join(failed)


class TestGeneratedSqlStructure:
    """生成された SQL が Oracle PL/SQL として正しい構造を持つか検証"""

    def test_package_spec_and_body_present(self):
        source = """
model Article
  table :articles
  permit :title, :body
end
"""
        result = transpile(source, "article.model.hk")
        # SPEC（宣言部）と BODY（実装部）の両方が存在するか
        assert "CREATE OR REPLACE PACKAGE article_model AS" in result
        assert "CREATE OR REPLACE PACKAGE BODY article_model AS" in result
        # Oracle の区切り文字 "/" で終わるか
        assert result.strip().endswith("/")

    def test_no_syntax_placeholder_left(self):
        """トランスパイル後に未解決プレースホルダーが残っていないか"""
        source = """
model Post
  table :posts
  permit :title, :body
  validates :title, presence: true
  has_many :comments, foreign_key: :post_id
end
"""
        result = transpile(source, "post.model.hk")
        # 未解決テンプレート変数のチェック
        assert "{{" not in result
        assert "}}" not in result
        assert "TODO" not in result
        assert "FIXME" not in result

    def test_controller_procedures_declared(self):
        source = """
controller Articles
  def index
    render "articles/index"
  end
  def show
    @article = Article.find(params[:id])
    render "articles/show"
  end
  def new_action
    render "articles/new"
  end
end
"""
        result = transpile(source, "articles.controller.hk")
        # SPEC に PROCEDURE 宣言があるか
        spec_part = result.split("CREATE OR REPLACE PACKAGE BODY")[0]
        assert "PROCEDURE index;" in spec_part
        assert "PROCEDURE show;" in spec_part
