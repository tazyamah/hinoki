-- ============================================================
-- HINOKI_MODEL: ActiveRecord ライクなモデル基盤
-- 動的SQLによるCRUD、バリデーション、関連付け
-- ============================================================

CREATE OR REPLACE PACKAGE hinoki_model AS

    -- ========== 型定義 ==========
    TYPE t_record IS TABLE OF VARCHAR2(32767) INDEX BY VARCHAR2(200);
    TYPE t_records IS TABLE OF t_record INDEX BY PLS_INTEGER;

    TYPE t_column IS RECORD (
        name       VARCHAR2(200),
        data_type  VARCHAR2(100),
        nullable   BOOLEAN DEFAULT TRUE,
        max_length NUMBER
    );
    TYPE t_columns IS TABLE OF t_column INDEX BY PLS_INTEGER;

    TYPE t_validation IS RECORD (
        field     VARCHAR2(200),
        rule      VARCHAR2(100),  -- 'presence', 'length', 'numericality', 'format', 'uniqueness'
        param     VARCHAR2(1000),
        message   VARCHAR2(1000)
    );
    TYPE t_validations IS TABLE OF t_validation INDEX BY PLS_INTEGER;

    TYPE t_errors IS TABLE OF VARCHAR2(1000) INDEX BY PLS_INTEGER;

    -- ========== バリデーション結果 ==========
    g_errors t_errors;

    -- ========== CRUD ==========

    -- 全件取得 (WHERE句、ORDER BY句をオプションで指定)
    FUNCTION find_all(
        p_table    IN VARCHAR2,
        p_columns  IN VARCHAR2 DEFAULT '*',
        p_where    IN VARCHAR2 DEFAULT NULL,
        p_order    IN VARCHAR2 DEFAULT 'id DESC',
        p_limit    IN NUMBER   DEFAULT 100,
        p_offset   IN NUMBER   DEFAULT 0
    ) RETURN SYS_REFCURSOR;

    -- ID で1件取得
    FUNCTION find_by_id(
        p_table IN VARCHAR2,
        p_id    IN NUMBER
    ) RETURN SYS_REFCURSOR;

    -- 条件検索 (1件)
    FUNCTION find_by(
        p_table     IN VARCHAR2,
        p_column    IN VARCHAR2,
        p_value     IN VARCHAR2
    ) RETURN SYS_REFCURSOR;

    -- カウント
    FUNCTION count_all(
        p_table IN VARCHAR2,
        p_where IN VARCHAR2 DEFAULT NULL
    ) RETURN NUMBER;

    -- 存在確認
    FUNCTION exists_by_id(
        p_table IN VARCHAR2,
        p_id    IN NUMBER
    ) RETURN BOOLEAN;

    -- INSERT (カラム名=値のペアを受け取り、新規IDを返す)
    FUNCTION create_record(
        p_table   IN VARCHAR2,
        p_columns IN VARCHAR2,  -- カンマ区切り: 'title,body,published'
        p_values  IN VARCHAR2   -- カンマ区切り: '''Hello'',''World'',1'
    ) RETURN NUMBER;

    -- INSERT (レコード型から)
    FUNCTION create_from_record(
        p_table  IN VARCHAR2,
        p_record IN t_record,
        p_columns IN VARCHAR2  -- 許可するカラム (Strong Parameters相当)
    ) RETURN NUMBER;

    -- UPDATE
    PROCEDURE update_record(
        p_table   IN VARCHAR2,
        p_id      IN NUMBER,
        p_set     IN VARCHAR2   -- 'title=''New Title'', body=''New Body'''
    );

    -- UPDATE (レコード型から)
    PROCEDURE update_from_record(
        p_table   IN VARCHAR2,
        p_id      IN NUMBER,
        p_record  IN t_record,
        p_columns IN VARCHAR2  -- 許可するカラム
    );

    -- DELETE
    PROCEDURE delete_record(
        p_table IN VARCHAR2,
        p_id    IN NUMBER
    );

    -- DELETE (条件指定)
    PROCEDURE delete_where(
        p_table IN VARCHAR2,
        p_where IN VARCHAR2
    );

    -- ========== バリデーション ==========

    -- バリデーションルール追加
    PROCEDURE validates_presence(p_field IN VARCHAR2, p_message IN VARCHAR2 DEFAULT NULL);
    PROCEDURE validates_length(p_field IN VARCHAR2, p_min IN NUMBER DEFAULT NULL,
                               p_max IN NUMBER DEFAULT NULL, p_message IN VARCHAR2 DEFAULT NULL);
    PROCEDURE validates_numericality(p_field IN VARCHAR2, p_message IN VARCHAR2 DEFAULT NULL);
    PROCEDURE validates_uniqueness(p_table IN VARCHAR2, p_field IN VARCHAR2,
                                   p_except_id IN NUMBER DEFAULT NULL,
                                   p_message IN VARCHAR2 DEFAULT NULL);

    -- レコードをバリデート
    FUNCTION validate(p_record IN t_record) RETURN BOOLEAN;

    -- エラーメッセージ取得
    FUNCTION errors_to_html RETURN VARCHAR2;
    FUNCTION errors_to_json RETURN CLOB;
    FUNCTION error_count RETURN NUMBER;
    PROCEDURE clear_errors;
    PROCEDURE clear_validations;

    -- ========== ページネーション ==========

    TYPE t_pagination IS RECORD (
        current_page  NUMBER,
        total_pages   NUMBER,
        total_count   NUMBER,
        per_page      NUMBER,
        has_prev      BOOLEAN,
        has_next      BOOLEAN
    );

    FUNCTION paginate(
        p_table    IN VARCHAR2,
        p_page     IN NUMBER DEFAULT 1,
        p_per_page IN NUMBER DEFAULT 25,
        p_where    IN VARCHAR2 DEFAULT NULL,
        p_order    IN VARCHAR2 DEFAULT 'id DESC'
    ) RETURN SYS_REFCURSOR;

    FUNCTION pagination_info(
        p_table    IN VARCHAR2,
        p_page     IN NUMBER DEFAULT 1,
        p_per_page IN NUMBER DEFAULT 25,
        p_where    IN VARCHAR2 DEFAULT NULL
    ) RETURN t_pagination;

    FUNCTION pagination_html(
        p_info     IN t_pagination,
        p_base_url IN VARCHAR2
    ) RETURN VARCHAR2;

    -- ========== JSON出力 ==========

    -- カーソルをJSON配列に変換
    FUNCTION cursor_to_json(
        p_cursor  IN SYS_REFCURSOR,
        p_columns IN VARCHAR2  -- カンマ区切り列名
    ) RETURN CLOB;

    -- 単一行をJSONオブジェクトに変換
    FUNCTION row_to_json(
        p_cursor  IN SYS_REFCURSOR,
        p_columns IN VARCHAR2
    ) RETURN CLOB;

    -- ========== テーブルメタデータ ==========

    FUNCTION get_columns(p_table IN VARCHAR2) RETURN t_columns;
    FUNCTION column_names(p_table IN VARCHAR2) RETURN VARCHAR2;
    FUNCTION table_exists(p_table IN VARCHAR2) RETURN BOOLEAN;

    -- ========== ヘルパー ==========
    FUNCTION sanitize_identifier(p_name IN VARCHAR2) RETURN VARCHAR2;

END hinoki_model;
/

CREATE OR REPLACE PACKAGE BODY hinoki_model AS

    -- プライベート変数
    g_validations t_validations;
    g_val_count   PLS_INTEGER := 0;

    -- ========== CRUD ==========

    FUNCTION find_all(
        p_table    IN VARCHAR2,
        p_columns  IN VARCHAR2 DEFAULT '*',
        p_where    IN VARCHAR2 DEFAULT NULL,
        p_order    IN VARCHAR2 DEFAULT 'id DESC',
        p_limit    IN NUMBER   DEFAULT 100,
        p_offset   IN NUMBER   DEFAULT 0
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
        v_sql    VARCHAR2(4000);
        v_tbl    VARCHAR2(200) := sanitize_identifier(p_table);
    BEGIN
        v_sql := 'SELECT ' || p_columns || ' FROM ' || v_tbl;
        IF p_where IS NOT NULL THEN
            v_sql := v_sql || ' WHERE ' || p_where;
        END IF;
        IF p_order IS NOT NULL THEN
            v_sql := v_sql || ' ORDER BY ' || p_order;
        END IF;
        v_sql := v_sql || ' OFFSET ' || p_offset || ' ROWS FETCH NEXT ' || p_limit || ' ROWS ONLY';

        OPEN v_cursor FOR v_sql;
        RETURN v_cursor;
    END find_all;

    FUNCTION find_by_id(p_table IN VARCHAR2, p_id IN NUMBER) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
        v_tbl    VARCHAR2(200) := sanitize_identifier(p_table);
    BEGIN
        OPEN v_cursor FOR
            'SELECT * FROM ' || v_tbl || ' WHERE id = :id' USING p_id;
        RETURN v_cursor;
    END find_by_id;

    FUNCTION find_by(p_table IN VARCHAR2, p_column IN VARCHAR2, p_value IN VARCHAR2)
        RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
        v_tbl    VARCHAR2(200) := sanitize_identifier(p_table);
        v_col    VARCHAR2(200) := sanitize_identifier(p_column);
    BEGIN
        OPEN v_cursor FOR
            'SELECT * FROM ' || v_tbl || ' WHERE ' || v_col || ' = :val' USING p_value;
        RETURN v_cursor;
    END find_by;

    FUNCTION count_all(p_table IN VARCHAR2, p_where IN VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
        v_count NUMBER;
        v_tbl   VARCHAR2(200) := sanitize_identifier(p_table);
        v_sql   VARCHAR2(4000);
    BEGIN
        v_sql := 'SELECT COUNT(*) FROM ' || v_tbl;
        IF p_where IS NOT NULL THEN
            v_sql := v_sql || ' WHERE ' || p_where;
        END IF;
        EXECUTE IMMEDIATE v_sql INTO v_count;
        RETURN v_count;
    END count_all;

    FUNCTION exists_by_id(p_table IN VARCHAR2, p_id IN NUMBER) RETURN BOOLEAN IS
        v_count NUMBER;
        v_tbl   VARCHAR2(200) := sanitize_identifier(p_table);
    BEGIN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || v_tbl || ' WHERE id = :id'
            INTO v_count USING p_id;
        RETURN v_count > 0;
    END exists_by_id;

    FUNCTION create_record(p_table IN VARCHAR2, p_columns IN VARCHAR2,
                           p_values IN VARCHAR2) RETURN NUMBER IS
        v_id  NUMBER;
        v_tbl VARCHAR2(200) := sanitize_identifier(p_table);
        v_sql VARCHAR2(4000);
    BEGIN
        v_sql := 'INSERT INTO ' || v_tbl || ' (' || p_columns || ', created_at, updated_at)'
              || ' VALUES (' || p_values || ', SYSTIMESTAMP, SYSTIMESTAMP)'
              || ' RETURNING id INTO :new_id';
        EXECUTE IMMEDIATE v_sql RETURNING INTO v_id;
        COMMIT;
        RETURN v_id;
    END create_record;

    FUNCTION create_from_record(p_table IN VARCHAR2, p_record IN t_record,
                                p_columns IN VARCHAR2) RETURN NUMBER IS
        v_col_list VARCHAR2(4000) := '';
        v_val_list VARCHAR2(32767) := '';
        v_col      VARCHAR2(200);
        v_pos      PLS_INTEGER;
        v_cols_str VARCHAR2(4000) := p_columns;
        v_first    BOOLEAN := TRUE;
    BEGIN
        -- 許可されたカラムのみ処理
        LOOP
            v_pos := INSTR(v_cols_str, ',');
            IF v_pos > 0 THEN
                v_col := TRIM(SUBSTR(v_cols_str, 1, v_pos - 1));
                v_cols_str := SUBSTR(v_cols_str, v_pos + 1);
            ELSE
                v_col := TRIM(v_cols_str);
            END IF;

            IF p_record.EXISTS(v_col) THEN
                IF NOT v_first THEN
                    v_col_list := v_col_list || ', ';
                    v_val_list := v_val_list || ', ';
                END IF;
                v_col_list := v_col_list || sanitize_identifier(v_col);
                v_val_list := v_val_list || '''' || REPLACE(p_record(v_col), '''', '''''') || '''';
                v_first := FALSE;
            END IF;

            EXIT WHEN v_pos = 0;
        END LOOP;

        IF v_col_list IS NOT NULL THEN
            RETURN create_record(p_table, v_col_list, v_val_list);
        END IF;
        RETURN NULL;
    END create_from_record;

    PROCEDURE update_record(p_table IN VARCHAR2, p_id IN NUMBER, p_set IN VARCHAR2) IS
        v_tbl VARCHAR2(200) := sanitize_identifier(p_table);
    BEGIN
        EXECUTE IMMEDIATE 'UPDATE ' || v_tbl
            || ' SET ' || p_set || ', updated_at = SYSTIMESTAMP WHERE id = :id'
            USING p_id;
        COMMIT;
    END update_record;

    PROCEDURE update_from_record(p_table IN VARCHAR2, p_id IN NUMBER,
                                 p_record IN t_record, p_columns IN VARCHAR2) IS
        v_set      VARCHAR2(32767) := '';
        v_col      VARCHAR2(200);
        v_pos      PLS_INTEGER;
        v_cols_str VARCHAR2(4000) := p_columns;
        v_first    BOOLEAN := TRUE;
    BEGIN
        LOOP
            v_pos := INSTR(v_cols_str, ',');
            IF v_pos > 0 THEN
                v_col := TRIM(SUBSTR(v_cols_str, 1, v_pos - 1));
                v_cols_str := SUBSTR(v_cols_str, v_pos + 1);
            ELSE
                v_col := TRIM(v_cols_str);
            END IF;

            IF p_record.EXISTS(v_col) THEN
                IF NOT v_first THEN v_set := v_set || ', '; END IF;
                v_set := v_set || sanitize_identifier(v_col) || ' = '''
                       || REPLACE(p_record(v_col), '''', '''''') || '''';
                v_first := FALSE;
            END IF;

            EXIT WHEN v_pos = 0;
        END LOOP;

        IF v_set IS NOT NULL THEN
            update_record(p_table, p_id, v_set);
        END IF;
    END update_from_record;

    PROCEDURE delete_record(p_table IN VARCHAR2, p_id IN NUMBER) IS
        v_tbl VARCHAR2(200) := sanitize_identifier(p_table);
    BEGIN
        EXECUTE IMMEDIATE 'DELETE FROM ' || v_tbl || ' WHERE id = :id' USING p_id;
        COMMIT;
    END delete_record;

    PROCEDURE delete_where(p_table IN VARCHAR2, p_where IN VARCHAR2) IS
        v_tbl VARCHAR2(200) := sanitize_identifier(p_table);
    BEGIN
        EXECUTE IMMEDIATE 'DELETE FROM ' || v_tbl || ' WHERE ' || p_where;
        COMMIT;
    END delete_where;

    -- ========== バリデーション ==========

    PROCEDURE validates_presence(p_field IN VARCHAR2, p_message IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        g_val_count := g_val_count + 1;
        g_validations(g_val_count).field := p_field;
        g_validations(g_val_count).rule := 'presence';
        g_validations(g_val_count).message := NVL(p_message,
            INITCAP(REPLACE(p_field, '_', ' ')) || 'は必須です');
    END validates_presence;

    PROCEDURE validates_length(p_field IN VARCHAR2, p_min IN NUMBER DEFAULT NULL,
                               p_max IN NUMBER DEFAULT NULL,
                               p_message IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        g_val_count := g_val_count + 1;
        g_validations(g_val_count).field := p_field;
        g_validations(g_val_count).rule := 'length';
        g_validations(g_val_count).param := NVL(TO_CHAR(p_min), '') || ',' || NVL(TO_CHAR(p_max), '');
        g_validations(g_val_count).message := NVL(p_message,
            INITCAP(REPLACE(p_field, '_', ' ')) || 'の長さが不正です');
    END validates_length;

    PROCEDURE validates_numericality(p_field IN VARCHAR2, p_message IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        g_val_count := g_val_count + 1;
        g_validations(g_val_count).field := p_field;
        g_validations(g_val_count).rule := 'numericality';
        g_validations(g_val_count).message := NVL(p_message,
            INITCAP(REPLACE(p_field, '_', ' ')) || 'は数値でなければなりません');
    END validates_numericality;

    PROCEDURE validates_uniqueness(p_table IN VARCHAR2, p_field IN VARCHAR2,
                                   p_except_id IN NUMBER DEFAULT NULL,
                                   p_message IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        g_val_count := g_val_count + 1;
        g_validations(g_val_count).field := p_field;
        g_validations(g_val_count).rule := 'uniqueness';
        g_validations(g_val_count).param := p_table || ',' || NVL(TO_CHAR(p_except_id), '');
        g_validations(g_val_count).message := NVL(p_message,
            INITCAP(REPLACE(p_field, '_', ' ')) || 'は既に使用されています');
    END validates_uniqueness;

    FUNCTION validate(p_record IN t_record) RETURN BOOLEAN IS
        v_val   t_validation;
        v_value VARCHAR2(32767);
        v_valid BOOLEAN := TRUE;
        v_min   NUMBER;
        v_max   NUMBER;
        v_cnt   NUMBER;
        v_err_idx PLS_INTEGER := 0;
    BEGIN
        g_errors.DELETE;

        FOR i IN 1..g_val_count LOOP
            v_val := g_validations(i);

            IF p_record.EXISTS(v_val.field) THEN
                v_value := p_record(v_val.field);
            ELSE
                v_value := NULL;
            END IF;

            CASE v_val.rule
                WHEN 'presence' THEN
                    IF v_value IS NULL OR TRIM(v_value) = '' THEN
                        v_err_idx := v_err_idx + 1;
                        g_errors(v_err_idx) := v_val.message;
                        v_valid := FALSE;
                    END IF;

                WHEN 'length' THEN
                    IF v_value IS NOT NULL THEN
                        v_min := TO_NUMBER(REGEXP_SUBSTR(v_val.param, '[^,]+', 1, 1));
                        v_max := TO_NUMBER(REGEXP_SUBSTR(v_val.param, '[^,]+', 1, 2));
                        IF (v_min IS NOT NULL AND LENGTH(v_value) < v_min) OR
                           (v_max IS NOT NULL AND LENGTH(v_value) > v_max) THEN
                            v_err_idx := v_err_idx + 1;
                            g_errors(v_err_idx) := v_val.message;
                            v_valid := FALSE;
                        END IF;
                    END IF;

                WHEN 'numericality' THEN
                    IF v_value IS NOT NULL THEN
                        BEGIN
                            v_cnt := TO_NUMBER(v_value);
                        EXCEPTION WHEN OTHERS THEN
                            v_err_idx := v_err_idx + 1;
                            g_errors(v_err_idx) := v_val.message;
                            v_valid := FALSE;
                        END;
                    END IF;

                WHEN 'uniqueness' THEN
                    IF v_value IS NOT NULL THEN
                        DECLARE
                            v_tbl VARCHAR2(200) := sanitize_identifier(
                                REGEXP_SUBSTR(v_val.param, '[^,]+', 1, 1));
                            v_exc VARCHAR2(200) := REGEXP_SUBSTR(v_val.param, '[^,]+', 1, 2);
                            v_col VARCHAR2(200) := sanitize_identifier(v_val.field);
                            v_sql VARCHAR2(4000);
                        BEGIN
                            v_sql := 'SELECT COUNT(*) FROM ' || v_tbl
                                  || ' WHERE ' || v_col || ' = :val';
                            IF v_exc IS NOT NULL THEN
                                v_sql := v_sql || ' AND id != :exc_id';
                                EXECUTE IMMEDIATE v_sql INTO v_cnt USING v_value, TO_NUMBER(v_exc);
                            ELSE
                                EXECUTE IMMEDIATE v_sql INTO v_cnt USING v_value;
                            END IF;
                            IF v_cnt > 0 THEN
                                v_err_idx := v_err_idx + 1;
                                g_errors(v_err_idx) := v_val.message;
                                v_valid := FALSE;
                            END IF;
                        END;
                    END IF;

                ELSE NULL;
            END CASE;
        END LOOP;

        RETURN v_valid;
    END validate;

    FUNCTION errors_to_html RETURN VARCHAR2 IS
        v_html VARCHAR2(4000) := '';
    BEGIN
        IF g_errors.COUNT = 0 THEN RETURN ''; END IF;
        v_html := '<div class="hinoki-errors"><h4>エラーが発生しました:</h4><ul>';
        FOR i IN 1..g_errors.COUNT LOOP
            v_html := v_html || '<li>' || hinoki_core.h(g_errors(i)) || '</li>';
        END LOOP;
        v_html := v_html || '</ul></div>';
        RETURN v_html;
    END errors_to_html;

    FUNCTION errors_to_json RETURN CLOB IS
        v_json CLOB := '{"errors":[';
    BEGIN
        FOR i IN 1..g_errors.COUNT LOOP
            IF i > 1 THEN v_json := v_json || ','; END IF;
            v_json := v_json || hinoki_core.to_json_value(g_errors(i));
        END LOOP;
        v_json := v_json || ']}';
        RETURN v_json;
    END errors_to_json;

    FUNCTION error_count RETURN NUMBER IS
    BEGIN RETURN g_errors.COUNT; END;

    PROCEDURE clear_errors IS
    BEGIN g_errors.DELETE; END;

    PROCEDURE clear_validations IS
    BEGIN g_validations.DELETE; g_val_count := 0; END;

    -- ========== ページネーション ==========

    FUNCTION paginate(p_table IN VARCHAR2, p_page IN NUMBER DEFAULT 1,
                      p_per_page IN NUMBER DEFAULT 25, p_where IN VARCHAR2 DEFAULT NULL,
                      p_order IN VARCHAR2 DEFAULT 'id DESC') RETURN SYS_REFCURSOR IS
        v_offset NUMBER := (GREATEST(p_page, 1) - 1) * p_per_page;
    BEGIN
        RETURN find_all(p_table, '*', p_where, p_order, p_per_page, v_offset);
    END paginate;

    FUNCTION pagination_info(p_table IN VARCHAR2, p_page IN NUMBER DEFAULT 1,
                             p_per_page IN NUMBER DEFAULT 25,
                             p_where IN VARCHAR2 DEFAULT NULL) RETURN t_pagination IS
        v_info t_pagination;
    BEGIN
        v_info.total_count := count_all(p_table, p_where);
        v_info.per_page := p_per_page;
        v_info.total_pages := CEIL(v_info.total_count / p_per_page);
        v_info.current_page := GREATEST(1, LEAST(p_page, v_info.total_pages));
        v_info.has_prev := v_info.current_page > 1;
        v_info.has_next := v_info.current_page < v_info.total_pages;
        RETURN v_info;
    END pagination_info;

    FUNCTION pagination_html(p_info IN t_pagination, p_base_url IN VARCHAR2) RETURN VARCHAR2 IS
        v_html VARCHAR2(4000) := '<nav class="hinoki-pagination">';
    BEGIN
        IF p_info.total_pages <= 1 THEN RETURN ''; END IF;

        IF p_info.has_prev THEN
            v_html := v_html || '<a href="' || p_base_url || '?page='
                   || (p_info.current_page - 1) || '">&laquo; 前へ</a>';
        END IF;

        FOR i IN 1..p_info.total_pages LOOP
            IF i = p_info.current_page THEN
                v_html := v_html || '<span class="current">' || i || '</span>';
            ELSE
                v_html := v_html || '<a href="' || p_base_url || '?page=' || i || '">' || i || '</a>';
            END IF;
        END LOOP;

        IF p_info.has_next THEN
            v_html := v_html || '<a href="' || p_base_url || '?page='
                   || (p_info.current_page + 1) || '">次へ &raquo;</a>';
        END IF;

        v_html := v_html || '</nav>';
        RETURN v_html;
    END pagination_html;

    -- ========== JSON出力 ==========

    FUNCTION cursor_to_json(p_cursor IN SYS_REFCURSOR, p_columns IN VARCHAR2) RETURN CLOB IS
        v_json       CLOB := '[';
        v_cursor_id  NUMBER;
        v_cols       DBMS_SQL.desc_tab;
        v_col_cnt    NUMBER;
        v_varchar    VARCHAR2(32767);
        v_first      BOOLEAN := TRUE;

        TYPE t_names IS TABLE OF VARCHAR2(200) INDEX BY PLS_INTEGER;
        v_names t_names;
        v_idx   PLS_INTEGER := 0;
        v_pos   PLS_INTEGER;
        v_str   VARCHAR2(4000) := p_columns;
    BEGIN
        -- カラム名パース
        LOOP
            v_idx := v_idx + 1;
            v_pos := INSTR(v_str, ',');
            IF v_pos > 0 THEN
                v_names(v_idx) := TRIM(SUBSTR(v_str, 1, v_pos - 1));
                v_str := SUBSTR(v_str, v_pos + 1);
            ELSE
                v_names(v_idx) := TRIM(v_str);
                EXIT;
            END IF;
        END LOOP;

        v_cursor_id := DBMS_SQL.to_cursor_number(p_cursor);
        DBMS_SQL.describe_columns(v_cursor_id, v_col_cnt, v_cols);
        FOR i IN 1..v_col_cnt LOOP
            DBMS_SQL.define_column(v_cursor_id, i, v_varchar, 32767);
        END LOOP;

        LOOP
            EXIT WHEN DBMS_SQL.fetch_rows(v_cursor_id) = 0;
            IF NOT v_first THEN v_json := v_json || ','; END IF;
            v_first := FALSE;
            v_json := v_json || '{';
            FOR i IN 1..LEAST(v_col_cnt, v_names.COUNT) LOOP
                DBMS_SQL.column_value(v_cursor_id, i, v_varchar);
                IF i > 1 THEN v_json := v_json || ','; END IF;
                v_json := v_json || hinoki_core.json_kv(v_names(i), v_varchar, FALSE);
            END LOOP;
            v_json := v_json || '}';
        END LOOP;

        DBMS_SQL.close_cursor(v_cursor_id);
        v_json := v_json || ']';
        RETURN v_json;
    END cursor_to_json;

    FUNCTION row_to_json(p_cursor IN SYS_REFCURSOR, p_columns IN VARCHAR2) RETURN CLOB IS
        v_json CLOB;
    BEGIN
        v_json := cursor_to_json(p_cursor, p_columns);
        -- 配列の最初の要素を返す
        IF LENGTH(v_json) > 2 THEN
            RETURN SUBSTR(v_json, 2, LENGTH(v_json) - 2);
        END IF;
        RETURN 'null';
    END row_to_json;

    -- ========== テーブルメタデータ ==========

    FUNCTION get_columns(p_table IN VARCHAR2) RETURN t_columns IS
        v_cols t_columns;
        v_idx  PLS_INTEGER := 0;
    BEGIN
        FOR rec IN (
            SELECT column_name, data_type, nullable, data_length
            FROM user_tab_columns
            WHERE table_name = UPPER(p_table)
            ORDER BY column_id
        ) LOOP
            v_idx := v_idx + 1;
            v_cols(v_idx).name := LOWER(rec.column_name);
            v_cols(v_idx).data_type := rec.data_type;
            v_cols(v_idx).nullable := rec.nullable = 'Y';
            v_cols(v_idx).max_length := rec.data_length;
        END LOOP;
        RETURN v_cols;
    END get_columns;

    FUNCTION column_names(p_table IN VARCHAR2) RETURN VARCHAR2 IS
        v_names VARCHAR2(4000) := '';
    BEGIN
        FOR rec IN (
            SELECT LOWER(column_name) AS col
            FROM user_tab_columns
            WHERE table_name = UPPER(p_table)
            ORDER BY column_id
        ) LOOP
            IF v_names IS NOT NULL THEN v_names := v_names || ','; END IF;
            v_names := v_names || rec.col;
        END LOOP;
        RETURN v_names;
    END column_names;

    FUNCTION table_exists(p_table IN VARCHAR2) RETURN BOOLEAN IS
        v_cnt NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt FROM user_tables WHERE table_name = UPPER(p_table);
        RETURN v_cnt > 0;
    END table_exists;

    -- ========== ヘルパー ==========

    FUNCTION sanitize_identifier(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        -- SQLインジェクション防止: 英数字とアンダースコアのみ許可
        RETURN REGEXP_REPLACE(p_name, '[^a-zA-Z0-9_]', '');
    END sanitize_identifier;

END hinoki_model;
/

PROMPT  ✓ hinoki_model installed
