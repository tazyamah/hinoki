-- ============================================================
-- Hinoki Framework - Core Installation Script
-- OCI Autonomous Database Full-Stack Web Framework
-- ============================================================

WHENEVER SQLERROR EXIT SQL.SQLCODE;

PROMPT ========================================
PROMPT  🌲 Hinoki Framework Installation
PROMPT ========================================

-- ============================================================
-- 1. Framework metadata tables
-- ============================================================

PROMPT Creating framework tables...

CREATE TABLE IF NOT EXISTS hinoki_config (
    key         VARCHAR2(200) PRIMARY KEY,
    value       VARCHAR2(4000),
    updated_at  TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE IF NOT EXISTS hinoki_migrations (
    id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    version     VARCHAR2(100) NOT NULL UNIQUE,
    name        VARCHAR2(500),
    executed_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    checksum    VARCHAR2(64)
);

CREATE TABLE IF NOT EXISTS hinoki_routes (
    id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    http_method VARCHAR2(10) NOT NULL,
    path        VARCHAR2(1000) NOT NULL,
    controller  VARCHAR2(200) NOT NULL,
    action      VARCHAR2(200) NOT NULL,
    ords_module VARCHAR2(200),
    created_at  TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT hinoki_routes_uk UNIQUE (http_method, path)
);

CREATE TABLE IF NOT EXISTS hinoki_views (
    id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR2(500) NOT NULL UNIQUE,
    content     CLOB,
    layout      VARCHAR2(200) DEFAULT 'application',
    updated_at  TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE IF NOT EXISTS hinoki_sessions (
    session_id  VARCHAR2(128) PRIMARY KEY,
    data        CLOB DEFAULT '{}',
    user_id     NUMBER,
    created_at  TIMESTAMP DEFAULT SYSTIMESTAMP,
    expires_at  TIMESTAMP DEFAULT SYSTIMESTAMP + INTERVAL '24' HOUR,
    updated_at  TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE IF NOT EXISTS hinoki_assets (
    id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    path        VARCHAR2(1000) NOT NULL UNIQUE,
    content     BLOB,
    mime_type   VARCHAR2(200),
    etag        VARCHAR2(64),
    updated_at  TIMESTAMP DEFAULT SYSTIMESTAMP
);

-- ============================================================
-- 2. Default config
-- ============================================================

MERGE INTO hinoki_config c
USING (SELECT 'app.name' AS key, 'HinokiApp' AS value FROM dual
       UNION ALL SELECT 'app.version', '0.1.0' FROM dual
       UNION ALL SELECT 'app.charset', 'UTF-8' FROM dual
       UNION ALL SELECT 'view.layout', 'application' FROM dual
       UNION ALL SELECT 'session.timeout', '86400' FROM dual
       UNION ALL SELECT 'ords.base_path', '/hinoki/' FROM dual
) s ON (c.key = s.key)
WHEN NOT MATCHED THEN INSERT (key, value) VALUES (s.key, s.value);

COMMIT;

PROMPT Core tables created.

-- ============================================================
-- 3. Install PL/SQL packages (in dependency order)
-- ============================================================

@@hinoki_core.sql
@@hinoki_view.sql
@@hinoki_model.sql
@@hinoki_router.sql
@@hinoki_controller.sql
@@hinoki_migrate.sql

PROMPT
PROMPT ========================================
PROMPT  🌲 Hinoki installed successfully!
PROMPT ========================================

