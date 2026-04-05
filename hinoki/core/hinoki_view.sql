-- ============================================================
-- HINOKI_VIEW: テンプレートエンジン
-- ERBライクな構文でHTMLを動的生成
--
-- 構文:
--   {{ variable }}            - 変数展開 (HTMLエスケープ済み)
--   {{{ variable }}}          - 変数展開 (エスケープなし/raw)
--   {% if cond %}...{% endif %}
--   {% for item in collection %}...{% endfor %}  ★NEW
--   {{ item.field }}          - ループ内フィールドアクセス ★NEW
--   {{ item.field | filter }} - パイプフィルター         ★NEW
--   {% partial "name" %}
--   {% yield %}               - レイアウト内でコンテンツ挿入位置
-- ============================================================

CREATE OR REPLACE PACKAGE hinoki_view AS
    TYPE t_vars IS TABLE OF VARCHAR2(32767) INDEX BY VARCHAR2(200);
    g_vars t_vars;

    PROCEDURE assign(p_key IN VARCHAR2, p_value IN VARCHAR2);
    PROCEDURE assign(p_key IN VARCHAR2, p_value IN NUMBER);
    PROCEDURE assign(p_key IN VARCHAR2, p_value IN DATE);
    PROCEDURE assign_raw(p_key IN VARCHAR2, p_value IN CLOB);
    PROCEDURE clear_vars;

    -- コレクション (JSON配列)
    PROCEDURE assign_collection(p_key IN VARCHAR2, p_cursor IN SYS_REFCURSOR);
    PROCEDURE assign_collection_json(p_key IN VARCHAR2, p_json IN CLOB);

    PROCEDURE save_template(p_name IN VARCHAR2, p_content IN CLOB, p_layout IN VARCHAR2 DEFAULT 'application');
    FUNCTION load_template(p_name IN VARCHAR2) RETURN CLOB;
    FUNCTION template_exists(p_name IN VARCHAR2) RETURN BOOLEAN;
    FUNCTION render(p_template_name IN VARCHAR2, p_layout IN VARCHAR2 DEFAULT NULL) RETURN CLOB;
    FUNCTION render_string(p_template IN CLOB) RETURN CLOB;
    FUNCTION render_partial(p_name IN VARCHAR2) RETURN CLOB;
    FUNCTION render_layout(p_layout_name IN VARCHAR2, p_content IN CLOB) RETURN CLOB;
    PROCEDURE render_to(p_template_name IN VARCHAR2, p_layout IN VARCHAR2 DEFAULT NULL, p_status IN NUMBER DEFAULT 200);
    PROCEDURE render_json(p_json IN CLOB, p_status IN NUMBER DEFAULT 200);
    FUNCTION render_collection(p_cursor IN SYS_REFCURSOR, p_item_template IN VARCHAR2, p_columns IN VARCHAR2, p_separator IN VARCHAR2 DEFAULT '') RETURN CLOB;
    FUNCTION stylesheet_tag(p_path IN VARCHAR2) RETURN VARCHAR2;
    FUNCTION javascript_tag(p_path IN VARCHAR2) RETURN VARCHAR2;
    FUNCTION image_tag(p_path IN VARCHAR2, p_alt IN VARCHAR2 DEFAULT '') RETURN VARCHAR2;
    FUNCTION time_ago(p_timestamp IN TIMESTAMP) RETURN VARCHAR2;
    FUNCTION apply_filter(p_value IN VARCHAR2, p_filter IN VARCHAR2) RETURN VARCHAR2;
END hinoki_view;
/

CREATE OR REPLACE PACKAGE BODY hinoki_view AS

    c_coll_prefix CONSTANT VARCHAR2(10) := '_c:';

    -- ========== 変数操作 ==========
    PROCEDURE assign(p_key IN VARCHAR2, p_value IN VARCHAR2) IS
    BEGIN g_vars(p_key) := p_value; END;
    PROCEDURE assign(p_key IN VARCHAR2, p_value IN NUMBER) IS
    BEGIN g_vars(p_key) := TO_CHAR(p_value); END;
    PROCEDURE assign(p_key IN VARCHAR2, p_value IN DATE) IS
    BEGIN g_vars(p_key) := TO_CHAR(p_value, 'YYYY-MM-DD HH24:MI:SS'); END;
    PROCEDURE assign_raw(p_key IN VARCHAR2, p_value IN CLOB) IS
    BEGIN g_vars(p_key) := DBMS_LOB.SUBSTR(p_value, 32767, 1); END;
    PROCEDURE clear_vars IS BEGIN g_vars.DELETE; END;

    -- ========== コレクション (JSON) ==========

    FUNCTION cursor_to_json_internal(p_cursor IN SYS_REFCURSOR) RETURN CLOB IS
        v_json CLOB := '['; v_cid NUMBER; v_cols DBMS_SQL.desc_tab;
        v_cnt NUMBER; v_val VARCHAR2(32767); v_first BOOLEAN := TRUE;
    BEGIN
        v_cid := DBMS_SQL.to_cursor_number(p_cursor);
        DBMS_SQL.describe_columns(v_cid, v_cnt, v_cols);
        FOR i IN 1..v_cnt LOOP DBMS_SQL.define_column(v_cid, i, v_val, 32767); END LOOP;
        LOOP
            EXIT WHEN DBMS_SQL.fetch_rows(v_cid) = 0;
            IF NOT v_first THEN v_json := v_json || ','; END IF; v_first := FALSE;
            v_json := v_json || '{';
            FOR i IN 1..v_cnt LOOP
                DBMS_SQL.column_value(v_cid, i, v_val);
                IF i > 1 THEN v_json := v_json || ','; END IF;
                v_json := v_json || '"' || LOWER(v_cols(i).col_name) || '":' || hinoki_core.to_json_value(v_val);
            END LOOP;
            v_json := v_json || '}';
        END LOOP;
        DBMS_SQL.close_cursor(v_cid);
        RETURN v_json || ']';
    EXCEPTION WHEN OTHERS THEN
        IF DBMS_SQL.is_open(v_cid) THEN DBMS_SQL.close_cursor(v_cid); END IF; RAISE;
    END;

    PROCEDURE assign_collection(p_key IN VARCHAR2, p_cursor IN SYS_REFCURSOR) IS
    BEGIN g_vars(c_coll_prefix || p_key) := DBMS_LOB.SUBSTR(cursor_to_json_internal(p_cursor), 32767, 1); END;

    PROCEDURE assign_collection_json(p_key IN VARCHAR2, p_json IN CLOB) IS
    BEGIN g_vars(c_coll_prefix || p_key) := DBMS_LOB.SUBSTR(p_json, 32767, 1); END;

    -- ========== テンプレート管理 ==========
    PROCEDURE save_template(p_name IN VARCHAR2, p_content IN CLOB, p_layout IN VARCHAR2 DEFAULT 'application') IS
    BEGIN
        MERGE INTO hinoki_views v USING (SELECT p_name AS name FROM dual) s ON (v.name = s.name)
        WHEN MATCHED THEN UPDATE SET content = p_content, layout = p_layout, updated_at = SYSTIMESTAMP
        WHEN NOT MATCHED THEN INSERT (name, content, layout) VALUES (p_name, p_content, p_layout);
        COMMIT;
    END;

    FUNCTION load_template(p_name IN VARCHAR2) RETURN CLOB IS v_c CLOB;
    BEGIN SELECT content INTO v_c FROM hinoki_views WHERE name = p_name; RETURN v_c;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN '<div class="hinoki-error">Template not found: '||hinoki_core.h(p_name)||'</div>'; END;

    FUNCTION template_exists(p_name IN VARCHAR2) RETURN BOOLEAN IS v_n NUMBER;
    BEGIN SELECT COUNT(*) INTO v_n FROM hinoki_views WHERE name = p_name; RETURN v_n > 0; END;

    -- ========== 変数展開 ==========
    FUNCTION expand_variables(p_template IN CLOB) RETURN CLOB IS
        v_result CLOB := p_template; v_key VARCHAR2(200); v_value VARCHAR2(32767);
    BEGIN
        v_key := g_vars.FIRST;
        WHILE v_key IS NOT NULL LOOP
            IF v_key NOT LIKE c_coll_prefix||'%' THEN
                v_result := REPLACE(v_result, '{{{ '||v_key||' }}}', g_vars(v_key));
                v_result := REPLACE(v_result, '{{{'||v_key||'}}}', g_vars(v_key));
            END IF; v_key := g_vars.NEXT(v_key);
        END LOOP;
        v_key := g_vars.FIRST;
        WHILE v_key IS NOT NULL LOOP
            IF v_key NOT LIKE c_coll_prefix||'%' THEN
                v_value := hinoki_core.h(g_vars(v_key));
                v_result := REPLACE(v_result, '{{ '||v_key||' }}', v_value);
                v_result := REPLACE(v_result, '{{'||v_key||'}}', v_value);
            END IF; v_key := g_vars.NEXT(v_key);
        END LOOP;
        RETURN v_result;
    END;

    -- ========== {% if %} ==========
    FUNCTION process_conditionals(p_template IN CLOB) RETURN CLOB IS
        v_result CLOB := p_template; v_start NUMBER; v_end NUMBER;
        v_var VARCHAR2(200); v_block CLOB; v_else NUMBER;
        v_val VARCHAR2(32767); v_is_true BOOLEAN;
    BEGIN
        LOOP
            v_start := INSTR(v_result, '{% if '); EXIT WHEN v_start = 0;
            v_var := TRIM(SUBSTR(v_result, v_start+6, INSTR(v_result,' %}',v_start)-v_start-6));
            v_end := INSTR(v_result, '{% endif %}', v_start); IF v_end=0 THEN EXIT; END IF;
            v_block := SUBSTR(v_result, INSTR(v_result,' %}',v_start)+3, v_end-INSTR(v_result,' %}',v_start)-3);
            v_is_true := FALSE;
            IF g_vars.EXISTS(v_var) THEN
                v_val := g_vars(v_var);
                v_is_true := v_val IS NOT NULL AND v_val!='0' AND LOWER(v_val)!='false' AND v_val!='';
            END IF;
            v_else := INSTR(v_block, '{% else %}');
            IF v_is_true THEN
                IF v_else>0 THEN v_block := SUBSTR(v_block,1,v_else-1); END IF;
            ELSE
                IF v_else>0 THEN v_block := SUBSTR(v_block, v_else+10); ELSE v_block := ''; END IF;
            END IF;
            v_result := SUBSTR(v_result,1,v_start-1)||v_block||SUBSTR(v_result,v_end+12);
        END LOOP;
        RETURN v_result;
    END;

    -- ========== {% for item in collection %} ==========
    FUNCTION process_for_loops(p_template IN CLOB) RETURN CLOB IS
        v_result    CLOB := p_template;
        v_start     NUMBER;
        v_tag_end   NUMBER;
        v_end       NUMBER;
        v_tag       VARCHAR2(500);
        v_item      VARCHAR2(200);
        v_coll      VARCHAR2(200);
        v_block     CLOB;
        v_json      CLOB;
        v_expanded  CLOB;
        v_row_html  CLOB;
        v_in_pos    NUMBER;
        v_arr_len   NUMBER;
        v_idx       NUMBER;
        v_idx_str   VARCHAR2(20);
        v_scan      NUMBER;
        v_rs        NUMBER;
        v_re        NUMBER;
        v_expr      VARCHAR2(500);
        v_field     VARCHAR2(200);
        v_filter    VARCHAR2(200);
        v_dot       NUMBER;
        v_pipe      NUMBER;
        v_val       VARCHAR2(32767);
    BEGIN
        LOOP
            v_start := INSTR(v_result, '{% for '); EXIT WHEN v_start = 0;
            v_tag_end := INSTR(v_result, ' %}', v_start); IF v_tag_end = 0 THEN EXIT; END IF;
            v_tag := TRIM(SUBSTR(v_result, v_start+7, v_tag_end-v_start-7));
            v_in_pos := INSTR(v_tag, ' in '); IF v_in_pos = 0 THEN EXIT; END IF;
            v_item := TRIM(SUBSTR(v_tag, 1, v_in_pos-1));
            v_coll := TRIM(SUBSTR(v_tag, v_in_pos+4));
            v_end := INSTR(v_result, '{% endfor %}', v_start); IF v_end = 0 THEN EXIT; END IF;
            v_block := SUBSTR(v_result, v_tag_end+3, v_end-v_tag_end-3);

            -- JSON取得
            IF g_vars.EXISTS(c_coll_prefix||v_coll) THEN v_json := g_vars(c_coll_prefix||v_coll);
            ELSIF g_vars.EXISTS(v_coll) THEN v_json := g_vars(v_coll);
            ELSE v_json := '[]'; END IF;

            -- 配列長
            BEGIN
                SELECT COUNT(*) INTO v_arr_len FROM JSON_TABLE(v_json, '$[*]' COLUMNS (d VARCHAR2(1) PATH '$'));
            EXCEPTION WHEN OTHERS THEN v_arr_len := 0; END;

            v_expanded := '';
            FOR v_idx IN 0..(v_arr_len-1) LOOP
                v_row_html := v_block;
                v_idx_str := TO_CHAR(v_idx);

                -- ループヘルパー変数
                g_vars(v_item||'._index')  := TO_CHAR(v_idx);
                g_vars(v_item||'._number') := TO_CHAR(v_idx+1);
                g_vars(v_item||'._first')  := CASE WHEN v_idx=0 THEN '1' ELSE '0' END;
                g_vars(v_item||'._last')   := CASE WHEN v_idx=v_arr_len-1 THEN '1' ELSE '0' END;

                -- 1) ブロック内の item.field をすべて g_vars にセット ({% if %} 用)
                v_scan := 1;
                LOOP
                    v_rs := REGEXP_INSTR(v_row_html, v_item||'\.(\w+)', v_scan);
                    EXIT WHEN v_rs = 0;
                    v_field := REGEXP_SUBSTR(v_row_html, v_item||'\.(\w+)', v_scan, 1, NULL, 1);
                    IF v_field IS NOT NULL AND v_field NOT LIKE '\_%' ESCAPE '\' THEN
                        BEGIN
                            SELECT JSON_VALUE(v_json, '$['||v_idx_str||'].'||v_field) INTO v_val FROM dual;
                        EXCEPTION WHEN OTHERS THEN v_val := NULL; END;
                        g_vars(v_item||'.'||v_field) := v_val;
                    END IF;
                    v_scan := v_rs + LENGTH(v_item) + 1;
                END LOOP;

                -- 2) {% if item.field %} を処理
                v_row_html := process_conditionals(v_row_html);

                -- 3) {{{ item.field | filter }}} (raw) を展開
                v_scan := 1;
                LOOP
                    v_rs := INSTR(v_row_html, '{{{ '||v_item||'.', v_scan);
                    IF v_rs = 0 THEN v_rs := INSTR(v_row_html, '{{{'||v_item||'.', v_scan); END IF;
                    EXIT WHEN v_rs = 0;
                    v_re := INSTR(v_row_html, '}}}', v_rs); IF v_re = 0 THEN EXIT; END IF;
                    v_expr := TRIM(REPLACE(SUBSTR(v_row_html, v_rs+3, v_re-v_rs-3), '{', ''));
                    v_dot := INSTR(v_expr, '.'); v_pipe := INSTR(v_expr, '|', v_dot);
                    IF v_pipe > 0 THEN
                        v_field := TRIM(SUBSTR(v_expr, v_dot+1, v_pipe-v_dot-1));
                        v_filter := TRIM(SUBSTR(v_expr, v_pipe+1));
                    ELSE v_field := TRIM(SUBSTR(v_expr, v_dot+1)); v_filter := NULL; END IF;
                    BEGIN SELECT JSON_VALUE(v_json,'$['||v_idx_str||'].'||v_field) INTO v_val FROM dual;
                    EXCEPTION WHEN OTHERS THEN v_val := ''; END;
                    IF v_filter IS NOT NULL AND v_val IS NOT NULL THEN v_val := apply_filter(v_val, v_filter); END IF;
                    v_row_html := SUBSTR(v_row_html,1,v_rs-1)||NVL(v_val,'')||SUBSTR(v_row_html,v_re+3);
                    v_scan := v_rs + NVL(LENGTH(v_val),0);
                END LOOP;

                -- 4) {{ item.field | filter }} (escaped) を展開
                v_scan := 1;
                LOOP
                    v_rs := INSTR(v_row_html, '{{ '||v_item||'.', v_scan);
                    IF v_rs = 0 THEN v_rs := INSTR(v_row_html, '{{'||v_item||'.', v_scan); END IF;
                    EXIT WHEN v_rs = 0;
                    v_re := INSTR(v_row_html, '}}', v_rs); IF v_re = 0 THEN EXIT; END IF;
                    v_expr := TRIM(REPLACE(SUBSTR(v_row_html, v_rs+2, v_re-v_rs-2), '{', ''));
                    v_dot := INSTR(v_expr, '.'); v_pipe := INSTR(v_expr, '|', v_dot);
                    IF v_pipe > 0 THEN
                        v_field := TRIM(SUBSTR(v_expr, v_dot+1, v_pipe-v_dot-1));
                        v_filter := TRIM(SUBSTR(v_expr, v_pipe+1));
                    ELSE v_field := TRIM(SUBSTR(v_expr, v_dot+1)); v_filter := NULL; END IF;
                    BEGIN SELECT JSON_VALUE(v_json,'$['||v_idx_str||'].'||v_field) INTO v_val FROM dual;
                    EXCEPTION WHEN OTHERS THEN v_val := ''; END;
                    IF v_filter IS NOT NULL AND v_val IS NOT NULL THEN v_val := apply_filter(v_val, v_filter); END IF;
                    v_row_html := SUBSTR(v_row_html,1,v_rs-1)||hinoki_core.h(NVL(v_val,''))||SUBSTR(v_row_html,v_re+2);
                    v_scan := v_rs + NVL(LENGTH(v_val),0);
                END LOOP;

                v_expanded := v_expanded || v_row_html;

                -- item.xxx 一時変数クリア
                DECLARE v_k VARCHAR2(200) := g_vars.FIRST; v_pfx VARCHAR2(210) := v_item||'.';
                BEGIN WHILE v_k IS NOT NULL LOOP
                    IF v_k LIKE v_pfx||'%' THEN g_vars.DELETE(v_k); END IF;
                    v_k := g_vars.NEXT(v_k);
                END LOOP; END;
            END LOOP;

            v_result := SUBSTR(v_result,1,v_start-1)||v_expanded||SUBSTR(v_result,v_end+12);
        END LOOP;
        RETURN v_result;
    END process_for_loops;

    -- ========== フィルター ==========
    FUNCTION apply_filter(p_value IN VARCHAR2, p_filter IN VARCHAR2) RETURN VARCHAR2 IS
        v_f VARCHAR2(200) := LOWER(TRIM(p_filter)); v_arg VARCHAR2(200); v_sp NUMBER;
    BEGIN
        v_sp := INSTR(v_f, ' ');
        IF v_sp > 0 THEN v_arg := TRIM(BOTH '"' FROM TRIM(BOTH '''' FROM TRIM(SUBSTR(v_f, v_sp+1)))); v_f := SUBSTR(v_f,1,v_sp-1); END IF;
        CASE v_f
            WHEN 'upcase' THEN RETURN UPPER(p_value);
            WHEN 'downcase' THEN RETURN LOWER(p_value);
            WHEN 'capitalize' THEN RETURN INITCAP(p_value);
            WHEN 'h' THEN RETURN hinoki_core.h(p_value);
            WHEN 'truncate' THEN
                IF v_arg IS NOT NULL THEN
                    DECLARE v_len NUMBER := TO_NUMBER(v_arg);
                    BEGIN IF LENGTH(p_value)>v_len THEN RETURN SUBSTR(p_value,1,v_len)||'...'; END IF; END;
                END IF; RETURN p_value;
            WHEN 'default' THEN
                IF p_value IS NULL OR p_value='' THEN RETURN NVL(v_arg,''); END IF; RETURN p_value;
            WHEN 'time_ago' THEN
                BEGIN RETURN time_ago(TO_TIMESTAMP(p_value,'YYYY-MM-DD HH24:MI:SS'));
                EXCEPTION WHEN OTHERS THEN RETURN p_value; END;
            WHEN 'number_format' THEN
                BEGIN RETURN TO_CHAR(TO_NUMBER(p_value),'FM999,999,999,990');
                EXCEPTION WHEN OTHERS THEN RETURN p_value; END;
            WHEN 'strip_tags' THEN RETURN REGEXP_REPLACE(p_value, '<[^>]*>', '');
            ELSE RETURN p_value;
        END CASE;
    END;

    -- ========== partials ==========
    FUNCTION process_partials(p_template IN CLOB) RETURN CLOB IS
        v_result CLOB := p_template; v_start NUMBER; v_end NUMBER; v_name VARCHAR2(500);
    BEGIN
        LOOP v_start := INSTR(v_result, '{% partial "'); EXIT WHEN v_start=0;
            v_end := INSTR(v_result, '" %}', v_start); IF v_end=0 THEN EXIT; END IF;
            v_name := SUBSTR(v_result, v_start+12, v_end-v_start-12);
            v_result := SUBSTR(v_result,1,v_start-1)||render_string(load_template('_'||v_name))||SUBSTR(v_result,v_end+4);
        END LOOP; RETURN v_result;
    END;

    -- ========== レンダリングパイプライン ==========
    FUNCTION render_string(p_template IN CLOB) RETURN CLOB IS v_r CLOB;
    BEGIN v_r := p_template; v_r := process_for_loops(v_r); v_r := process_conditionals(v_r);
        v_r := process_partials(v_r); v_r := expand_variables(v_r); RETURN v_r; END;

    FUNCTION render_partial(p_name IN VARCHAR2) RETURN CLOB IS
    BEGIN RETURN render_string(load_template('_'||p_name)); END;

    FUNCTION render_layout(p_layout_name IN VARCHAR2, p_content IN CLOB) RETURN CLOB IS v_l CLOB;
    BEGIN v_l := load_template('layouts/'||p_layout_name);
        v_l := REPLACE(v_l, '{% yield %}', p_content); v_l := REPLACE(v_l, '{%yield%}', p_content);
        RETURN render_string(v_l); END;

    FUNCTION render(p_template_name IN VARCHAR2, p_layout IN VARCHAR2 DEFAULT NULL) RETURN CLOB IS
        v_c CLOB; v_l VARCHAR2(200); v_r CLOB;
    BEGIN
        assign_raw('flash', hinoki_core.flash_html);
        v_c := render_string(load_template(p_template_name));
        v_l := NVL(p_layout, hinoki_core.config('view.layout'));
        IF v_l IS NOT NULL AND template_exists('layouts/'||v_l) THEN v_r := render_layout(v_l, v_c);
        ELSE v_r := v_c; END IF;
        clear_vars; RETURN v_r;
    END;

    PROCEDURE render_to(p_template_name IN VARCHAR2, p_layout IN VARCHAR2 DEFAULT NULL, p_status IN NUMBER DEFAULT 200) IS
    BEGIN hinoki_core.respond(render(p_template_name, p_layout), p_status); END;

    PROCEDURE render_json(p_json IN CLOB, p_status IN NUMBER DEFAULT 200) IS
    BEGIN hinoki_core.respond_json(p_json, p_status); END;

    -- ========== render_collection (旧API互換) ==========
    FUNCTION render_collection(p_cursor IN SYS_REFCURSOR, p_item_template IN VARCHAR2,
        p_columns IN VARCHAR2, p_separator IN VARCHAR2 DEFAULT '') RETURN CLOB IS
        v_result CLOB:=''; v_cols DBMS_SQL.desc_tab; v_cnt NUMBER; v_cid NUMBER; v_v VARCHAR2(32767);
        TYPE t_n IS TABLE OF VARCHAR2(200) INDEX BY PLS_INTEGER; v_names t_n;
        v_idx PLS_INTEGER:=0; v_pos PLS_INTEGER; v_str VARCHAR2(4000):=p_columns; v_first BOOLEAN:=TRUE;
    BEGIN
        LOOP v_idx:=v_idx+1; v_pos:=INSTR(v_str,',');
            IF v_pos>0 THEN v_names(v_idx):=TRIM(SUBSTR(v_str,1,v_pos-1)); v_str:=SUBSTR(v_str,v_pos+1);
            ELSE v_names(v_idx):=TRIM(v_str); EXIT; END IF; END LOOP;
        v_cid:=DBMS_SQL.to_cursor_number(p_cursor); DBMS_SQL.describe_columns(v_cid,v_cnt,v_cols);
        FOR i IN 1..v_cnt LOOP DBMS_SQL.define_column(v_cid,i,v_v,32767); END LOOP;
        LOOP EXIT WHEN DBMS_SQL.fetch_rows(v_cid)=0;
            FOR i IN 1..LEAST(v_cnt,v_names.COUNT) LOOP DBMS_SQL.column_value(v_cid,i,v_v); g_vars(v_names(i)):=v_v; END LOOP;
            IF NOT v_first AND p_separator IS NOT NULL THEN v_result:=v_result||p_separator; END IF; v_first:=FALSE;
            v_result:=v_result||render_string(load_template(p_item_template));
        END LOOP;
        DBMS_SQL.close_cursor(v_cid); RETURN v_result;
    EXCEPTION WHEN OTHERS THEN IF DBMS_SQL.is_open(v_cid) THEN DBMS_SQL.close_cursor(v_cid); END IF; RAISE;
    END;

    -- ========== ヘルパー ==========
    FUNCTION stylesheet_tag(p_path IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN RETURN '<link rel="stylesheet" href="'||hinoki_core.h(p_path)||'">'; END;
    FUNCTION javascript_tag(p_path IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN RETURN '<script src="'||hinoki_core.h(p_path)||'"></script>'; END;
    FUNCTION image_tag(p_path IN VARCHAR2, p_alt IN VARCHAR2 DEFAULT '') RETURN VARCHAR2 IS
    BEGIN RETURN '<img src="'||hinoki_core.h(p_path)||'" alt="'||hinoki_core.h(p_alt)||'">'; END;
    FUNCTION time_ago(p_timestamp IN TIMESTAMP) RETURN VARCHAR2 IS
        v_d INTERVAL DAY(9) TO SECOND; v_days NUMBER; v_hrs NUMBER; v_min NUMBER;
    BEGIN v_d:=SYSTIMESTAMP-p_timestamp; v_days:=EXTRACT(DAY FROM v_d); v_hrs:=EXTRACT(HOUR FROM v_d); v_min:=EXTRACT(MINUTE FROM v_d);
        IF v_days>365 THEN RETURN TRUNC(v_days/365)||'年前'; ELSIF v_days>30 THEN RETURN TRUNC(v_days/30)||'ヶ月前';
        ELSIF v_days>0 THEN RETURN v_days||'日前'; ELSIF v_hrs>0 THEN RETURN v_hrs||'時間前';
        ELSIF v_min>0 THEN RETURN v_min||'分前'; ELSE RETURN 'たった今'; END IF; END;

END hinoki_view;
/

PROMPT  ✓ hinoki_view installed (with {% for %} and filters)
