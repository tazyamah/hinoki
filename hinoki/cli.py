#!/usr/bin/env python3
"""
🌲 Hinoki CLI - Full-Stack Web Framework for OCI Autonomous Database
"""

import click
import os
import sys
import yaml
import datetime
import re
import textwrap
from pathlib import Path

from hinoki.transpiler import transpile, transpile_file, is_hk_file

HINOKI_DIR = Path(__file__).parent
CORE_DIR = HINOKI_DIR / "core"


# ============================================================
# Helpers
# ============================================================

def get_project_root():
    path = Path.cwd()
    while path != path.parent:
        if (path / "hinoki.yml").exists():
            return path
        path = path.parent
    return Path.cwd()


def load_config():
    root = get_project_root()
    cfg = root / "hinoki.yml"
    if cfg.exists():
        with open(cfg) as f:
            return yaml.safe_load(f)
    return {}


def get_db_config():
    root = get_project_root()
    db_file = root / "config" / "database.yml"
    if db_file.exists():
        with open(db_file) as f:
            return yaml.safe_load(f)
    return {}


def get_connection():
    try:
        import oracledb
    except ImportError:
        click.echo("Error: oracledb not installed. Run: pip install oracledb")
        sys.exit(1)
    db = get_db_config()
    env = db.get("environment", "development")
    cfg = db.get(env, db)
    kw = {}
    if "wallet_location" in cfg:
        kw["config_dir"] = cfg["wallet_location"]
        kw["wallet_location"] = cfg["wallet_location"]
        kw["wallet_password"] = cfg.get("wallet_password", "")
    try:
        return oracledb.connect(
            user=cfg.get("username", "ADMIN"),
            password=cfg.get("password", ""),
            dsn=cfg.get("dsn", cfg.get("service_name", "")), **kw)
    except Exception as e:
        click.echo(f"DB connection error: {e}")
        sys.exit(1)


def execute_sql_file(cursor, filepath):
    """Execute a .sql or .hk file against the database."""
    if is_hk_file(filepath):
        sql = transpile_file(filepath)
    else:
        sql = filepath.read_text()

    blocks = [b.strip() for b in sql.split("\n/\n") if b.strip()]
    if not blocks:
        blocks = [sql.strip()]
    for block in blocks:
        lines = [l for l in block.split("\n")
                 if l.strip() and not l.strip().startswith("--")
                 and not l.strip().startswith("PROMPT")]
        clean = "\n".join(lines).strip()
        if clean.endswith("/"):
            clean = clean[:-1].strip()
        if not clean:
            continue
        try:
            cursor.execute(clean)
        except Exception as e:
            click.echo(f"    Warning: {e}")


def pluralize(name):
    if name.endswith("y") and name[-2] not in "aeiou":
        return name[:-1] + "ies"
    if name.endswith("s"):
        return name + "es"
    return name + "s"


def parse_column(spec):
    parts = spec.split(":")
    name = parts[0]
    type_map = {
        "string": "VARCHAR2(200)", "text": "CLOB", "clob": "CLOB",
        "integer": "NUMBER(10)", "number": "NUMBER", "float": "NUMBER(15,5)",
        "boolean": "NUMBER(1) DEFAULT 0", "date": "DATE",
        "datetime": "TIMESTAMP", "timestamp": "TIMESTAMP",
    }
    if len(parts) < 2:
        return name, "VARCHAR2(200)"
    t = parts[1].lower()
    if "_" in t and t.split("_")[0] in ("varchar2", "number", "char"):
        base, size = t.rsplit("_", 1)
        return name, f"{base.upper()}({size})"
    return name, type_map.get(t, t.upper())


# ============================================================
# CLI
# ============================================================

@click.group()
def cli():
    """🌲 Hinoki - Full-Stack Web Framework for OCI Autonomous Database"""
    pass


# ---------- new ----------

@cli.command()
@click.argument("app_name")
def new(app_name):
    """Create a new Hinoki application"""
    root = Path(app_name)
    if root.exists():
        click.echo(f"Error: '{app_name}' already exists.")
        sys.exit(1)
    click.echo(f"🌲 Creating new Hinoki app: {app_name}")
    for d in ["config", "app/controllers", "app/models",
              "app/views/layouts", "app/views/shared",
              "db/migrate", "db/seeds", "public/css", "public/js", "test"]:
        (root / d).mkdir(parents=True, exist_ok=True)

    # hinoki.yml
    with open(root / "hinoki.yml", "w") as f:
        yaml.dump({"app": {"name": app_name, "version": "0.1.0"},
                    "ords": {"base_path": f"/{app_name}/", "module_name": app_name}},
                   f, default_flow_style=False)

    # database.yml
    (root / "config" / "database.yml").write_text(textwrap.dedent(f"""\
        environment: development
        development:
          username: ADMIN
          password: YOUR_PASSWORD_HERE
          dsn: your_adb_high
          wallet_location: /path/to/wallet
        production:
          username: APP_USER
          password: YOUR_PASSWORD_HERE
          dsn: your_adb_high
          wallet_location: /path/to/wallet
    """))

    # routes.hk (DSL format)
    (root / "config" / "routes.hk").write_text(textwrap.dedent(f"""\
        # 🌲 Hinoki Routes
        routes "{app_name}" do
          # root "home#index"
          # resources :posts
          # get "/about" => "pages#about"
        end
    """))

    # Default layout
    (root / "app" / "views" / "layouts" / "application.html").write_text(
        _default_layout(app_name))

    click.echo(f"""
🌲 App '{app_name}' created!

  cd {app_name}
  # Edit config/database.yml
  hinoki install
  hinoki generate scaffold post title:string body:text
  hinoki migrate
  hinoki deploy
""")


# ---------- compile ----------

@cli.command()
@click.argument("filepath")
@click.option("-o", "--output", default=None, help="Output file path")
def compile(filepath, output):
    """Compile a .hk file to PL/SQL (without executing)"""
    path = Path(filepath)
    if not path.exists():
        click.echo(f"Error: {filepath} not found")
        sys.exit(1)
    if not is_hk_file(path):
        click.echo(f"Error: {filepath} is not a .hk file")
        sys.exit(1)

    try:
        sql = transpile_file(path)
    except Exception as e:
        click.echo(f"Transpile error: {e}")
        sys.exit(1)

    if output:
        Path(output).write_text(sql)
        click.echo(f"✓ Compiled to {output}")
    else:
        click.echo(sql)


# ---------- install ----------

@cli.command()
def install():
    """Install Hinoki framework into the database"""
    click.echo("🌲 Installing Hinoki framework...")
    conn = get_connection()
    cursor = conn.cursor()
    for sql_file in sorted(CORE_DIR.glob("*.sql")):
        if sql_file.name == "install.sql":
            continue
        click.echo(f"  {sql_file.name}")
        execute_sql_file(cursor, sql_file)
    conn.commit()

    # Register layout template
    root = get_project_root()
    layout = root / "app" / "views" / "layouts" / "application.html"
    if layout.exists():
        try:
            cursor.execute("""
                MERGE INTO hinoki_views v USING (SELECT 'layouts/application' AS name FROM dual) s
                ON (v.name = s.name)
                WHEN MATCHED THEN UPDATE SET content = :c, updated_at = SYSTIMESTAMP
                WHEN NOT MATCHED THEN INSERT (name, content) VALUES (s.name, :c)
            """, {"c": layout.read_text()})
            conn.commit()
        except Exception:
            pass
    cursor.close()
    conn.close()
    click.echo("🌲 Installed!")


# ---------- generate ----------

@cli.group()
def generate():
    """Generate scaffold, model, controller, or migration"""
    pass

cli.add_command(generate)


@generate.command("scaffold")
@click.argument("name")
@click.argument("columns", nargs=-1)
@click.option("--sql", is_flag=True, help="Generate .sql instead of .hk")
def gen_scaffold(name, columns, sql):
    """Generate full CRUD scaffold"""
    root = get_project_root()
    table = pluralize(name.lower())
    parsed = [parse_column(c) for c in columns]
    col_names = [c[0] for c in parsed]
    ts = datetime.datetime.now().strftime("%Y%m%d%H%M%S")

    click.echo(f"🌲 Generating scaffold: {name}")

    ext = "sql" if sql else "hk"

    # Migration
    if sql:
        col_defs = ", ".join(f"{c[0]} {c[1]}" for c in parsed)
        mig = f"BEGIN\n    hinoki_migrate.create_table('{table}', '{col_defs}');\nEND;"
    else:
        type_map_rev = {"VARCHAR2(200)": "string", "CLOB": "text", "NUMBER(10)": "integer",
                        "NUMBER": "number", "NUMBER(1) DEFAULT 0": "boolean",
                        "DATE": "date", "TIMESTAMP": "datetime"}
        mig_cols = []
        for cname, ctype in parsed:
            dsl_type = type_map_rev.get(ctype, "string")
            mig_cols.append(f"    {dsl_type} :{cname}")
        mig = f'migration "create_{table}" do\n  create_table :{table} do\n'
        mig += "\n".join(mig_cols) + f"\n  end\nend"

    mig_file = root / "db" / "migrate" / f"{ts}_create_{table}.{ext}"
    mig_file.write_text(mig)
    click.echo(f"  Created: {mig_file.relative_to(root)}")

    # Model
    if sql:
        model_content = _gen_model_sql(name.lower(), table, col_names)
    else:
        model_content = _gen_model_hk(name, col_names)
    model_file = root / "app" / "models" / f"{name.lower()}.model.{ext}"
    model_file.write_text(model_content)
    click.echo(f"  Created: {model_file.relative_to(root)}")

    # Controller
    if sql:
        ctrl_content = _gen_controller_sql(table, name.lower(), col_names)
    else:
        ctrl_content = _gen_controller_hk(name, col_names)
    ctrl_file = root / "app" / "controllers" / f"{table}.controller.{ext}"
    ctrl_file.write_text(ctrl_content)
    click.echo(f"  Created: {ctrl_file.relative_to(root)}")

    # Views
    views_dir = root / "app" / "views" / table
    views_dir.mkdir(parents=True, exist_ok=True)
    for vname, vcontent in _gen_views(table, name.lower(), col_names).items():
        (views_dir / f"{vname}.html").write_text(vcontent)
        click.echo(f"  Created: app/views/{table}/{vname}.html")

    click.echo(f"\n  Add to config/routes.hk:\n    resources :{table}\n")


@generate.command("migration")
@click.argument("name")
def gen_migration(name):
    """Generate an empty migration"""
    root = get_project_root()
    ts = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    f = root / "db" / "migrate" / f"{ts}_{name}.hk"
    f.write_text(f'migration "{name}" do\n  # TODO\nend\n')
    click.echo(f"  Created: {f.relative_to(root)}")


# ---------- migrate ----------

@cli.command()
def migrate():
    """Run pending migrations"""
    root = get_project_root()
    mdir = root / "db" / "migrate"
    if not mdir.exists():
        click.echo("No migrations directory."); return
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT version FROM hinoki_migrations ORDER BY version")
        executed = {r[0] for r in cur.fetchall()}
    except:
        executed = set()

    pending = sorted([f for f in mdir.iterdir()
                      if f.suffix in (".sql", ".hk") and "_down" not in f.name])
    count = 0
    for mf in pending:
        version = mf.stem.split("_")[0]
        if version in executed:
            continue
        mig_name = "_".join(mf.stem.split("_")[1:])
        click.echo(f"  Migrating: {mf.name}")

        if is_hk_file(mf):
            up_sql = transpile_file(mf)
        else:
            up_sql = mf.read_text()

        # Check for down file
        down_path = mf.with_name(mf.stem + "_down" + mf.suffix)
        down_sql = (transpile_file(down_path) if is_hk_file(down_path) else down_path.read_text()) \
            if down_path.exists() else None

        try:
            cur.execute("BEGIN hinoki_migrate.run_migration(:v, :n, :u, :d); END;",
                        {"v": version, "n": mig_name, "u": up_sql, "d": down_sql})
            conn.commit()
            click.echo(f"    ✓ {mig_name}")
            count += 1
        except Exception as e:
            click.echo(f"    ✗ {e}")
            conn.rollback()
    if count == 0:
        click.echo("🌲 No pending migrations.")
    else:
        click.echo(f"🌲 {count} migration(s) complete.")
    cur.close(); conn.close()


@cli.command("migrate:rollback")
def migrate_rollback():
    """Rollback the last migration"""
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.callproc("hinoki_migrate.rollback_last")
        conn.commit()
        click.echo("🌲 Rollback complete.")
    except Exception as e:
        click.echo(f"Error: {e}")
    cur.close(); conn.close()


# ---------- routes ----------

@cli.command()
def routes():
    """Display all registered routes"""
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("""SELECT http_method, path, controller, action
                       FROM hinoki_routes
                       ORDER BY path, DECODE(http_method,'GET',1,'POST',2,'PUT',3,'DELETE',4,5)""")
        click.echo(f"\n🌲 Hinoki Routes\n{'='*80}")
        click.echo(f"{'Method':<10}{'Path':<30}{'Controller':<25}{'Action'}")
        click.echo(f"{'-'*80}")
        for r in cur:
            click.echo(f"{r[0]:<10}{r[1]:<30}{r[2]:<25}{r[3]}")
        click.echo(f"{'='*80}")
    except Exception as e:
        click.echo(f"Error: {e}")
    cur.close(); conn.close()


# ---------- deploy ----------

@cli.command()
def deploy():
    """Deploy all code to the database (.hk files auto-compiled)"""
    root = get_project_root()
    conn = get_connection()
    cur = conn.cursor()
    click.echo("🌲 Deploying to ADB...")

    # Models & Controllers (.hk and .sql)
    for subdir in ["app/models", "app/controllers"]:
        d = root / subdir
        if not d.exists():
            continue
        for f in sorted(d.iterdir()):
            if f.suffix in (".hk", ".sql"):
                tag = "🔄" if f.suffix == ".hk" else "📄"
                click.echo(f"  {tag} {f.relative_to(root)}")
                execute_sql_file(cur, f)

    # Views → hinoki_views table
    views_dir = root / "app" / "views"
    if views_dir.exists():
        for html in sorted(views_dir.rglob("*.html")):
            rel = html.relative_to(views_dir)
            vname = str(rel).replace(".html", "").replace("\\", "/")
            cur.execute("""
                MERGE INTO hinoki_views v USING (SELECT :n AS name FROM dual) s
                ON (v.name = s.name)
                WHEN MATCHED THEN UPDATE SET content = :c, updated_at = SYSTIMESTAMP
                WHEN NOT MATCHED THEN INSERT (name, content) VALUES (:n, :c)
            """, {"n": vname, "c": html.read_text()})
            click.echo(f"  🖼  {vname}")

    conn.commit()

    # Routes (.hk or .sql)
    for routes_file in [root / "config" / "routes.hk", root / "config" / "routes.sql"]:
        if routes_file.exists():
            click.echo(f"  🛤  routes")
            execute_sql_file(cur, routes_file)
            conn.commit()
            break

    cur.close(); conn.close()
    click.echo("🌲 Deploy complete!")


# ---------- console ----------

@cli.command()
def console():
    """Open interactive PL/SQL console"""
    conn = get_connection()
    cur = conn.cursor()
    click.echo("🌲 Hinoki Console (type 'exit' to quit)\n")
    while True:
        try:
            sql = input("hinoki> ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if sql.lower() in ("exit", "quit", "\\q"):
            break
        if not sql:
            continue
        if sql.endswith(";"):
            sql = sql[:-1]
        try:
            if sql.upper().startswith(("SELECT", "WITH")):
                cur.execute(sql)
                cols = [d[0] for d in cur.description]
                click.echo("  " + " | ".join(cols))
                for row in cur:
                    click.echo("  " + " | ".join(str(v) for v in row))
            else:
                cur.execute(sql)
                conn.commit()
                click.echo(f"  OK ({cur.rowcount} rows)")
        except Exception as e:
            click.echo(f"  Error: {e}")
    cur.close(); conn.close()
    click.echo("Bye! 🌲")


# ============================================================
# Generator templates
# ============================================================

def _gen_model_hk(name, col_names):
    cols = ", ".join(f":{c}" for c in col_names)
    validates = "\n".join(f"  validates :{c}, presence: true" for c in col_names[:1])
    return f"""\
model {name.capitalize()}
  table :{pluralize(name.lower())}

  permit {cols}

{validates}
end
"""

def _gen_controller_hk(name, col_names):
    model = name.capitalize()
    table = pluralize(name.lower())
    cols = ", ".join(f":{c}" for c in col_names)
    return f"""\
controller {model.capitalize()}s
  # before_action :require_login, except: [:index, :show]

  def index
    @posts = {model}.all.paginate(params[:page])
    @pagination = {model}.pagination_info(params[:page])
    render "{table}/index"
  end

  def show
    @{name.lower()} = {model}.find(params[:id])
    render "{table}/show"
  end

  def new_form
    @page_title = "新規作成"
    render "{table}/new"
  end

  def create_action
    @{name.lower()} = {model}.new(permit({cols}))
    if @{name.lower()}.save
      redirect_to "/{table}/#{{@{name.lower()}.id}}", flash: "作成しました！"
    else
      render "{table}/new"
    end
  end

  def edit_form
    @{name.lower()} = {model}.find(params[:id])
    render "{table}/edit"
  end

  def update_action
    @{name.lower()} = {model}.find(params[:id])
    @{name.lower()}.update(permit({cols}))
    redirect_to "/{table}/#{{@{name.lower()}.id}}", flash: "更新しました"
  end

  def delete_action
    {model}.delete(params[:id])
    redirect_to "/{table}", flash: "削除しました"
  end
end
"""

def _gen_model_sql(model_name, table_name, col_names):
    cols = ",".join(col_names)
    return f"""\
CREATE OR REPLACE PACKAGE {model_name}_model AS
    c_table CONSTANT VARCHAR2(200) := '{table_name}';
    c_permitted CONSTANT VARCHAR2(1000) := '{cols}';
    FUNCTION all_records(p_page IN NUMBER DEFAULT 1, p_per_page IN NUMBER DEFAULT 25) RETURN SYS_REFCURSOR;
    FUNCTION find(p_id IN NUMBER) RETURN SYS_REFCURSOR;
    FUNCTION create_record(p_params IN hinoki_model.t_record) RETURN NUMBER;
    PROCEDURE update_record(p_id IN NUMBER, p_params IN hinoki_model.t_record);
    PROCEDURE delete_record(p_id IN NUMBER);
    FUNCTION validate(p_params IN hinoki_model.t_record) RETURN BOOLEAN;
END {model_name}_model;
/

CREATE OR REPLACE PACKAGE BODY {model_name}_model AS
    FUNCTION all_records(p_page IN NUMBER DEFAULT 1, p_per_page IN NUMBER DEFAULT 25) RETURN SYS_REFCURSOR IS
    BEGIN RETURN hinoki_model.paginate(c_table, p_page, p_per_page); END;
    FUNCTION find(p_id IN NUMBER) RETURN SYS_REFCURSOR IS
    BEGIN RETURN hinoki_model.find_by_id(c_table, p_id); END;
    FUNCTION create_record(p_params IN hinoki_model.t_record) RETURN NUMBER IS
    BEGIN IF NOT validate(p_params) THEN RETURN NULL; END IF;
          RETURN hinoki_model.create_from_record(c_table, p_params, c_permitted); END;
    PROCEDURE update_record(p_id IN NUMBER, p_params IN hinoki_model.t_record) IS
    BEGIN IF validate(p_params) THEN hinoki_model.update_from_record(c_table, p_id, p_params, c_permitted); END IF; END;
    PROCEDURE delete_record(p_id IN NUMBER) IS
    BEGIN hinoki_model.delete_record(c_table, p_id); END;
    FUNCTION validate(p_params IN hinoki_model.t_record) RETURN BOOLEAN IS
    BEGIN hinoki_model.clear_validations; RETURN hinoki_model.validate(p_params); END;
END {model_name}_model;
/
"""

def _gen_controller_sql(table, model, col_names):
    cols = ",".join(col_names)
    ctrl = table + "_controller"
    return f"""\
CREATE OR REPLACE PACKAGE {ctrl} AS
    PROCEDURE index_action; PROCEDURE show; PROCEDURE new_form;
    PROCEDURE create_action; PROCEDURE edit_form; PROCEDURE update_action; PROCEDURE delete_action;
END {ctrl};
/
CREATE OR REPLACE PACKAGE BODY {ctrl} AS
    PROCEDURE index_action IS v_cur SYS_REFCURSOR; v_page NUMBER := NVL(hinoki_core.param_int('page'),1);
    BEGIN v_cur := {model}_model.all_records(v_page);
        hinoki_view.assign('page_title','{table}'); hinoki_view.assign_raw('table_content',
        hinoki_controller.table_for(v_cur,'id,{cols}',NULL,'{table}'));
        hinoki_view.render_to('{table}/index'); END;
    PROCEDURE show IS v_id NUMBER := hinoki_core.param_int('id'); BEGIN
        hinoki_view.render_to('{table}/show'); END;
    PROCEDURE new_form IS BEGIN hinoki_view.assign_raw('form_content',
        hinoki_controller.form_for('/{table}','POST',hinoki_model.t_record(),'{cols}'));
        hinoki_view.render_to('{table}/new'); END;
    PROCEDURE create_action IS v_p hinoki_model.t_record; v_id NUMBER; BEGIN
        v_p := hinoki_controller.permit('{cols}'); v_id := {model}_model.create_record(v_p);
        IF v_id IS NOT NULL THEN hinoki_controller.redirect_to('/{table}/'||v_id,'作成しました','success');
        ELSE hinoki_view.render_to('{table}/new'); END IF; END;
    PROCEDURE edit_form IS BEGIN hinoki_view.render_to('{table}/edit'); END;
    PROCEDURE update_action IS v_id NUMBER := hinoki_core.param_int('id');
        v_p hinoki_model.t_record; BEGIN v_p := hinoki_controller.permit('{cols}');
        {model}_model.update_record(v_id, v_p);
        hinoki_controller.redirect_to('/{table}/'||v_id,'更新しました','success'); END;
    PROCEDURE delete_action IS v_id NUMBER := hinoki_core.param_int('id'); BEGIN
        {model}_model.delete_record(v_id);
        hinoki_controller.redirect_to('/{table}','削除しました','notice'); END;
END {ctrl};
/
"""

def _gen_views(table, model, col_names):
    views = {}
    views["index"] = f"<h2>{table}一覧</h2>\n{{{{{{ nav }}}}}}\n{{{{{{ table_content }}}}}}\n{{{{{{ pagination }}}}}}"
    rows = "\n".join(f"    <tr><th>{c}</th><td>{{{{ {c} }}}}</td></tr>" for c in col_names)
    views["show"] = f"<h2>{table}詳細</h2>\n<div class=\"hinoki-card\"><table class=\"hinoki-table\">\n    <tr><th>ID</th><td>{{{{ id }}}}</td></tr>\n{rows}\n</table></div>"
    views["new"] = f"<h2>{table}新規作成</h2>\n<div class=\"hinoki-card\">{{{{{{ form_content }}}}}}</div>"
    views["edit"] = f"<h2>{table}編集</h2>\n<div class=\"hinoki-card\">{{{{{{ form_content }}}}}}</div>"
    return views


def _default_layout(app_name):
    return textwrap.dedent(f"""\
    <!DOCTYPE html>
    <html lang="ja">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>{{{{ page_title }}}} - {app_name}</title>
        <style>
        :root {{ --hk:#2d5016; --hk-l:#f0f7eb; --hk-d:#1a3009; --hk-a:#5a8f29; --hk-b:#d4e5c7; }}
        *{{box-sizing:border-box;margin:0;padding:0}}
        body{{font-family:-apple-system,BlinkMacSystemFont,"Hiragino Sans","Noto Sans JP",sans-serif;
             background:#fafdf7;color:#333;line-height:1.7}}
        .hinoki-header{{background:var(--hk);color:#fff;padding:12px 24px;display:flex;
                       align-items:center;justify-content:space-between;box-shadow:0 2px 8px rgba(0,0,0,.15)}}
        .hinoki-header h1{{font-size:1.2em}} .hinoki-header h1 a{{color:#fff;text-decoration:none}}
        .hinoki-header nav a{{color:rgba(255,255,255,.85);text-decoration:none;margin-left:20px;font-size:.9em}}
        .hinoki-container{{max-width:960px;margin:24px auto;padding:0 20px}}
        .hinoki-table{{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;
                      box-shadow:0 1px 4px rgba(0,0,0,.08)}}
        .hinoki-table th{{background:var(--hk-l);color:var(--hk);padding:12px 16px;text-align:left;font-weight:600;
                         font-size:.85em;text-transform:uppercase;letter-spacing:.05em}}
        .hinoki-table td{{padding:12px 16px;border-top:1px solid #eee}}
        .hinoki-field{{margin-bottom:16px}} .hinoki-field label{{display:block;font-weight:600;color:var(--hk-d);margin-bottom:6px;font-size:.9em}}
        .hinoki-input{{width:100%;padding:10px 14px;border:2px solid var(--hk-b);border-radius:6px;font-size:1em;font-family:inherit}}
        .hinoki-input:focus{{outline:none;border-color:var(--hk-a);box-shadow:0 0 0 3px rgba(90,143,41,.15)}}
        .hinoki-btn{{background:var(--hk);color:#fff;border:none;padding:10px 24px;border-radius:6px;font-size:1em;cursor:pointer;font-weight:600}}
        .hinoki-btn:hover{{background:var(--hk-d)}}
        .hinoki-card{{background:#fff;padding:24px;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.08);margin-bottom:20px}}
        .hinoki-flash{{border-radius:6px;padding:12px 20px;margin-bottom:16px;border:1px solid}}
        .hinoki-actions{{margin-top:16px}} .hinoki-actions a{{margin-right:12px;color:var(--hk-a)}}
        .hinoki-danger{{color:#c0392b!important}}
        .hinoki-nav{{margin-bottom:20px;padding:12px 0;border-bottom:1px solid var(--hk-b)}}
        .hinoki-nav a{{color:var(--hk-a);text-decoration:none;margin-right:16px}}
        .hinoki-errors{{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb;padding:12px 20px;border-radius:6px;margin-bottom:16px}}
        .hinoki-pagination{{display:flex;gap:4px;margin:20px 0}}
        .hinoki-pagination a,.hinoki-pagination span{{padding:8px 14px;border-radius:4px;text-decoration:none}}
        .hinoki-pagination a{{background:#fff;color:var(--hk-a);border:1px solid var(--hk-b)}}
        .hinoki-pagination .current{{background:var(--hk);color:#fff}}
        .hinoki-footer{{text-align:center;padding:24px;color:#999;font-size:.85em}}
        </style>
    </head>
    <body>
        <header class="hinoki-header">
            <h1><a href="/">🌲 {app_name}</a></h1>
            <nav>{{{{{{ nav_links }}}}}}</nav>
        </header>
        <main class="hinoki-container">
            {{{{{{ flash }}}}}}
            {{% yield %}}
        </main>
        <footer class="hinoki-footer">Powered by Hinoki 🌲 on OCI Autonomous Database</footer>
    </body>
    </html>
    """)


# ============================================================
# Entry point
# ============================================================

def main():
    cli()

if __name__ == "__main__":
    main()
