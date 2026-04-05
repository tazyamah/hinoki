-- ============================================================
-- HINOKI_CORE: フレームワークの基盤ユーティリティ
-- リクエスト/レスポンス、セッション、JSON、設定管理
-- ============================================================

CREATE OR REPLACE PACKAGE hinoki_core AS

    -- ========== 型定義 ==========
    TYPE t_param IS RECORD (
        name  VARCHAR2(500),
        value VARCHAR2(32767)
    );
    TYPE t_params IS TABLE OF t_param INDEX BY PLS_INTEGER;

    TYPE t_header IS RECORD (
        name  VARCHAR2(500),
        value VARCHAR2(32767)
    );
    TYPE t_headers IS TABLE OF t_header INDEX BY PLS_INTEGER;

    -- レスポンス構造体
    TYPE t_response IS RECORD (
        status_code  NUMBER DEFAULT 200,
        content_type VARCHAR2(200) DEFAULT 'text/html; charset=utf-8',
        body         CLOB,
        headers      t_headers,
        redirect_url VARCHAR2(4000)
    );

    -- Flash メッセージ種別
    SUBTYPE t_flash_type IS VARCHAR2(20);
    c_flash_notice  CONSTANT t_flash_type := 'notice';
    c_flash_alert   CONSTANT t_flash_type := 'alert';
    c_flash_error   CONSTANT t_flash_type := 'error';
    c_flash_success CONSTANT t_flash_type := 'success';

    -- ========== 設定 ==========
    FUNCTION config(p_key IN VARCHAR2) RETURN VARCHAR2;
    PROCEDURE set_config(p_key IN VARCHAR2, p_value IN VARCHAR2);

    -- ========== リクエストヘルパー ==========
    FUNCTION request_method RETURN VARCHAR2;
    FUNCTION request_path RETURN VARCHAR2;
    FUNCTION param(p_name IN VARCHAR2) RETURN VARCHAR2;
    FUNCTION param_int(p_name IN VARCHAR2) RETURN NUMBER;
    FUNCTION param_clob(p_name IN VARCHAR2) RETURN CLOB;
    FUNCTION header(p_name IN VARCHAR2) RETURN VARCHAR2;
    FUNCTION content_type RETURN VARCHAR2;
    FUNCTION is_json_request RETURN BOOLEAN;

    -- ========== レスポンスヘルパー ==========
    PROCEDURE respond(p_body IN CLOB, p_status IN NUMBER DEFAULT 200,
                      p_content_type IN VARCHAR2 DEFAULT 'text/html; charset=utf-8');
    PROCEDURE respond_json(p_json IN CLOB, p_status IN NUMBER DEFAULT 200);
    PROCEDURE redirect(p_url IN VARCHAR2, p_status IN NUMBER DEFAULT 302);
    PROCEDURE respond_404(p_message IN VARCHAR2 DEFAULT 'Not Found');
    PROCEDURE respond_500(p_message IN VARCHAR2 DEFAULT 'Internal Server Error');
    PROCEDURE set_header(p_name IN VARCHAR2, p_value IN VARCHAR2);
    PROCEDURE set_cookie(p_name IN VARCHAR2, p_value IN VARCHAR2,
                         p_max_age IN NUMBER DEFAULT 86400,
                         p_path IN VARCHAR2 DEFAULT '/');

    -- ========== セッション ==========
    FUNCTION session_id RETURN VARCHAR2;
    FUNCTION session_get(p_key IN VARCHAR2) RETURN VARCHAR2;
    PROCEDURE session_set(p_key IN VARCHAR2, p_value IN VARCHAR2);
    PROCEDURE session_destroy;

    -- ========== Flash メッセージ ==========
    PROCEDURE flash(p_type IN t_flash_type, p_message IN VARCHAR2);
    FUNCTION flash_get(p_type IN t_flash_type) RETURN VARCHAR2;
    FUNCTION flash_html RETURN VARCHAR2;

    -- ========== JSON ユーティリティ ==========
    FUNCTION to_json_value(p_value IN VARCHAR2) RETURN VARCHAR2;
    FUNCTION to_json_value(p_value IN NUMBER) RETURN VARCHAR2;
    FUNCTION to_json_value(p_value IN DATE) RETURN VARCHAR2;
    FUNCTION to_json_value(p_value IN TIMESTAMP) RETURN VARCHAR2;
    FUNCTION json_obj_open RETURN VARCHAR2;
    FUNCTION json_obj_close RETURN VARCHAR2;
    FUNCTION json_arr_open RETURN VARCHAR2;
    FUNCTION json_arr_close RETURN VARCHAR2;
    FUNCTION json_kv(p_key IN VARCHAR2, p_value IN VARCHAR2,
                     p_comma IN BOOLEAN DEFAULT TRUE) RETURN VARCHAR2;
    FUNCTION json_kv(p_key IN VARCHAR2, p_value IN NUMBER,
                     p_comma IN BOOLEAN DEFAULT TRUE) RETURN VARCHAR2;

    -- ========== HTML ユーティリティ ==========
    FUNCTION h(p_text IN VARCHAR2) RETURN VARCHAR2;  -- HTMLエスケープ
    FUNCTION link_to(p_text IN VARCHAR2, p_url IN VARCHAR2,
                     p_class IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;
    FUNCTION form_tag(p_action IN VARCHAR2, p_method IN VARCHAR2 DEFAULT 'POST') RETURN VARCHAR2;
    FUNCTION form_end RETURN VARCHAR2;
    FUNCTION text_field(p_name IN VARCHAR2, p_value IN VARCHAR2 DEFAULT NULL,
                        p_label IN VARCHAR2 DEFAULT NULL,
                        p_class IN VARCHAR2 DEFAULT 'hinoki-input') RETURN VARCHAR2;
    FUNCTION text_area(p_name IN VARCHAR2, p_value IN VARCHAR2 DEFAULT NULL,
                       p_label IN VARCHAR2 DEFAULT NULL,
                       p_rows IN NUMBER DEFAULT 5) RETURN VARCHAR2;
    FUNCTION submit_button(p_text IN VARCHAR2 DEFAULT 'Save',
                           p_class IN VARCHAR2 DEFAULT 'hinoki-btn') RETURN VARCHAR2;
    FUNCTION csrf_token RETURN VARCHAR2;
    FUNCTION csrf_field RETURN VARCHAR2;

    -- ========== ログ ==========
    PROCEDURE log_info(p_message IN VARCHAR2);
    PROCEDURE log_error(p_message IN VARCHAR2);
    PROCEDURE log_debug(p_message IN VARCHAR2);

    -- ========== 内部 ==========
    FUNCTION generate_id RETURN VARCHAR2;

END hinoki_core;
/

CREATE OR REPLACE PACKAGE BODY hinoki_core AS

    -- プライベート変数
    g_response_headers t_headers;
    g_header_count     PLS_INTEGER := 0;
    g_session_id       VARCHAR2(128);
    g_session_loaded   BOOLEAN := FALSE;

    -- ========== 設定 ==========

    FUNCTION config(p_key IN VARCHAR2) RETURN VARCHAR2 IS
        v_value VARCHAR2(4000);
    BEGIN
        SELECT value INTO v_value
        FROM hinoki_config WHERE key = p_key;
        RETURN v_value;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        RETURN NULL;
    END config;

    PROCEDURE set_config(p_key IN VARCHAR2, p_value IN VARCHAR2) IS
    BEGIN
        MERGE INTO hinoki_config c
        USING (SELECT p_key AS key FROM dual) s ON (c.key = s.key)
        WHEN MATCHED THEN UPDATE SET value = p_value, updated_at = SYSTIMESTAMP
        WHEN NOT MATCHED THEN INSERT (key, value) VALUES (p_key, p_value);
        COMMIT;
    END set_config;

    -- ========== リクエストヘルパー ==========

    FUNCTION request_method RETURN VARCHAR2 IS
    BEGIN
        RETURN OWA_UTIL.get_cgi_env('REQUEST_METHOD');
    EXCEPTION WHEN OTHERS THEN
        RETURN NVL(OWA_UTIL.get_cgi_env('X-ORDS-METHOD'), 'GET');
    END request_method;

    FUNCTION request_path RETURN VARCHAR2 IS
    BEGIN
        RETURN OWA_UTIL.get_cgi_env('PATH_INFO');
    EXCEPTION WHEN OTHERS THEN
        RETURN '/';
    END request_path;

    FUNCTION param(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN OWA_UTIL.get_cgi_env(p_name);
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END param;

    FUNCTION param_int(p_name IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        RETURN TO_NUMBER(param(p_name));
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END param_int;

    FUNCTION param_clob(p_name IN VARCHAR2) RETURN CLOB IS
    BEGIN
        RETURN TO_CLOB(param(p_name));
    END param_clob;

    FUNCTION header(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN OWA_UTIL.get_cgi_env('HTTP_' || UPPER(REPLACE(p_name, '-', '_')));
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END header;

    FUNCTION content_type RETURN VARCHAR2 IS
    BEGIN
        RETURN OWA_UTIL.get_cgi_env('CONTENT_TYPE');
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END content_type;

    FUNCTION is_json_request RETURN BOOLEAN IS
    BEGIN
        RETURN INSTR(NVL(content_type, ''), 'application/json') > 0;
    END is_json_request;

    -- ========== レスポンスヘルパー ==========

    PROCEDURE respond(p_body IN CLOB, p_status IN NUMBER DEFAULT 200,
                      p_content_type IN VARCHAR2 DEFAULT 'text/html; charset=utf-8') IS
    BEGIN
        OWA_UTIL.status_line(p_status);
        OWA_UTIL.mime_header(p_content_type, FALSE);
        -- カスタムヘッダー出力
        FOR i IN 1..g_header_count LOOP
            OWA_UTIL.http_header_close;
        END LOOP;
        OWA_UTIL.http_header_close;
        HTP.prn(p_body);
    EXCEPTION WHEN OTHERS THEN
        -- ORDSコンテキスト外ではDBMS_OUTPUTにフォールバック
        DBMS_OUTPUT.put_line('Status: ' || p_status);
        DBMS_OUTPUT.put_line('Content-Type: ' || p_content_type);
        DBMS_OUTPUT.put_line('');
        DBMS_OUTPUT.put_line(DBMS_LOB.SUBSTR(p_body, 4000, 1));
    END respond;

    PROCEDURE respond_json(p_json IN CLOB, p_status IN NUMBER DEFAULT 200) IS
    BEGIN
        respond(p_json, p_status, 'application/json; charset=utf-8');
    END respond_json;

    PROCEDURE redirect(p_url IN VARCHAR2, p_status IN NUMBER DEFAULT 302) IS
    BEGIN
        OWA_UTIL.status_line(p_status);
        OWA_UTIL.redirect_url(p_url);
    EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.put_line('Redirect: ' || p_url);
    END redirect;

    PROCEDURE respond_404(p_message IN VARCHAR2 DEFAULT 'Not Found') IS
        v_html CLOB;
    BEGIN
        v_html := '<!DOCTYPE html><html><head><title>404</title>'
            || '<style>body{font-family:sans-serif;display:flex;justify-content:center;'
            || 'align-items:center;height:100vh;margin:0;background:#f8f9fa;}'
            || '.c{text-align:center}h1{font-size:6em;margin:0;color:#2d5016}'
            || 'p{color:#666;font-size:1.2em}</style></head>'
            || '<body><div class="c"><h1>404</h1><p>' || h(p_message) || '</p>'
            || '<p><a href="/">🌲 Back to Home</a></p></div></body></html>';
        respond(v_html, 404);
    END respond_404;

    PROCEDURE respond_500(p_message IN VARCHAR2 DEFAULT 'Internal Server Error') IS
        v_html CLOB;
    BEGIN
        v_html := '<!DOCTYPE html><html><head><title>500</title>'
            || '<style>body{font-family:monospace;padding:2em;background:#1a1a2e;color:#e94560}'
            || 'pre{background:#16213e;padding:1em;border-radius:8px;color:#eee}</style></head>'
            || '<body><h1>🌲 Hinoki - Error 500</h1><pre>' || h(p_message) || '</pre></body></html>';
        respond(v_html, 500);
    END respond_500;

    PROCEDURE set_header(p_name IN VARCHAR2, p_value IN VARCHAR2) IS
    BEGIN
        g_header_count := g_header_count + 1;
        g_response_headers(g_header_count).name := p_name;
        g_response_headers(g_header_count).value := p_value;
    END set_header;

    PROCEDURE set_cookie(p_name IN VARCHAR2, p_value IN VARCHAR2,
                         p_max_age IN NUMBER DEFAULT 86400,
                         p_path IN VARCHAR2 DEFAULT '/') IS
    BEGIN
        set_header('Set-Cookie',
            p_name || '=' || p_value
            || '; Path=' || p_path
            || '; Max-Age=' || p_max_age
            || '; HttpOnly; SameSite=Lax');
    END set_cookie;

    -- ========== セッション ==========

    FUNCTION session_id RETURN VARCHAR2 IS
    BEGIN
        IF g_session_id IS NULL THEN
            g_session_id := header('Cookie');
            IF g_session_id IS NOT NULL THEN
                -- hinoki_sid=xxx を抽出
                g_session_id := REGEXP_SUBSTR(g_session_id, 'hinoki_sid=([^;]+)', 1, 1, NULL, 1);
            END IF;
            IF g_session_id IS NULL THEN
                g_session_id := generate_id;
                set_cookie('hinoki_sid', g_session_id);
                INSERT INTO hinoki_sessions (session_id) VALUES (g_session_id);
                COMMIT;
            END IF;
        END IF;
        RETURN g_session_id;
    END session_id;

    FUNCTION session_get(p_key IN VARCHAR2) RETURN VARCHAR2 IS
        v_data CLOB;
    BEGIN
        SELECT data INTO v_data
        FROM hinoki_sessions
        WHERE session_id = session_id AND expires_at > SYSTIMESTAMP;

        RETURN JSON_VALUE(v_data, '$.' || p_key);
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END session_get;

    PROCEDURE session_set(p_key IN VARCHAR2, p_value IN VARCHAR2) IS
    BEGIN
        UPDATE hinoki_sessions
        SET data = JSON_MERGEPATCH(NVL(data, '{}'),
                    '{"' || REPLACE(p_key, '"', '\"') || '":"'
                         || REPLACE(p_value, '"', '\"') || '"}'),
            updated_at = SYSTIMESTAMP
        WHERE session_id = session_id;
        COMMIT;
    END session_set;

    PROCEDURE session_destroy IS
    BEGIN
        DELETE FROM hinoki_sessions WHERE session_id = g_session_id;
        g_session_id := NULL;
        COMMIT;
    END session_destroy;

    -- ========== Flash メッセージ ==========

    PROCEDURE flash(p_type IN t_flash_type, p_message IN VARCHAR2) IS
    BEGIN
        session_set('_flash_' || p_type, p_message);
    END flash;

    FUNCTION flash_get(p_type IN t_flash_type) RETURN VARCHAR2 IS
        v_msg VARCHAR2(4000);
    BEGIN
        v_msg := session_get('_flash_' || p_type);
        IF v_msg IS NOT NULL THEN
            session_set('_flash_' || p_type, '');
        END IF;
        RETURN v_msg;
    END flash_get;

    FUNCTION flash_html RETURN VARCHAR2 IS
        v_html  VARCHAR2(4000) := '';
        v_msg   VARCHAR2(4000);
        TYPE t_types IS TABLE OF t_flash_type INDEX BY PLS_INTEGER;
        v_types t_types;
        v_colors VARCHAR2(4000);
    BEGIN
        v_types(1) := c_flash_success;
        v_types(2) := c_flash_notice;
        v_types(3) := c_flash_alert;
        v_types(4) := c_flash_error;

        FOR i IN 1..v_types.COUNT LOOP
            v_msg := flash_get(v_types(i));
            IF v_msg IS NOT NULL THEN
                CASE v_types(i)
                    WHEN c_flash_success THEN v_colors := 'background:#d4edda;color:#155724;border-color:#c3e6cb';
                    WHEN c_flash_notice  THEN v_colors := 'background:#d1ecf1;color:#0c5460;border-color:#bee5eb';
                    WHEN c_flash_alert   THEN v_colors := 'background:#fff3cd;color:#856404;border-color:#ffeeba';
                    WHEN c_flash_error   THEN v_colors := 'background:#f8d7da;color:#721c24;border-color:#f5c6cb';
                END CASE;
                v_html := v_html
                    || '<div class="hinoki-flash" style="padding:12px 20px;margin:8px 0;'
                    || 'border-radius:6px;border:1px solid;' || v_colors || '">'
                    || h(v_msg) || '</div>';
            END IF;
        END LOOP;
        RETURN v_html;
    END flash_html;

    -- ========== JSON ユーティリティ ==========

    FUNCTION to_json_value(p_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_value IS NULL THEN RETURN 'null'; END IF;
        RETURN '"' || REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            p_value, '\', '\\'), '"', '\"'), CHR(10), '\n'),
            CHR(13), '\r'), CHR(9), '\t') || '"';
    END to_json_value;

    FUNCTION to_json_value(p_value IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_value IS NULL THEN RETURN 'null'; END IF;
        RETURN TO_CHAR(p_value);
    END to_json_value;

    FUNCTION to_json_value(p_value IN DATE) RETURN VARCHAR2 IS
    BEGIN
        IF p_value IS NULL THEN RETURN 'null'; END IF;
        RETURN '"' || TO_CHAR(p_value, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '"';
    END to_json_value;

    FUNCTION to_json_value(p_value IN TIMESTAMP) RETURN VARCHAR2 IS
    BEGIN
        IF p_value IS NULL THEN RETURN 'null'; END IF;
        RETURN '"' || TO_CHAR(p_value, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '"';
    END to_json_value;

    FUNCTION json_obj_open RETURN VARCHAR2 IS BEGIN RETURN '{'; END;
    FUNCTION json_obj_close RETURN VARCHAR2 IS BEGIN RETURN '}'; END;
    FUNCTION json_arr_open RETURN VARCHAR2 IS BEGIN RETURN '['; END;
    FUNCTION json_arr_close RETURN VARCHAR2 IS BEGIN RETURN ']'; END;

    FUNCTION json_kv(p_key IN VARCHAR2, p_value IN VARCHAR2,
                     p_comma IN BOOLEAN DEFAULT TRUE) RETURN VARCHAR2 IS
    BEGIN
        RETURN '"' || p_key || '":' || to_json_value(p_value)
               || CASE WHEN p_comma THEN ',' ELSE '' END;
    END json_kv;

    FUNCTION json_kv(p_key IN VARCHAR2, p_value IN NUMBER,
                     p_comma IN BOOLEAN DEFAULT TRUE) RETURN VARCHAR2 IS
    BEGIN
        RETURN '"' || p_key || '":' || to_json_value(p_value)
               || CASE WHEN p_comma THEN ',' ELSE '' END;
    END json_kv;

    -- ========== HTML ユーティリティ ==========

    FUNCTION h(p_text IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            p_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
            '"', '&quot;'), '''', '&#39;');
    END h;

    FUNCTION link_to(p_text IN VARCHAR2, p_url IN VARCHAR2,
                     p_class IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<a href="' || h(p_url) || '"'
            || CASE WHEN p_class IS NOT NULL THEN ' class="' || h(p_class) || '"' END
            || '>' || h(p_text) || '</a>';
    END link_to;

    FUNCTION form_tag(p_action IN VARCHAR2, p_method IN VARCHAR2 DEFAULT 'POST') RETURN VARCHAR2 IS
    BEGIN
        RETURN '<form action="' || h(p_action) || '" method="' || h(p_method) || '">'
            || csrf_field;
    END form_tag;

    FUNCTION form_end RETURN VARCHAR2 IS
    BEGIN
        RETURN '</form>';
    END form_end;

    FUNCTION text_field(p_name IN VARCHAR2, p_value IN VARCHAR2 DEFAULT NULL,
                        p_label IN VARCHAR2 DEFAULT NULL,
                        p_class IN VARCHAR2 DEFAULT 'hinoki-input') RETURN VARCHAR2 IS
        v_html VARCHAR2(4000);
        v_lbl  VARCHAR2(200) := NVL(p_label, INITCAP(REPLACE(p_name, '_', ' ')));
    BEGIN
        v_html := '<div class="hinoki-field">'
            || '<label for="' || h(p_name) || '">' || h(v_lbl) || '</label>'
            || '<input type="text" id="' || h(p_name)
            || '" name="' || h(p_name) || '"'
            || ' value="' || h(NVL(p_value, '')) || '"'
            || ' class="' || h(p_class) || '">'
            || '</div>';
        RETURN v_html;
    END text_field;

    FUNCTION text_area(p_name IN VARCHAR2, p_value IN VARCHAR2 DEFAULT NULL,
                       p_label IN VARCHAR2 DEFAULT NULL,
                       p_rows IN NUMBER DEFAULT 5) RETURN VARCHAR2 IS
        v_lbl VARCHAR2(200) := NVL(p_label, INITCAP(REPLACE(p_name, '_', ' ')));
    BEGIN
        RETURN '<div class="hinoki-field">'
            || '<label for="' || h(p_name) || '">' || h(v_lbl) || '</label>'
            || '<textarea id="' || h(p_name) || '" name="' || h(p_name)
            || '" rows="' || p_rows || '" class="hinoki-input">'
            || h(NVL(p_value, ''))
            || '</textarea></div>';
    END text_area;

    FUNCTION submit_button(p_text IN VARCHAR2 DEFAULT 'Save',
                           p_class IN VARCHAR2 DEFAULT 'hinoki-btn') RETURN VARCHAR2 IS
    BEGIN
        RETURN '<button type="submit" class="' || h(p_class) || '">' || h(p_text) || '</button>';
    END submit_button;

    FUNCTION csrf_token RETURN VARCHAR2 IS
    BEGIN
        RETURN DBMS_CRYPTO.HASH(
            UTL_I18N.STRING_TO_RAW(session_id || TO_CHAR(TRUNC(SYSDATE)), 'AL32UTF8'),
            DBMS_CRYPTO.HASH_SH256
        );
    EXCEPTION WHEN OTHERS THEN
        RETURN generate_id;
    END csrf_token;

    FUNCTION csrf_field RETURN VARCHAR2 IS
    BEGIN
        RETURN '<input type="hidden" name="_csrf" value="' || csrf_token || '">';
    END csrf_field;

    -- ========== ログ ==========

    PROCEDURE log_info(p_message IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.put_line('[HINOKI INFO] ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS.FF3') || ' ' || p_message);
    END log_info;

    PROCEDURE log_error(p_message IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.put_line('[HINOKI ERROR] ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS.FF3') || ' ' || p_message);
    END log_error;

    PROCEDURE log_debug(p_message IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.put_line('[HINOKI DEBUG] ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS.FF3') || ' ' || p_message);
    END log_debug;

    -- ========== 内部 ==========

    FUNCTION generate_id RETURN VARCHAR2 IS
    BEGIN
        RETURN LOWER(RAWTOHEX(SYS_GUID()));
    END generate_id;

END hinoki_core;
/

PROMPT  ✓ hinoki_core installed
