"""
pytest 共有フィクスチャ

--run-e2e オプションが指定された場合のみ @pytest.mark.e2e テストを実行。
ADB接続情報は環境変数 or config/database.yml から取得。
"""

import pytest
import os
import yaml
from pathlib import Path


def pytest_addoption(parser):
    parser.addoption(
        "--run-e2e",
        action="store_true",
        default=False,
        help="ADB接続が必要なe2eテストも実行する",
    )


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "e2e: ADB接続が必要なフルスタックe2eテスト"
    )


def pytest_collection_modifyitems(config, items):
    if not config.getoption("--run-e2e"):
        skip_e2e = pytest.mark.skip(reason="--run-e2e を指定してください")
        for item in items:
            # ディレクトリ名ではなく、実際に @pytest.mark.e2e が付いているものだけスキップ
            if item.get_closest_marker("e2e"):
                item.add_marker(skip_e2e)


# ============================================================
# フィクスチャ: プロジェクトパス
# ============================================================

@pytest.fixture(scope="session")
def project_root():
    return Path(__file__).parent.parent


@pytest.fixture(scope="session")
def examples_blog_dir(project_root):
    return project_root / "examples" / "blog"


# ============================================================
# フィクスチャ: ADB接続（e2eテスト用）
# ============================================================

@pytest.fixture(scope="session")
def db_config(project_root):
    """database.yml または環境変数から DB 接続情報を取得"""
    # 環境変数が優先
    if os.environ.get("HINOKI_TEST_DSN"):
        return {
            "username": os.environ.get("HINOKI_TEST_USER", "ADMIN"),
            "password": os.environ["HINOKI_TEST_PASSWORD"],
            "dsn": os.environ["HINOKI_TEST_DSN"],
            "wallet_location": os.environ.get("HINOKI_TEST_WALLET", ""),
        }

    # config/database.yml の test 環境を使用
    db_file = project_root / "config" / "database.yml"
    if db_file.exists():
        with open(db_file) as f:
            cfg = yaml.safe_load(f)
        env = cfg.get("environment", "test")
        return cfg.get("test", cfg.get("development", {}))

    return {}


@pytest.fixture(scope="session")
def db_connection(db_config):
    """Oracle DB 接続を確立（e2eテスト用）"""
    try:
        import oracledb
    except ImportError:
        pytest.skip("oracledb がインストールされていません: pip install oracledb")

    if not db_config.get("dsn"):
        pytest.skip("DB接続情報がありません（環境変数 HINOKI_TEST_DSN 等を設定してください）")

    kw = {}
    if db_config.get("wallet_location"):
        kw["config_dir"] = db_config["wallet_location"]
        kw["wallet_location"] = db_config["wallet_location"]
        kw["wallet_password"] = db_config.get("wallet_password", "")

    try:
        conn = oracledb.connect(
            user=db_config["username"],
            password=db_config["password"],
            dsn=db_config["dsn"],
            **kw,
        )
        yield conn
        conn.close()
    except Exception as e:
        pytest.skip(f"DB接続に失敗しました: {e}")


@pytest.fixture(scope="session")
def ords_base_url():
    """ORDS の Base URL（環境変数から取得）"""
    url = os.environ.get("HINOKI_TEST_ORDS_URL")
    if not url:
        pytest.skip("HINOKI_TEST_ORDS_URL 環境変数が設定されていません")
    return url.rstrip("/")
