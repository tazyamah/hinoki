-- ============================================================
-- HINOKI_CONTROLLER: コントローラ基盤
-- before_action / after_action, レスポンスヘルパー
-- ============================================================

CREATE OR REPLACE PACKAGE hinoki_controller AS

    -- ========== コールバック管理 ==========
    TYPE t_callback IS RECORD (
        controller VARCHAR2(200),
        proc_name  VARCHAR2(200),
        only       VARCHAR2(1000),  -- カンマ区切りアクション名、NULLなら全て
        except     VARCHAR2(1000)
    );
    TYPE t_callbacks IS TABLE OF t_callback INDEX BY PLS_INTEGER;

    -- before_action 登録
    PROCEDURE before_action(
        p_controller IN VARCHAR2,
        p_proc_name  IN VARCHAR2,
        p_only       IN VARCHAR2 DEFAULT NULL,
        p_except     IN VARCHAR2 DEFAULT NULL
    );

    -- before_action 実行
    PROCEDURE run_before_actions(p_controller IN VARCHAR2, p_action IN VARCHAR2);

    -- ========== Strong Parameters ==========
    -- ORDSバインド変数からパラメータ取得 (SQLインジェクション対策済み)
    FUNCTION permit(p_allowed_columns IN VARCHAR2) RETURN hinoki_model.t_record;

    -- ========== レスポンスショートカット ==========

    -- HTMLレンダリング
    PROCEDURE render_view(
        p_template  IN VARCHAR2,
        p_layout    IN VARCHAR2 DEFAULT NULL,
        p_status    IN NUMBER   DEFAULT 200
    );

    -- JSONレンダリング
    PROCEDURE render_json(
        p_data   IN CLOB,
        p_status IN NUMBER DEFAULT 200
    );

    -- リダイレクト
    PROCEDURE redirect_to(
        p_url     IN VARCHAR2,
        p_flash   IN VARCHAR2 DEFAULT NULL,
        p_flash_type IN VARCHAR2 DEFAULT 'notice'
    );

    -- ========== ビューヘルパー ==========

    -- CRUD共通のナビゲーション
    FUNCTION nav_links(p_resource IN VARCHAR2, p_current IN VARCHAR2 DEFAULT NULL)
        RETURN VARCHAR2;

    -- CRUD用の標準テーブルHTML
    FUNCTION table_for(
        p_cursor    IN SYS_REFCURSOR,
        p_columns   IN VARCHAR2,
        p_labels    IN VARCHAR2 DEFAULT NULL,
        p_resource  IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    -- フォームヘルパー (model_record を元にフォーム生成)
    FUNCTION form_for(
        p_action   IN VARCHAR2,
        p_method   IN VARCHAR2 DEFAULT 'POST',
        p_record   IN hinoki_model.t_record DEFAULT hinoki_model.t_record(),
        p_columns  IN VARCHAR2 DEFAULT NULL,
        p_labels   IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

END hinoki_controller;
/

CREATE OR REPLACE PACKAGE BODY hinoki_controller AS

    g_before_actions t_callbacks;
    g_ba_count       PLS_INTEGER := 0;

    -- ========== コールバック ==========

    PROCEDURE before_action(p_controller IN VARCHAR2, p_proc_name IN VARCHAR2,
                            p_only IN VARCHAR2 DEFAULT NULL,
                            p_except IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        g_ba_count := g_ba_count + 1;
        g_before_actions(g_ba_count).controller := LOWER(p_controller);
        g_before_actions(g_ba_count).proc_name := p_proc_name;
        g_before_actions(g_ba_count).only := LOWER(p_only);
        g_before_actions(g_ba_count).except := LOWER(p_except);
    END before_action;

    PROCEDURE run_before_actions(p_controller IN VARCHAR2, p_action IN VARCHAR2) IS
        v_cb     t_callback;
        v_run    BOOLEAN;
    BEGIN
        FOR i IN 1..g_ba_count LOOP
            v_cb := g_before_actions(i);
            IF LOWER(p_controller) = v_cb.controller THEN
                v_run := TRUE;
                IF v_cb.only IS NOT NULL THEN
                    v_run := INSTR(',' || v_cb.only || ',',
                                   ',' || LOWER(p_action) || ',') > 0;
                END IF;
                IF v_cb.except IS NOT NULL THEN
                    IF INSTR(',' || v_cb.except || ',',
                             ',' || LOWER(p_action) || ',') > 0 THEN
                        v_run := FALSE;
                    END IF;
                END IF;

                IF v_run THEN
                    EXECUTE IMMEDIATE 'BEGIN ' || v_cb.controller || '.'
                                   || v_cb.proc_name || '; END;';
                END IF;
            END IF;
        END LOOP;
    END run_before_actions;

    -- ========== Strong Parameters ==========

    FUNCTION permit(p_allowed_columns IN VARCHAR2) RETURN hinoki_model.t_record IS
        v_record hinoki_model.t_record;
        v_col    VARCHAR2(200);
        v_val    VARCHAR2(32767);
        v_pos    PLS_INTEGER;
        v_str    VARCHAR2(4000) := p_allowed_columns;
    BEGIN
        LOOP
            v_pos := INSTR(v_str, ',');
            IF v_pos > 0 THEN
                v_col := TRIM(SUBSTR(v_str, 1, v_pos - 1));
                v_str := SUBSTR(v_str, v_pos + 1);
            ELSE
                v_col := TRIM(v_str);
            END IF;

            v_val := hinoki_core.param(v_col);
            IF v_val IS NOT NULL THEN
                v_record(v_col) := v_val;
            END IF;

            EXIT WHEN v_pos = 0;
        END LOOP;
        RETURN v_record;
    END permit;

    -- ========== レスポンスショートカット ==========

    PROCEDURE render_view(p_template IN VARCHAR2, p_layout IN VARCHAR2 DEFAULT NULL,
                          p_status IN NUMBER DEFAULT 200) IS
    BEGIN
        hinoki_view.render_to(p_template, p_layout, p_status);
    END render_view;

    PROCEDURE render_json(p_data IN CLOB, p_status IN NUMBER DEFAULT 200) IS
    BEGIN
        hinoki_core.respond_json(p_data, p_status);
    END render_json;

    PROCEDURE redirect_to(p_url IN VARCHAR2, p_flash IN VARCHAR2 DEFAULT NULL,
                          p_flash_type IN VARCHAR2 DEFAULT 'notice') IS
    BEGIN
        IF p_flash IS NOT NULL THEN
            hinoki_core.flash(p_flash_type, p_flash);
        END IF;
        hinoki_core.redirect(p_url);
    END redirect_to;

    -- ========== ビューヘルパー ==========

    FUNCTION nav_links(p_resource IN VARCHAR2, p_current IN VARCHAR2 DEFAULT NULL)
        RETURN VARCHAR2 IS
        v_base VARCHAR2(200) := '/' || p_resource;
    BEGIN
        RETURN '<nav class="hinoki-nav">'
            || CASE WHEN p_current = 'index' THEN '<strong>一覧</strong>'
               ELSE '<a href="' || v_base || '">一覧</a>' END
            || ' | '
            || CASE WHEN p_current = 'new' THEN '<strong>新規作成</strong>'
               ELSE '<a href="' || v_base || '/new">新規作成</a>' END
            || '</nav>';
    END nav_links;

    FUNCTION table_for(p_cursor IN SYS_REFCURSOR, p_columns IN VARCHAR2,
                       p_labels IN VARCHAR2 DEFAULT NULL,
                       p_resource IN VARCHAR2 DEFAULT NULL) RETURN CLOB IS
        v_html      CLOB := '<table class="hinoki-table"><thead><tr>';
        v_cursor_id NUMBER;
        v_cols      DBMS_SQL.desc_tab;
        v_col_cnt   NUMBER;
        v_varchar   VARCHAR2(32767);

        TYPE t_names IS TABLE OF VARCHAR2(200) INDEX BY PLS_INTEGER;
        v_col_names  t_names;
        v_col_labels t_names;
        v_idx        PLS_INTEGER := 0;
        v_pos        PLS_INTEGER;
        v_str        VARCHAR2(4000);
        v_first      BOOLEAN;
        v_id_val     VARCHAR2(200);
    BEGIN
        -- カラム名パース
        v_str := p_columns;
        LOOP
            v_idx := v_idx + 1;
            v_pos := INSTR(v_str, ',');
            IF v_pos > 0 THEN
                v_col_names(v_idx) := TRIM(SUBSTR(v_str, 1, v_pos - 1));
                v_str := SUBSTR(v_str, v_pos + 1);
            ELSE
                v_col_names(v_idx) := TRIM(v_str);
                EXIT;
            END IF;
        END LOOP;

        -- ラベルパース
        IF p_labels IS NOT NULL THEN
            v_str := p_labels;
            v_idx := 0;
            LOOP
                v_idx := v_idx + 1;
                v_pos := INSTR(v_str, ',');
                IF v_pos > 0 THEN
                    v_col_labels(v_idx) := TRIM(SUBSTR(v_str, 1, v_pos - 1));
                    v_str := SUBSTR(v_str, v_pos + 1);
                ELSE
                    v_col_labels(v_idx) := TRIM(v_str);
                    EXIT;
                END IF;
            END LOOP;
        END IF;

        -- ヘッダー行
        FOR i IN 1..v_col_names.COUNT LOOP
            IF v_col_labels.EXISTS(i) THEN
                v_html := v_html || '<th>' || hinoki_core.h(v_col_labels(i)) || '</th>';
            ELSE
                v_html := v_html || '<th>' || hinoki_core.h(
                    INITCAP(REPLACE(v_col_names(i), '_', ' '))) || '</th>';
            END IF;
        END LOOP;
        IF p_resource IS NOT NULL THEN
            v_html := v_html || '<th>操作</th>';
        END IF;
        v_html := v_html || '</tr></thead><tbody>';

        -- データ行
        v_cursor_id := DBMS_SQL.to_cursor_number(p_cursor);
        DBMS_SQL.describe_columns(v_cursor_id, v_col_cnt, v_cols);
        FOR i IN 1..v_col_cnt LOOP
            DBMS_SQL.define_column(v_cursor_id, i, v_varchar, 32767);
        END LOOP;

        LOOP
            EXIT WHEN DBMS_SQL.fetch_rows(v_cursor_id) = 0;
            v_html := v_html || '<tr>';
            v_id_val := NULL;

            FOR i IN 1..v_col_cnt LOOP
                DBMS_SQL.column_value(v_cursor_id, i, v_varchar);
                IF LOWER(v_cols(i).col_name) = 'id' THEN
                    v_id_val := v_varchar;
                END IF;
                -- 表示対象のカラムか確認
                FOR j IN 1..v_col_names.COUNT LOOP
                    IF LOWER(v_cols(i).col_name) = LOWER(v_col_names(j)) THEN
                        v_html := v_html || '<td>' || hinoki_core.h(NVL(v_varchar, '')) || '</td>';
                    END IF;
                END LOOP;
            END LOOP;

            -- 操作リンク
            IF p_resource IS NOT NULL AND v_id_val IS NOT NULL THEN
                v_html := v_html || '<td class="hinoki-actions">'
                    || '<a href="/' || p_resource || '/' || v_id_val || '">詳細</a> '
                    || '<a href="/' || p_resource || '/' || v_id_val || '/edit">編集</a> '
                    || '<a href="/' || p_resource || '/' || v_id_val || '/delete"'
                    || ' class="hinoki-danger"'
                    || ' onclick="return confirm(''本当に削除しますか？'')">削除</a>'
                    || '</td>';
            END IF;

            v_html := v_html || '</tr>';
        END LOOP;

        DBMS_SQL.close_cursor(v_cursor_id);
        v_html := v_html || '</tbody></table>';
        RETURN v_html;
    EXCEPTION WHEN OTHERS THEN
        IF DBMS_SQL.is_open(v_cursor_id) THEN
            DBMS_SQL.close_cursor(v_cursor_id);
        END IF;
        RAISE;
    END table_for;

    FUNCTION form_for(p_action IN VARCHAR2, p_method IN VARCHAR2 DEFAULT 'POST',
                      p_record IN hinoki_model.t_record DEFAULT hinoki_model.t_record(),
                      p_columns IN VARCHAR2 DEFAULT NULL,
                      p_labels IN VARCHAR2 DEFAULT NULL) RETURN CLOB IS
        v_html CLOB;
        v_col  VARCHAR2(200);
        v_pos  PLS_INTEGER;
        v_str  VARCHAR2(4000) := p_columns;
        v_val  VARCHAR2(32767);
    BEGIN
        v_html := hinoki_core.form_tag(p_action, p_method);
        v_html := v_html || hinoki_model.errors_to_html;

        IF v_str IS NOT NULL THEN
            LOOP
                v_pos := INSTR(v_str, ',');
                IF v_pos > 0 THEN
                    v_col := TRIM(SUBSTR(v_str, 1, v_pos - 1));
                    v_str := SUBSTR(v_str, v_pos + 1);
                ELSE
                    v_col := TRIM(v_str);
                END IF;

                IF p_record.EXISTS(v_col) THEN
                    v_val := p_record(v_col);
                ELSE
                    v_val := NULL;
                END IF;

                -- CLOBっぽいカラム名ならtextarea
                IF LOWER(v_col) IN ('body', 'content', 'description', 'text', 'memo', 'note') THEN
                    v_html := v_html || hinoki_core.text_area(v_col, v_val);
                ELSE
                    v_html := v_html || hinoki_core.text_field(v_col, v_val);
                END IF;

                EXIT WHEN v_pos = 0;
            END LOOP;
        END IF;

        v_html := v_html || '<div class="hinoki-actions">'
                || hinoki_core.submit_button('保存')
                || '</div>';
        v_html := v_html || hinoki_core.form_end;
        RETURN v_html;
    END form_for;

END hinoki_controller;
/

PROMPT  ✓ hinoki_controller installed
