"""
Tests for the Hinoki transpiler.

Run with: python -m pytest tests/ -v
"""

import sys
from pathlib import Path

# Add parent to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from hinoki.transpiler import transpile, detect_type
from hinoki.transpiler.parser_utils import (
    parse_symbol, parse_symbol_list, parse_hash_opts
)


# ============================================================
# Parser Utils Tests
# ============================================================

class TestParserUtils:

    def test_parse_symbol(self):
        assert parse_symbol(":name") == "name"
        assert parse_symbol(":title,") == "title"
        assert parse_symbol("'hello'") == "hello"

    def test_parse_symbol_list(self):
        assert parse_symbol_list(":a, :b, :c") == ["a", "b", "c"]
        assert parse_symbol_list(":title, :body") == ["title", "body"]

    def test_parse_hash_opts_simple(self):
        result = parse_hash_opts("presence: true, length: 500")
        assert result["presence"] is True
        assert result["length"] == 500

    def test_parse_hash_opts_nested(self):
        result = parse_hash_opts("length: { max: 500, min: 1 }")
        assert result["length"]["max"] == 500
        assert result["length"]["min"] == 1

    def test_parse_hash_opts_symbol(self):
        result = parse_hash_opts("foreign_key: :post_id")
        assert result["foreign_key"] == "post_id"

    def test_parse_hash_opts_array(self):
        result = parse_hash_opts("only: [:index, :show]")
        assert result["only"] == ["index", "show"]


# ============================================================
# Detect Type Tests
# ============================================================

class TestDetectType:

    def test_model(self):
        assert detect_type("model Post\n  table :posts\nend") == "model"

    def test_controller(self):
        assert detect_type("controller Posts\n  def index\n  end\nend") == "controller"

    def test_migration(self):
        assert detect_type('migration "create_posts" do\nend') == "migration"

    def test_routes(self):
        assert detect_type("routes do\nend") == "routes"

    def test_with_comments(self):
        assert detect_type("# comment\nmodel Post\nend") == "model"


# ============================================================
# Model Transpiler Tests
# ============================================================

class TestModelTranspiler:

    def test_basic_model(self):
        source = """
model Post
  table :posts
  permit :title, :body

  validates :title, presence: true
end
"""
        result = transpile(source, "post.model.hk")
        assert "CREATE OR REPLACE PACKAGE post_model AS" in result
        assert "CREATE OR REPLACE PACKAGE BODY post_model AS" in result
        assert "c_table" in result
        assert "c_permitted" in result
        assert "'title,body'" in result or "'title, body'" in result

    def test_model_with_scope(self):
        source = """
model Article
  table :articles
  permit :title
  scope :published, -> { where "published = 1" }
end
"""
        result = transpile(source, "article.model.hk")
        assert "FUNCTION published" in result
        assert "published = 1" in result

    def test_model_with_association(self):
        source = """
model Post
  table :posts
  permit :title
  has_many :comments, foreign_key: :post_id
end
"""
        result = transpile(source, "post.model.hk")
        assert "FUNCTION comments" in result
        assert "post_id" in result

    def test_model_with_validation(self):
        source = """
model Post
  table :posts
  permit :title
  validates :title, presence: true, length: { max: 500 }
end
"""
        result = transpile(source, "post.model.hk")
        assert "validates_presence" in result
        assert "validates_length" in result
        assert "500" in result

    def test_model_with_callbacks(self):
        source = """
model Post
  table :posts
  permit :title
  before_save :set_defaults
  def set_defaults
    self.view_count = 0
  end
end
"""
        result = transpile(source, "post.model.hk")
        assert "set_defaults" in result

    def test_model_auto_table_name(self):
        source = """
model Comment
  permit :body
end
"""
        result = transpile(source, "comment.model.hk")
        assert "comment_model" in result
        assert "'comments'" in result


# ============================================================
# Controller Transpiler Tests
# ============================================================

class TestControllerTranspiler:

    def test_basic_controller(self):
        source = """
controller Posts
  def index
    render "posts/index"
  end

  def show
    @post = Post.find(params[:id])
    render "posts/show"
  end
end
"""
        result = transpile(source, "posts.controller.hk")
        assert "CREATE OR REPLACE PACKAGE posts_controller AS" in result
        assert "PROCEDURE index;" in result
        assert "PROCEDURE show;" in result
        assert "hinoki_view.render_to('posts/index'" in result

    def test_controller_with_before_action(self):
        source = """
controller Posts
  before_action :require_login, except: [:index, :show]

  def index
    render "posts/index"
  end

  def create_action
    render "posts/new"
  end
end
"""
        result = transpile(source, "posts.controller.hk")
        assert "require_login" in result

    def test_controller_redirect(self):
        source = """
controller Posts
  def delete_action
    Post.delete(params[:id])
    redirect_to "/posts", flash: "削除しました"
  end
end
"""
        result = transpile(source, "posts.controller.hk")
        assert "hinoki_controller.redirect_to" in result
        assert "削除しました" in result

    def test_controller_save_pattern(self):
        source = """
controller Posts
  def create_action
    @post = Post.new(permit(:title, :body))
    if @post.save
      redirect_to "/posts", flash: "作成しました"
    else
      render "posts/new"
    end
  end
end
"""
        result = transpile(source, "posts.controller.hk")
        assert "hinoki_controller.permit" in result
        assert "create_record" in result
        assert "IF v_new_id IS NOT NULL THEN" in result

    def test_controller_collection_assignment(self):
        """@posts = Model.scope.paginate → assign_collection"""
        source = """
controller Articles
  def index
    @posts = Article.published.paginate(params[:page])
    render "articles/index"
  end
end
"""
        result = transpile(source, "articles.controller.hk")
        assert "assign_collection" in result
        assert "'posts'" in result
        assert "article_model.published" in result

    def test_controller_collection_all(self):
        """@items = Model.all.paginate → assign_collection"""
        source = """
controller Items
  def index
    @items = Item.all.paginate(params[:page])
    render "items/index"
  end
end
"""
        result = transpile(source, "items.controller.hk")
        assert "assign_collection" in result
        assert "all_records" in result


# ============================================================
# Migration Transpiler Tests
# ============================================================

class TestMigrationTranspiler:

    def test_create_table(self):
        source = """
migration "create_posts" do
  create_table :posts do
    string  :title, null: false, limit: 500
    text    :body
    boolean :published, default: false
    integer :view_count, default: 0
  end
end
"""
        result = transpile(source, "migration.hk")
        assert "hinoki_migrate.create_table" in result
        assert "VARCHAR2(500)" in result
        assert "CLOB" in result
        assert "NUMBER(1)" in result
        assert "NOT NULL" in result

    def test_create_table_with_index(self):
        source = """
migration "create_posts" do
  create_table :posts do
    string :title
    index  :title, unique: true
  end
end
"""
        result = transpile(source, "migration.hk")
        assert "hinoki_migrate.add_index" in result
        assert "TRUE" in result  # unique

    def test_add_column(self):
        source = """
migration "add_slug" do
  add_column :posts, :slug, :string
end
"""
        result = transpile(source, "migration.hk")
        assert "hinoki_migrate.add_column" in result
        assert "'slug'" in result

    def test_drop_table(self):
        source = """
migration "drop_old" do
  drop_table :legacy_posts
end
"""
        result = transpile(source, "migration.hk")
        assert "hinoki_migrate.drop_table" in result
        assert "legacy_posts" in result


# ============================================================
# Routes Transpiler Tests
# ============================================================

class TestRoutesTranspiler:

    def test_basic_routes(self):
        source = """
routes "myapp" do
  root "home#index"
  resources :posts
end
"""
        result = transpile(source, "routes.hk")
        assert "hinoki_router.root" in result
        assert "hinoki_router.get('/posts'" in result
        assert "hinoki_router.post('/posts'" in result
        assert "index_action" in result
        assert "create_action" in result
        assert "deploy_routes('myapp')" in result

    def test_routes_with_only(self):
        source = """
routes do
  resources :comments, only: [:index, :create]
end
"""
        result = transpile(source, "routes.hk")
        assert "index_action" in result
        assert "create_action" in result
        # show, edit, etc. should NOT be present
        assert "show" not in result.split("index_action")[1].split("create_action")[0]

    def test_custom_routes(self):
        source = """
routes do
  get  "/about"   => "pages#about"
  post "/contact" => "pages#contact"
end
"""
        result = transpile(source, "routes.hk")
        assert "hinoki_router.get('/about'" in result
        assert "pages_controller" in result
        assert "'about'" in result

    def test_namespace(self):
        source = """
routes do
  namespace :api do
    resources :posts, only: [:index, :show]
  end
end
"""
        result = transpile(source, "routes.hk")
        assert "/api/posts" in result
        assert "api_posts_controller" in result


# ============================================================
# Integration: End-to-end transpile
# ============================================================

class TestEndToEnd:

    def test_model_generates_valid_structure(self):
        source = """
model User
  table :users
  permit :name, :email, :role
  validates :name, presence: true
  validates :email, presence: true, uniqueness: true
  scope :admins, -> { where "role = 'admin'" }
  has_many :posts, foreign_key: :user_id
end
"""
        result = transpile(source, "user.model.hk")

        # Should have both spec and body
        assert result.count("CREATE OR REPLACE PACKAGE") == 2
        # Should end with /
        assert "/\n" in result
        # Should have all standard methods
        for method in ["all_records", "find", "create_record",
                       "update_record", "delete_record", "validate",
                       "admins", "posts", "all_as_json", "find_as_json"]:
            assert method in result, f"Missing method: {method}"

    def test_full_blog_example(self):
        """Test that the example blog files transpile without errors."""
        examples_dir = Path(__file__).parent.parent / "examples" / "blog"
        if not examples_dir.exists():
            return

        for hk_file in examples_dir.rglob("*.hk"):
            result = transpile(hk_file.read_text(), str(hk_file))
            assert result  # Should produce output
            assert "ERROR" not in result.upper() or "SQLERRM" in result


# ============================================================
# Run tests
# ============================================================

if __name__ == "__main__":
    import pytest
    pytest.main([__file__, "-v"])
