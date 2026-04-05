-- ============================================================
-- HINOKI_ROUTER: ルーティングエンジン
-- RESTfulルーティングをORDSモジュールにマッピング
-- ============================================================

CREATE OR REPLACE PACKAGE hinoki_router AS

    -- ========== ルーティングDSL ==========

    -- 個別ルート定義
    PROCEDURE get(p_path IN VARCHAR2, p_controller IN VARCHAR2, p_action IN VARCHAR2);
    PROCEDURE post(p_path IN VARCHAR2, p_controller IN VARCHAR2, p_action IN VARCHAR2);
    PROCEDURE put(p_path IN VARCHAR2, p_controller IN VARCHAR2, p_action IN VARCHAR2);
    PROCEDURE delete_route(p_path IN VARCHAR2, p_controller IN VARCHAR2, p_action IN VARCHAR2);
    PROCEDURE patch(p_path IN VARCHAR2, p_controller IN VARCHAR2, p_action IN VARCHAR2);

    -- RESTful リソース一括定義 (Rails の resources :posts 相当)
    -- GET    /posts          → index
    -- GET    /posts/new      → new_form
    -- POST   /posts          → create_action
    -- GET    /posts/:id      → show
    -- GET    /posts/:id/edit → edit_form
    -- PUT    /posts/:id      → update_action
    -- DELETE /posts/:id      → delete_action
    PROCEDURE resources(p_name IN VARCHAR2, p_controller IN VARCHAR2 DEFAULT NULL);

    -- root パス
    PROCEDURE root(p_controller IN VARCHAR2, p_action IN VARCHAR2);

    -- ========== ORDS連携 ==========

    -- ルートテーブルからORDSモジュールを自動生成
    PROCEDURE deploy_routes(p_module_name IN VARCHAR2 DEFAULT 'hinoki');

    -- ORDSモジュール削除
    PROCEDURE undeploy_routes(p_module_name IN VARCHAR2 DEFAULT 'hinoki');

    -- 単一ルートをORDSに登録
    PROCEDURE deploy_single_route(
        p_module_name IN VARCHAR2,
        p_http_method IN VARCHAR2,
        p_path        IN VARCHAR2,
        p_controller  IN VARCHAR2,
        p_action      IN VARCHAR2
    );

    -- ========== ディスパッチ ==========

    -- リクエストをコントローラにディスパッチ (ORDS Handler から呼び出し)
    PROCEDURE dispatch(p_controller IN VARCHAR2, p_action IN VARCHAR2);

    -- ========== 情報表示 ==========

    -- ルート一覧取得
    FUNCTION list_routes RETURN SYS_REFCURSOR;

    -- ルート一覧をテキストで出力
    PROCEDURE print_routes;

END hinoki_router;
/

CREATE OR REPLACE PACKAGE BODY hinoki_router AS

    -- ルートをDB登録
    PROCEDURE add_route(p_method IN VARCHAR2, p_path IN VARCHAR2,
                        p_controller IN VARCHAR2, p_action IN VARCHAR2) IS
    BEGIN
        MERGE INTO hinoki_routes r
        USING (SELECT p_method AS http_method, p_path AS path FROM dual) s
        ON (r.http_method = s.http_method AND r.path = s.path)
        WHEN MATCHED THEN
            UPDATE SET controller = p_controller, action = p_action
        WHEN NOT MATCHED THEN
            INSERT (http_method, path, controller, action)
            VALUES (p_method, p_path, p_controller, p_action);
        COMMIT;
    END add_route;

    -- ========== ルーティングDSL ==========

    PROCEDURE get(p_path IN VARCHAR2, p_controller IN VARCHAR2, p_action IN VARCHAR2) IS
    BEGIN add_route('GET', p_path, p_controller, p_action); END;

    PROCEDURE post(p_path IN VARCHAR2, p_controller IN VARCHAR2, p_action IN VARCHAR2) IS
    BEGIN add_route('POST', p_path, p_controller, p_action); END;

    PROCEDURE put(p_path IN VARCHAR2, p_controller IN VARCHAR2, p_action IN VARCHAR2) IS
    BEGIN add_route('PUT', p_path, p_controller, p_action); END;

    PROCEDURE delete_route(p_path IN VARCHAR2, p_controller IN VARCHAR2, p_action IN VARCHAR2) IS
    BEGIN add_route('DELETE', p_path, p_controller, p_action); END;

    PROCEDURE patch(p_path IN VARCHAR2, p_controller IN VARCHAR2, p_action IN VARCHAR2) IS
    BEGIN add_route('PATCH', p_path, p_controller, p_action); END;

    PROCEDURE resources(p_name IN VARCHAR2, p_controller IN VARCHAR2 DEFAULT NULL) IS
        v_ctrl VARCHAR2(200) := NVL(p_controller, p_name || '_controller');
        v_base VARCHAR2(500) := '/' || p_name;
    BEGIN
        get(v_base,                 v_ctrl, 'index_action');
        get(v_base || '/new',       v_ctrl, 'new_form');
        post(v_base,                v_ctrl, 'create_action');
        get(v_base || '/:id',       v_ctrl, 'show');
        get(v_base || '/:id/edit',  v_ctrl, 'edit_form');
        put(v_base || '/:id',       v_ctrl, 'update_action');
        post(v_base || '/:id',      v_ctrl, 'update_action');  -- HTMLフォーム対応
        delete_route(v_base || '/:id', v_ctrl, 'delete_action');
        post(v_base || '/:id/delete', v_ctrl, 'delete_action'); -- HTMLフォーム対応

        hinoki_core.log_info('Routes registered for resource: ' || p_name);
    END resources;

    PROCEDURE root(p_controller IN VARCHAR2, p_action IN VARCHAR2) IS
    BEGIN
        get('/', p_controller, p_action);
    END root;

    -- ========== ORDS連携 ==========

    PROCEDURE deploy_single_route(
        p_module_name IN VARCHAR2,
        p_http_method IN VARCHAR2,
        p_path        IN VARCHAR2,
        p_controller  IN VARCHAR2,
        p_action      IN VARCHAR2
    ) IS
        v_pattern VARCHAR2(1000);
        v_source  CLOB;
        v_tpl     VARCHAR2(200);
    BEGIN
        -- ORDS パターンに変換 (:id → {id})
        v_pattern := REPLACE(p_path, ':id', '{id}');
        IF v_pattern = '/' THEN v_pattern := '.'; END IF;

        -- テンプレート名 (パス + メソッドで一意)
        v_tpl := REPLACE(REPLACE(v_pattern, '/', '_'), '.', 'root')
              || '_' || LOWER(p_http_method);

        -- PL/SQL ハンドラソース
        v_source := 'BEGIN ' || p_controller || '.' || p_action || '; END;';

        -- ORDS テンプレート & ハンドラ登録
        ORDS.define_template(
            p_module_name => p_module_name,
            p_pattern     => v_pattern
        );

        ORDS.define_handler(
            p_module_name  => p_module_name,
            p_pattern      => v_pattern,
            p_method       => p_http_method,
            p_source_type  => ORDS.source_type_plsql,
            p_source       => v_source
        );
    END deploy_single_route;

    PROCEDURE deploy_routes(p_module_name IN VARCHAR2 DEFAULT 'hinoki') IS
        v_base_path VARCHAR2(200);
    BEGIN
        v_base_path := NVL(hinoki_core.config('ords.base_path'), '/hinoki/');

        -- モジュール作成 (既存があれば上書き)
        BEGIN
            ORDS.delete_module(p_module_name => p_module_name);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        ORDS.define_module(
            p_module_name => p_module_name,
            p_base_path   => v_base_path,
            p_items_per_page => 25,
            p_status      => 'PUBLISHED'
        );

        -- 全ルートをデプロイ
        FOR rec IN (
            SELECT http_method, path, controller, action
            FROM hinoki_routes
            ORDER BY path, http_method
        ) LOOP
            deploy_single_route(
                p_module_name, rec.http_method, rec.path,
                rec.controller, rec.action
            );
        END LOOP;

        COMMIT;
        hinoki_core.log_info('Routes deployed to ORDS module: ' || p_module_name);
    END deploy_routes;

    PROCEDURE undeploy_routes(p_module_name IN VARCHAR2 DEFAULT 'hinoki') IS
    BEGIN
        ORDS.delete_module(p_module_name => p_module_name);
        COMMIT;
    END undeploy_routes;

    -- ========== ディスパッチ ==========

    PROCEDURE dispatch(p_controller IN VARCHAR2, p_action IN VARCHAR2) IS
        v_ctrl VARCHAR2(200) := hinoki_model.sanitize_identifier(p_controller);
        v_act  VARCHAR2(200) := hinoki_model.sanitize_identifier(p_action);
    BEGIN
        hinoki_core.log_info('Dispatching: ' || v_ctrl || '#' || v_act);
        EXECUTE IMMEDIATE 'BEGIN ' || v_ctrl || '.' || v_act || '; END;';
    EXCEPTION WHEN OTHERS THEN
        hinoki_core.log_error('Dispatch error: ' || SQLERRM);
        hinoki_core.respond_500(SQLERRM);
    END dispatch;

    -- ========== 情報表示 ==========

    FUNCTION list_routes RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT http_method, path, controller, action
            FROM hinoki_routes
            ORDER BY path, DECODE(http_method, 'GET', 1, 'POST', 2, 'PUT', 3, 'DELETE', 4, 5);
        RETURN v_cursor;
    END list_routes;

    PROCEDURE print_routes IS
    BEGIN
        DBMS_OUTPUT.put_line('');
        DBMS_OUTPUT.put_line('🌲 Hinoki Routes');
        DBMS_OUTPUT.put_line(RPAD('=', 80, '='));
        DBMS_OUTPUT.put_line(
            RPAD('Method', 10) || RPAD('Path', 30) || RPAD('Controller', 25) || 'Action'
        );
        DBMS_OUTPUT.put_line(RPAD('-', 80, '-'));

        FOR rec IN (
            SELECT http_method, path, controller, action
            FROM hinoki_routes
            ORDER BY path, DECODE(http_method, 'GET', 1, 'POST', 2, 'PUT', 3, 'DELETE', 4, 5)
        ) LOOP
            DBMS_OUTPUT.put_line(
                RPAD(rec.http_method, 10)
                || RPAD(rec.path, 30)
                || RPAD(rec.controller, 25)
                || rec.action
            );
        END LOOP;
        DBMS_OUTPUT.put_line(RPAD('=', 80, '='));
    END print_routes;

END hinoki_router;
/

PROMPT  ✓ hinoki_router installed
