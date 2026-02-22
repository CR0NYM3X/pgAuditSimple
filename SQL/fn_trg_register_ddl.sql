/*
 @Function: audit.fn_trg_register_ddl
 @Creation Date: 19/02/2026
 @Description: Centralized DDL event capture. Records all DDL history exclusively 
                into audit.ddl_history, including the affected object name.
 @Parameters: N/A (Event Trigger)
 @Returns: event_trigger
 @Author: CR0NYM3X
 ---------------- HISTORY ----------------
 @Date: 19/02/2026
 @Change: Removed specific cat_server logic. Centralized all logs in ddl_history.
 @Author: CR0NYM3X
*/

-- DROP SCHEMA audit;
CREATE SCHEMA IF NOT EXISTS audit;

-- Centralized audit table
-- DROP TABLE audit.ddl_history;
-- truncate audit.ddl_history RESTART IDENTITY ;
CREATE TABLE IF NOT EXISTS audit.ddl_history (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- server_ip     text,
    port          int,
    app_name      text,
    db_name       text,
    event         text, -- TG_TAG
    object_name   text, -- Affected object (e.g., public.my_table)
    user_name     text,
    client_ip     text,
    query         text,
    created_at    timestamptz DEFAULT clock_timestamp()
);

-- 1. Catálogo de aplicaciones excluidas
CREATE TABLE IF NOT EXISTS audit.conf_excluded_apps (
    app_name text PRIMARY KEY,
    description text,
    created_at timestamptz DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_conf_excluded_apps ON audit.conf_excluded_apps (app_name);

-- Insertamos pg_cron por defecto
INSERT INTO audit.conf_excluded_apps (app_name, description) 
VALUES ('pg_cron', 'Procesos de mantenimiento automático')
ON CONFLICT DO NOTHING;


CREATE TABLE IF NOT EXISTS audit.conf_event_matrix (
    command_tag text PRIMARY KEY,
    is_active boolean DEFAULT true,
    created_at timestamptz DEFAULT clock_timestamp()
);

COMMENT ON TABLE audit.conf_event_matrix IS 'Matriz de control para activación/desactivación de auditoría por tipo de comando DDL.';

-- https://www.postgresql.org/docs/17/event-trigger-matrix.html
---------------- DATA POPULATION ----------------
INSERT INTO audit.conf_event_matrix (command_tag) VALUES
-- Objetos Base
('CREATE TABLE'), ('ALTER TABLE'), ('DROP TABLE'),
('CREATE TABLE AS'), ('SELECT INTO'),
-- Índices y Vistas
('CREATE INDEX'), ('ALTER INDEX'), ('DROP INDEX'),
('CREATE VIEW'), ('ALTER VIEW'), ('DROP VIEW'),
('CREATE MATERIALIZED VIEW'), ('ALTER MATERIALIZED VIEW'), ('DROP MATERIALIZED VIEW'), ('REFRESH MATERIALIZED VIEW'),
-- Secuencias y Tipos
('CREATE SEQUENCE'), ('ALTER SEQUENCE'), ('DROP SEQUENCE'),
('CREATE TYPE'), ('ALTER TYPE'), ('DROP TYPE'),
('CREATE DOMAIN'), ('ALTER DOMAIN'), ('DROP DOMAIN'),
-- Funciones y Procedimientos
('CREATE FUNCTION'), ('ALTER FUNCTION'), ('DROP FUNCTION'),
('CREATE PROCEDURE'), ('ALTER PROCEDURE'), ('DROP PROCEDURE'),
('CREATE AGGREGATE'), ('ALTER AGGREGATE'), ('DROP AGGREGATE'),
('CREATE ROUTINE'), ('ALTER ROUTINE'), ('DROP ROUTINE'),
-- Esquemas y Extensiones
('CREATE SCHEMA'), ('ALTER SCHEMA'), ('DROP SCHEMA'),
('CREATE EXTENSION'), ('ALTER EXTENSION'), ('DROP EXTENSION'),
-- Triggers y Reglas
('CREATE TRIGGER'), ('ALTER TRIGGER'), ('DROP TRIGGER'),
('CREATE RULE'), ('DROP RULE'),
-- Operadores y Conversiones
('CREATE OPERATOR'), ('ALTER OPERATOR'), ('DROP OPERATOR'),
('CREATE OPERATOR CLASS'), ('ALTER OPERATOR CLASS'), ('DROP OPERATOR CLASS'),
('CREATE OPERATOR FAMILY'), ('ALTER OPERATOR FAMILY'), ('DROP OPERATOR FAMILY'),
('CREATE CAST'), ('DROP CAST'),
('CREATE CONVERSION'), ('ALTER CONVERSION'), ('DROP CONVERSION'),
-- Texto y Collation
('CREATE COLLATION'), ('ALTER COLLATION'), ('DROP COLLATION'),
('CREATE TEXT SEARCH CONFIGURATION'), ('ALTER TEXT SEARCH CONFIGURATION'), ('DROP TEXT SEARCH CONFIGURATION'),
('CREATE TEXT SEARCH DICTIONARY'), ('ALTER TEXT SEARCH DICTIONARY'), ('DROP TEXT SEARCH DICTIONARY'),
('CREATE TEXT SEARCH PARSER'), ('ALTER TEXT SEARCH PARSER'), ('DROP TEXT SEARCH PARSER'),
('CREATE TEXT SEARCH TEMPLATE'), ('ALTER TEXT SEARCH TEMPLATE'), ('DROP TEXT SEARCH TEMPLATE'),
-- Seguridad y Políticas
('CREATE POLICY'), ('ALTER POLICY'), ('DROP POLICY'),
('CREATE ROLE'), ('ALTER ROLE'), ('DROP ROLE'),
('CREATE USER'), ('ALTER USER'), ('DROP USER'),
('CREATE USER GROUP'), ('ALTER USER GROUP'), ('DROP USER GROUP'),
-- FDW (Foreign Data Wrappers)
('CREATE FOREIGN DATA WRAPPER'), ('ALTER FOREIGN DATA WRAPPER'), ('DROP FOREIGN DATA WRAPPER'),
('CREATE SERVER'), ('ALTER SERVER'), ('DROP SERVER'),
('CREATE USER MAPPING'), ('ALTER USER MAPPING'), ('DROP USER MAPPING'),
('CREATE FOREIGN TABLE'), ('ALTER FOREIGN TABLE'), ('DROP FOREIGN TABLE'),
('IMPORT FOREIGN SCHEMA'),
-- Publicación y Suscripción
('CREATE PUBLICATION'), ('ALTER PUBLICATION'), ('DROP PUBLICATION'),
('CREATE SUBSCRIPTION'), ('ALTER SUBSCRIPTION'), ('DROP SUBSCRIPTION'),
-- Otros
('CREATE STATISTICS'), ('ALTER STATISTICS'), ('DROP STATISTICS'),
('CREATE EVENT TRIGGER'), ('ALTER EVENT TRIGGER'), ('DROP EVENT TRIGGER'),
('CREATE LANGUAGE'), ('ALTER LANGUAGE'), ('DROP LANGUAGE'),
('CREATE TRANSFORM'), ('DROP TRANSFORM'),
('CREATE ACCESS METHOD'), ('DROP ACCESS METHOD'),
('CREATE TS CONFIG'), ('ALTER TS CONFIG'), ('DROP TS CONFIG'),
('CREATE TS DICT'), ('ALTER TS DICT'), ('DROP TS DICT'),
('CREATE TS PARSER'), ('ALTER TS PARSER'), ('DROP TS PARSER'),
('CREATE TS TEMPLATE'), ('ALTER TS TEMPLATE'), ('DROP TS TEMPLATE'),
('COMMENT'), ('SECURITY LABEL'), ('GRANT'), ('REVOKE')
ON CONFLICT (command_tag) DO NOTHING;


CREATE INDEX IF NOT EXISTS idx_conf_event_matrix_active 
ON audit.conf_event_matrix (command_tag) 
WHERE is_active = true;





-- DROP FUNCTION audit.fn_trg_register_ddl();
CREATE OR REPLACE FUNCTION audit.fn_trg_register_ddl()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $BODY$
DECLARE
    v_app_name  text := current_setting('application_name', true);
    v_query     text := current_query();
    v_timestamp timestamptz := clock_timestamp();
    r_obj       record;
    v_is_active boolean;
BEGIN

    -- 1. FILTRO DE APLICACIONES (Lista Negra)
    IF EXISTS (SELECT 1 FROM audit.conf_excluded_apps WHERE app_name = v_app_name) THEN
        RETURN;
    END IF;

    -- Verificamos si el comando (TG_TAG) está activo en nuestra tabla de configuración
    SELECT is_active INTO v_is_active 
    FROM audit.conf_event_matrix 
    WHERE command_tag = TG_TAG;

    IF v_is_active = false THEN
        RETURN; -- Si existe pero está desactivado, salimos.
    END IF;

    -- CASO 1: Comandos de creación/alteración (CREATE, ALTER)
    IF TG_EVENT = 'ddl_command_end' THEN
        FOR r_obj IN SELECT object_identity FROM pg_catalog.pg_event_trigger_ddl_commands() LOOP
            INSERT INTO audit.ddl_history (app_name, db_name, event, object_name, user_name, client_ip, query, created_at) 
            VALUES (v_app_name, current_database(), TG_TAG, r_obj.object_identity, session_user, 
                    coalesce(host(inet_client_addr()), '127.0.0.1'), v_query, v_timestamp);
        END LOOP;

    -- CASO 2: Comandos de eliminación (DROP)
    ELSIF TG_EVENT = 'sql_drop' THEN
        -- FILTRO MAESTRO:
        -- original = true: indica que es el objeto mencionado en el comando DROP.
        -- Esto elimina duplicados de tipos compuestos y arrays asociados.
        FOR r_obj IN 
            SELECT object_identity 
            FROM pg_catalog.pg_event_trigger_dropped_objects()
            WHERE original = true -- ESTA ES LA CLAVE PARA EVITAR DUPLICADOS
        LOOP
            INSERT INTO audit.ddl_history (app_name, db_name, event, object_name, user_name, client_ip, query, created_at) 
            VALUES (v_app_name, current_database(), TG_TAG, r_obj.object_identity, session_user, 
                    coalesce(host(inet_client_addr()), '127.0.0.1'), v_query, v_timestamp);
        END LOOP;
    END IF;

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'DDL Audit failed: %', SQLERRM;
END;
$BODY$;


-- Security and Permissions Configuration
ALTER FUNCTION audit.fn_trg_register_ddl() 
SET search_path TO audit, pg_catalog, public, pg_temp;

REVOKE ALL ON FUNCTION audit.fn_trg_register_ddl() FROM PUBLIC;

---------------- COMMENT ----------------
COMMENT ON FUNCTION audit.fn_trg_register_ddl() IS
'Event trigger for centralized DDL auditing.
- Records all events in audit.ddl_history.
- Captures object_name using pg_event_trigger_ddl_commands().
- Security: SECURITY DEFINER with restricted search_path.';


-- DROP EVENT TRIGGER IF EXISTS trg_audit_ddl_global;
-- Trigger para CREATE, ALTER, etc.
DROP EVENT TRIGGER IF EXISTS trg_audit_ddl_global;
CREATE EVENT TRIGGER trg_audit_ddl_global 
ON ddl_command_end 
EXECUTE FUNCTION audit.fn_trg_register_ddl();

-- Trigger específico para DROP
DROP EVENT TRIGGER IF EXISTS trg_audit_ddl_drop;
CREATE EVENT TRIGGER trg_audit_ddl_drop 
ON sql_drop 
EXECUTE FUNCTION audit.fn_trg_register_ddl();


-- create temp table client123(name varchar);
-- alter table client123 add column phone varchar;
-- CREATE TABLE test_a(id int); CREATE TABLE test_b(id int);
-- DROP TABLE test_a, test_b;
-- select * from audit.ddl_history ;
