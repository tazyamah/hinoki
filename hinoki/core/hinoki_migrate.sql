-- ============================================================
-- HINOKI_MIGRATE: マイグレーションエンジン
-- スキーマバージョン管理 (Rails の db:migrate 相当)
-- ============================================================

CREATE OR REPLACE PACKAGE hinoki_migrate AS

    -- マイグレーション登録 & 実行
    PROCEDURE run_migration(
        p_version IN VARCHAR2,
        p_name    IN VARCHAR2,
        p_up_sql  IN CLOB,
        p_down_sql IN CLOB DEFAULT NULL
    );

    -- 実行済みか確認
    FUNCTION is_migrated(p_version IN VARCHAR2) RETURN BOOLEAN;

    -- ロールバック (直前のマイグレーション)
    PROCEDURE rollback_last;

    -- 全マイグレーション状態表示
    PROCEDURE status;

    -- ========== DDL ヘルパー (マイグレーション内で使用) ==========

    -- テーブル作成 (id, created_at, updated_at 自動付与)
    PROCEDURE create_table(
        p_table_name IN VARCHAR2,
        p_columns    IN VARCHAR2  -- 'title VARCHAR2(200) NOT NULL, body CLOB, published NUMBER(1) DEFAULT 0'
    );

    -- テーブル削除
    PROCEDURE drop_table(p_table_name IN VARCHAR2);

    -- カラム追加
    PROCEDURE add_column(
        p_table  IN VARCHAR2,
        p_column IN VARCHAR2,
        p_type   IN VARCHAR2,
        p_default IN VARCHAR2 DEFAULT NULL
    );

    -- カラム削除
    PROCEDURE remove_column(p_table IN VARCHAR2, p_column IN VARCHAR2);

    -- カラム変更
    PROCEDURE change_column(
        p_table  IN VARCHAR2,
        p_column IN VARCHAR2,
        p_type   IN VARCHAR2
    );

    -- インデックス作成
    PROCEDURE add_index(
        p_table   IN VARCHAR2,
        p_columns IN VARCHAR2,
        p_unique  IN BOOLEAN DEFAULT FALSE,
        p_name    IN VARCHAR2 DEFAULT NULL
    );

    -- インデックス削除
    PROCEDURE remove_index(p_name IN VARCHAR2);

    -- 外部キー追加
    PROCEDURE add_foreign_key(
        p_table      IN VARCHAR2,
        p_column     IN VARCHAR2,
        p_ref_table  IN VARCHAR2,
        p_ref_column IN VARCHAR2 DEFAULT 'id',
        p_on_delete  IN VARCHAR2 DEFAULT 'CASCADE'
    );

    -- SQL直接実行
    PROCEDURE execute_sql(p_sql IN VARCHAR2);

END hinoki_migrate;
/

CREATE OR REPLACE PACKAGE BODY hinoki_migrate AS

    PROCEDURE run_migration(p_version IN VARCHAR2, p_name IN VARCHAR2,
                            p_up_sql IN CLOB, p_down_sql IN CLOB DEFAULT NULL) IS
        v_checksum VARCHAR2(64);
    BEGIN
        IF is_migrated(p_version) THEN
            hinoki_core.log_info('Migration ' || p_version || ' already applied, skipping.');
            RETURN;
        END IF;

        hinoki_core.log_info('Running migration ' || p_version || ': ' || p_name);

        BEGIN
            EXECUTE IMMEDIATE p_up_sql;
        EXCEPTION WHEN OTHERS THEN
            hinoki_core.log_error('Migration ' || p_version || ' failed: ' || SQLERRM);
            RAISE;
        END;

        -- down SQLがあれば保存
        v_checksum := RAWTOHEX(DBMS_CRYPTO.HASH(
            UTL_I18N.STRING_TO_RAW(DBMS_LOB.SUBSTR(p_up_sql, 4000, 1), 'AL32UTF8'),
            DBMS_CRYPTO.HASH_SH256
        ));

        INSERT INTO hinoki_migrations (version, name, checksum)
        VALUES (p_version, p_name, v_checksum);

        -- down SQLをconfigに保存
        IF p_down_sql IS NOT NULL THEN
            hinoki_core.set_config('migrate.down.' || p_version,
                DBMS_LOB.SUBSTR(p_down_sql, 4000, 1));
        END IF;

        COMMIT;
        hinoki_core.log_info('Migration ' || p_version || ' completed.');
    END run_migration;

    FUNCTION is_migrated(p_version IN VARCHAR2) RETURN BOOLEAN IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count FROM hinoki_migrations WHERE version = p_version;
        RETURN v_count > 0;
    END is_migrated;

    PROCEDURE rollback_last IS
        v_version VARCHAR2(100);
        v_name    VARCHAR2(500);
        v_down    VARCHAR2(4000);
    BEGIN
        SELECT version, name INTO v_version, v_name
        FROM hinoki_migrations
        ORDER BY executed_at DESC
        FETCH FIRST 1 ROW ONLY;

        v_down := hinoki_core.config('migrate.down.' || v_version);
        IF v_down IS NOT NULL THEN
            hinoki_core.log_info('Rolling back ' || v_version || ': ' || v_name);
            EXECUTE IMMEDIATE v_down;
            DELETE FROM hinoki_migrations WHERE version = v_version;
            COMMIT;
            hinoki_core.log_info('Rollback complete.');
        ELSE
            hinoki_core.log_error('No rollback SQL found for ' || v_version);
        END IF;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        hinoki_core.log_info('No migrations to rollback.');
    END rollback_last;

    PROCEDURE status IS
    BEGIN
        DBMS_OUTPUT.put_line('');
        DBMS_OUTPUT.put_line('🌲 Hinoki Migrations');
        DBMS_OUTPUT.put_line(RPAD('=', 70, '='));
        DBMS_OUTPUT.put_line(
            RPAD('Version', 20) || RPAD('Name', 35) || 'Executed At'
        );
        DBMS_OUTPUT.put_line(RPAD('-', 70, '-'));

        FOR rec IN (
            SELECT version, name, TO_CHAR(executed_at, 'YYYY-MM-DD HH24:MI:SS') AS exec_at
            FROM hinoki_migrations ORDER BY version
        ) LOOP
            DBMS_OUTPUT.put_line(
                RPAD(rec.version, 20) || RPAD(NVL(rec.name, '-'), 35) || rec.exec_at
            );
        END LOOP;
        DBMS_OUTPUT.put_line(RPAD('=', 70, '='));
    END status;

    -- ========== DDL ヘルパー ==========

    PROCEDURE create_table(p_table_name IN VARCHAR2, p_columns IN VARCHAR2) IS
        v_tbl VARCHAR2(200) := hinoki_model.sanitize_identifier(p_table_name);
        v_sql VARCHAR2(4000);
    BEGIN
        v_sql := 'CREATE TABLE ' || v_tbl || ' ('
              || 'id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, '
              || p_columns || ', '
              || 'created_at TIMESTAMP DEFAULT SYSTIMESTAMP, '
              || 'updated_at TIMESTAMP DEFAULT SYSTIMESTAMP)';
        EXECUTE IMMEDIATE v_sql;
        hinoki_core.log_info('Created table: ' || v_tbl);
    END create_table;

    PROCEDURE drop_table(p_table_name IN VARCHAR2) IS
        v_tbl VARCHAR2(200) := hinoki_model.sanitize_identifier(p_table_name);
    BEGIN
        EXECUTE IMMEDIATE 'DROP TABLE ' || v_tbl || ' CASCADE CONSTRAINTS PURGE';
        hinoki_core.log_info('Dropped table: ' || v_tbl);
    EXCEPTION WHEN OTHERS THEN
        IF SQLCODE = -942 THEN
            hinoki_core.log_info('Table ' || v_tbl || ' does not exist, skipping.');
        ELSE
            RAISE;
        END IF;
    END drop_table;

    PROCEDURE add_column(p_table IN VARCHAR2, p_column IN VARCHAR2,
                         p_type IN VARCHAR2, p_default IN VARCHAR2 DEFAULT NULL) IS
        v_tbl VARCHAR2(200) := hinoki_model.sanitize_identifier(p_table);
        v_col VARCHAR2(200) := hinoki_model.sanitize_identifier(p_column);
        v_sql VARCHAR2(4000);
    BEGIN
        v_sql := 'ALTER TABLE ' || v_tbl || ' ADD ' || v_col || ' ' || p_type;
        IF p_default IS NOT NULL THEN
            v_sql := v_sql || ' DEFAULT ' || p_default;
        END IF;
        EXECUTE IMMEDIATE v_sql;
    END add_column;

    PROCEDURE remove_column(p_table IN VARCHAR2, p_column IN VARCHAR2) IS
        v_tbl VARCHAR2(200) := hinoki_model.sanitize_identifier(p_table);
        v_col VARCHAR2(200) := hinoki_model.sanitize_identifier(p_column);
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || v_tbl || ' DROP COLUMN ' || v_col;
    END remove_column;

    PROCEDURE change_column(p_table IN VARCHAR2, p_column IN VARCHAR2,
                            p_type IN VARCHAR2) IS
        v_tbl VARCHAR2(200) := hinoki_model.sanitize_identifier(p_table);
        v_col VARCHAR2(200) := hinoki_model.sanitize_identifier(p_column);
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || v_tbl || ' MODIFY ' || v_col || ' ' || p_type;
    END change_column;

    PROCEDURE add_index(p_table IN VARCHAR2, p_columns IN VARCHAR2,
                        p_unique IN BOOLEAN DEFAULT FALSE,
                        p_name IN VARCHAR2 DEFAULT NULL) IS
        v_tbl  VARCHAR2(200) := hinoki_model.sanitize_identifier(p_table);
        v_name VARCHAR2(200) := NVL(p_name, 'idx_' || v_tbl || '_' || REPLACE(p_columns, ',', '_'));
        v_sql  VARCHAR2(4000);
    BEGIN
        v_sql := 'CREATE ';
        IF p_unique THEN v_sql := v_sql || 'UNIQUE '; END IF;
        v_sql := v_sql || 'INDEX ' || v_name || ' ON ' || v_tbl || ' (' || p_columns || ')';
        EXECUTE IMMEDIATE v_sql;
    END add_index;

    PROCEDURE remove_index(p_name IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'DROP INDEX ' || hinoki_model.sanitize_identifier(p_name);
    END remove_index;

    PROCEDURE add_foreign_key(p_table IN VARCHAR2, p_column IN VARCHAR2,
                              p_ref_table IN VARCHAR2,
                              p_ref_column IN VARCHAR2 DEFAULT 'id',
                              p_on_delete IN VARCHAR2 DEFAULT 'CASCADE') IS
        v_tbl  VARCHAR2(200) := hinoki_model.sanitize_identifier(p_table);
        v_col  VARCHAR2(200) := hinoki_model.sanitize_identifier(p_column);
        v_rtbl VARCHAR2(200) := hinoki_model.sanitize_identifier(p_ref_table);
        v_rcol VARCHAR2(200) := hinoki_model.sanitize_identifier(p_ref_column);
        v_name VARCHAR2(200) := 'fk_' || v_tbl || '_' || v_col;
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || v_tbl
            || ' ADD CONSTRAINT ' || v_name
            || ' FOREIGN KEY (' || v_col || ')'
            || ' REFERENCES ' || v_rtbl || ' (' || v_rcol || ')'
            || ' ON DELETE ' || p_on_delete;
    END add_foreign_key;

    PROCEDURE execute_sql(p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    END execute_sql;

END hinoki_migrate;
/

PROMPT  ✓ hinoki_migrate installed
