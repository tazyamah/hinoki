-- ============================================================
-- Analytics Controller (生 PL/SQL)
-- 
-- 複雑な集計ロジックはDSLよりも生PL/SQLが適しているため、
-- .sql ファイルとして記述。.hk ファイルと共存可能。
-- ============================================================

CREATE OR REPLACE PACKAGE analytics_controller AS
    PROCEDURE dashboard;
    PROCEDURE popular;
END analytics_controller;
/

CREATE OR REPLACE PACKAGE BODY analytics_controller AS

    PROCEDURE dashboard IS
        v_total_articles NUMBER;
        v_total_views    NUMBER;
        v_total_comments NUMBER;
        v_json           CLOB;
    BEGIN
        SELECT COUNT(*), NVL(SUM(view_count), 0)
        INTO v_total_articles, v_total_views
        FROM articles WHERE published = 1;

        SELECT COUNT(*) INTO v_total_comments FROM comments;

        IF hinoki_core.is_json_request THEN
            v_json := '{"articles":' || v_total_articles
                   || ',"views":' || v_total_views
                   || ',"comments":' || v_total_comments || '}';
            hinoki_core.respond_json(v_json);
        ELSE
            hinoki_view.assign('total_articles', v_total_articles);
            hinoki_view.assign('total_views', v_total_views);
            hinoki_view.assign('total_comments', v_total_comments);
            hinoki_view.render_to('analytics/dashboard');
        END IF;
    END dashboard;

    PROCEDURE popular IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT id, title, author, view_count,
                   ROUND(view_count * 100.0 /
                       NULLIF((SELECT SUM(view_count) FROM articles), 0), 1) AS pct
            FROM articles
            WHERE published = 1
            ORDER BY view_count DESC
            FETCH FIRST 10 ROWS ONLY;

        hinoki_view.assign_raw('table_content',
            hinoki_controller.table_for(v_cursor,
                'id,title,author,view_count,pct',
                'ID,タイトル,著者,閲覧数,割合(%)', 'articles'));
        hinoki_view.render_to('analytics/popular');
    END popular;

END analytics_controller;
/
