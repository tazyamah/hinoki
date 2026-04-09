# デプロイ・ORDS

## デプロイの仕組み

`hinoki deploy` は以下の順番で実行します:

1. `app/models/*.hk` → トランスパイル → `CREATE OR REPLACE PACKAGE` 実行
2. `app/models/*.sql` → そのまま実行
3. `app/controllers/*.hk` → トランスパイル → 実行
4. `app/controllers/*.sql` → そのまま実行
5. `app/views/**/*.html` → `hinoki_views` テーブルに MERGE
6. `config/routes.hk` → トランスパイル → ORDS モジュール登録

## ORDS URL

デプロイ後の URL:

```
https://<your-adb>.adb.<region>.oraclecloudapps.com/ords/<schema>/<module_base_path>/<route>
```

例: `hinoki.yml` の `ords.base_path` が `/myblog/` の場合:

```
https://xxx.adb.ap-tokyo-1.oraclecloudapps.com/ords/admin/myblog/articles
```

## ORDS ユーザー設定

ADB の ADMIN ユーザーで以下を実行（通常は不要・デフォルトで有効）:

```sql
BEGIN
    ORDS.enable_schema(
        p_enabled => TRUE,
        p_schema  => 'ADMIN',
        p_url_mapping_type => 'BASE_PATH',
        p_url_mapping_pattern => 'admin'
    );
    COMMIT;
END;
/
```
