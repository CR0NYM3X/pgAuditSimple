CREATE OR REPLACE FUNCTION public.pg_deploy_audit_ddl()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $install$
BEGIN
    -- 1. CREACIÓN DE INFRAESTRUCTURA DE ESQUEMA
    CREATE SCHEMA IF NOT EXISTS audit;

    -- 2. TABLA DE HISTORIA CENTRALIZADA
    CREATE TABLE IF NOT EXISTS audit.ddl_history (
        id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        app_name    text,
        db_name     text,
        event       text, 
        object_name text, 
        user_name   text,
        client_ip   text,
        query       text,
        created_at  timestamptz DEFAULT clock_timestamp()
    );

    -- 3. TABLA DE EXCLUSIÓN DE APLICACIONES
    CREATE TABLE IF NOT EXISTS audit.conf_excluded_apps (
        app_name text PRIMARY KEY,
        description text,
        created_at timestamptz DEFAULT clock_timestamp()
    );
    
    CREATE INDEX IF NOT EXISTS idx_conf_excluded_apps ON audit.conf_excluded_apps (app_name);

    INSERT INTO audit.conf_excluded_apps (app_name, description) 
    VALUES ('pg_cron', 'Procesos de mantenimiento automático')
    ON CONFLICT DO NOTHING;

    -- 4. MATRIZ DE CONFIGURACIÓN DE COMANDOS
    CREATE TABLE IF NOT EXISTS audit.conf_event_matrix (
        command_tag text PRIMARY KEY,
        is_active boolean DEFAULT true,
        created_at timestamptz DEFAULT clock_timestamp()
    );

    CREATE INDEX IF NOT EXISTS idx_conf_event_matrix_active 
    ON audit.conf_event_matrix (command_tag) WHERE is_active = true;

    -- 5. POBLADO DE MATRIZ (POSTGRESQL 17)
    INSERT INTO audit.conf_event_matrix (command_tag) VALUES
    ('CREATE TABLE'), ('ALTER TABLE'), ('DROP TABLE'), ('CREATE TABLE AS'), ('SELECT INTO'),
    ('CREATE INDEX'), ('ALTER INDEX'), ('DROP INDEX'), ('CREATE VIEW'), ('ALTER VIEW'), ('DROP VIEW'),
    ('CREATE MATERIALIZED VIEW'), ('ALTER MATERIALIZED VIEW'), ('DROP MATERIALIZED VIEW'), ('REFRESH MATERIALIZED VIEW'),
    ('CREATE SEQUENCE'), ('ALTER SEQUENCE'), ('DROP SEQUENCE'), ('CREATE TYPE'), ('ALTER TYPE'), ('DROP TYPE'),
    ('CREATE DOMAIN'), ('ALTER DOMAIN'), ('DROP DOMAIN'), ('CREATE FUNCTION'), ('ALTER FUNCTION'), ('DROP FUNCTION'),
    ('CREATE PROCEDURE'), ('ALTER PROCEDURE'), ('DROP PROCEDURE'), ('CREATE AGGREGATE'), ('ALTER AGGREGATE'), ('DROP AGGREGATE'),
    ('CREATE ROUTINE'), ('ALTER ROUTINE'), ('DROP ROUTINE'), ('CREATE SCHEMA'), ('ALTER SCHEMA'), ('DROP SCHEMA'),
    ('CREATE EXTENSION'), ('ALTER EXTENSION'), ('DROP EXTENSION'), ('CREATE TRIGGER'), ('ALTER TRIGGER'), ('DROP TRIGGER'),
    ('CREATE RULE'), ('DROP RULE'), ('CREATE OPERATOR'), ('ALTER OPERATOR'), ('DROP OPERATOR'), ('CREATE OPERATOR CLASS'),
    ('ALTER OPERATOR CLASS'), ('DROP OPERATOR CLASS'), ('CREATE OPERATOR FAMILY'), ('ALTER OPERATOR FAMILY'), ('DROP OPERATOR FAMILY'),
    ('CREATE CAST'), ('DROP CAST'), ('CREATE CONVERSION'), ('ALTER CONVERSION'), ('DROP CONVERSION'), ('CREATE COLLATION'),
    ('ALTER COLLATION'), ('DROP COLLATION'), ('CREATE TEXT SEARCH CONFIGURATION'), ('ALTER TEXT SEARCH CONFIGURATION'),
    ('DROP TEXT SEARCH CONFIGURATION'), ('CREATE TEXT SEARCH DICTIONARY'), ('ALTER TEXT SEARCH DICTIONARY'), ('DROP TEXT SEARCH DICTIONARY'),
    ('CREATE TEXT SEARCH PARSER'), ('ALTER TEXT SEARCH PARSER'), ('DROP TEXT SEARCH PARSER'), ('CREATE TEXT SEARCH TEMPLATE'),
    ('ALTER TEXT SEARCH TEMPLATE'), ('DROP TEXT SEARCH TEMPLATE'), ('CREATE POLICY'), ('ALTER POLICY'), ('DROP POLICY'),
    ('CREATE ROLE'), ('ALTER ROLE'), ('DROP ROLE'), ('CREATE USER'), ('ALTER USER'), ('DROP USER'), ('CREATE USER GROUP'),
    ('ALTER USER GROUP'), ('DROP USER GROUP'), ('CREATE FOREIGN DATA WRAPPER'), ('ALTER FOREIGN DATA WRAPPER'), ('DROP FOREIGN DATA WRAPPER'),
    ('CREATE SERVER'), ('ALTER SERVER'), ('DROP SERVER'), ('CREATE USER MAPPING'), ('ALTER USER MAPPING'), ('DROP USER MAPPING'),
    ('CREATE FOREIGN TABLE'), ('ALTER FOREIGN TABLE'), ('DROP FOREIGN TABLE'), ('IMPORT FOREIGN SCHEMA'), ('CREATE PUBLICATION'),
    ('ALTER PUBLICATION'), ('DROP PUBLICATION'), ('CREATE SUBSCRIPTION'), ('ALTER SUBSCRIPTION'), ('DROP SUBSCRIPTION'),
    ('CREATE STATISTICS'), ('ALTER STATISTICS'), ('DROP STATISTICS'), ('CREATE EVENT TRIGGER'), ('ALTER EVENT TRIGGER'),
    ('DROP EVENT TRIGGER'), ('CREATE LANGUAGE'), ('ALTER LANGUAGE'), ('DROP LANGUAGE'), ('CREATE TRANSFORM'), ('DROP TRANSFORM'),
    ('CREATE ACCESS METHOD'), ('DROP ACCESS METHOD'), ('CREATE TS CONFIG'), ('ALTER TS CONFIG'), ('DROP TS CONFIG'),
    ('CREATE TS DICT'), ('ALTER TS DICT'), ('DROP TS DICT'), ('CREATE TS PARSER'), ('ALTER TS PARSER'), ('DROP TS PARSER'),
    ('CREATE TS TEMPLATE'), ('ALTER TS TEMPLATE'), ('DROP TS TEMPLATE'), ('COMMENT'), ('SECURITY LABEL'), ('GRANT'), ('REVOKE')
    ON CONFLICT (command_tag) DO NOTHING;

    -- 6. FUNCIÓN DEL TRIGGER DE EVENTOS
    EXECUTE $sql$
    CREATE OR REPLACE FUNCTION audit.fn_trg_register_ddl()
    RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER AS $_fn_$
    DECLARE
        v_app_name  text := current_setting('application_name', true);
        v_query     text := current_query();
        v_timestamp timestamptz := clock_timestamp();
        r_obj       record;
        v_is_active boolean;
    BEGIN
        IF EXISTS (SELECT 1 FROM audit.conf_excluded_apps WHERE app_name = v_app_name) THEN RETURN; END IF;
        SELECT is_active INTO v_is_active FROM audit.conf_event_matrix WHERE command_tag = TG_TAG;
        IF v_is_active = false THEN RETURN; END IF;

        IF TG_EVENT = 'ddl_command_end' THEN
            FOR r_obj IN SELECT object_identity FROM pg_catalog.pg_event_trigger_ddl_commands() LOOP
                INSERT INTO audit.ddl_history (app_name, db_name, event, object_name, user_name, client_ip, query, created_at) 
                VALUES (v_app_name, current_database(), TG_TAG, r_obj.object_identity, session_user, 
                        coalesce(host(inet_client_addr()), '127.0.0.1'), v_query, v_timestamp);
            END LOOP;
        ELSIF TG_EVENT = 'sql_drop' THEN
            FOR r_obj IN SELECT object_identity FROM pg_catalog.pg_event_trigger_dropped_objects() WHERE original = true LOOP
                INSERT INTO audit.ddl_history (app_name, db_name, event, object_name, user_name, client_ip, query, created_at) 
                VALUES (v_app_name, current_database(), TG_TAG, r_obj.object_identity, session_user, 
                        coalesce(host(inet_client_addr()), '127.0.0.1'), v_query, v_timestamp);
            END LOOP;
        END IF;
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'DDL Audit failed: %', SQLERRM;
    END; $_fn_$;
    $sql$;

    -- 7. SEGURIDAD DE LA FUNCIÓN
    ALTER FUNCTION audit.fn_trg_register_ddl() SET search_path TO audit, pg_catalog, public, pg_temp;
    REVOKE ALL ON FUNCTION audit.fn_trg_register_ddl() FROM PUBLIC;

    -- 8. CREACIÓN DE EVENT TRIGGERS
    -- Nota: No se puede usar IF NOT EXISTS en CREATE EVENT TRIGGER, por lo que usamos DROP previo.
    DROP EVENT TRIGGER IF EXISTS trg_audit_ddl_global;
    CREATE EVENT TRIGGER trg_audit_ddl_global ON ddl_command_end EXECUTE FUNCTION audit.fn_trg_register_ddl();

    DROP EVENT TRIGGER IF EXISTS trg_audit_ddl_drop;
    CREATE EVENT TRIGGER trg_audit_ddl_drop ON sql_drop EXECUTE FUNCTION audit.fn_trg_register_ddl();

    RETURN 'Motor de Auditoría DDL instalado/actualizado correctamente en el esquema audit.';
END;
$install$;



-- Ejecutar el instalador
-- SELECT public.pg_deploy_audit_ddl();

-- Probar el registro
-- CREATE TABLE test_a(id int); CREATE TABLE test_b(id int);
-- DROP TABLE test_a, test_b;

-- Verificar la matriz cargada
-- SELECT * FROM audit.conf_event_matrix;
-- SELECT * FROM  audit.ddl_history
-- SELECT * FROM udit.conf_excluded_apps


 
