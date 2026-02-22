



CREATE OR REPLACE FUNCTION public.pg_deploy_audit_dml(
    p_schema text,
    p_table  text,
    p_pk_col text,
    p_events text DEFAULT 'all'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $deploy$
DECLARE
    v_pk_type      text;
    v_audit_table  text := p_table;
    v_trigger_func text := 'fn_trg_audit_' || p_table;
    v_trunc_func   text := 'fn_trg_trunc_' || p_table;
    v_sql          text;
    v_event_list   text := lower(p_events);
BEGIN
    -- 1. Validar existencia de la tabla maestra y obtener tipo de PK
    SELECT data_type INTO v_pk_type
    FROM information_schema.columns
    WHERE table_schema = p_schema AND table_name = p_table AND column_name = p_pk_col;

    IF v_pk_type IS NULL THEN
        RAISE EXCEPTION 'La tabla o la columna PK no existen en %.%', p_schema, p_table;
    END IF;

    -- 2. Crear esquema audit si no existe
    CREATE SCHEMA IF NOT EXISTS audit;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tables WHERE schemaname = 'audit' AND tablename  = 'dml_inventory' ) THEN
        CREATE TABLE IF NOT EXISTS audit.dml_inventory (
            id_monitored    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            schema_name     text NOT NULL,
            table_name      text NOT NULL,
            pk_column       text NOT NULL,
            events          text NOT NULL, -- Ej: 'all' o 'insert,update'
            deployed_at     timestamptz DEFAULT clock_timestamp(),
            deployed_by     text DEFAULT session_user,
            UNIQUE(schema_name, table_name) -- Evita duplicados de registro para la misma tabla
        );
        
        COMMENT ON TABLE audit.dml_inventory IS 'Catálogo de tablas bajo monitoreo de auditoría DML.';
        CREATE INDEX IF NOT EXISTS idx_conf_monitored_lookup ON audit.dml_inventory (table_name, schema_name);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tables WHERE schemaname = 'audit' AND tablename  = 'conf_excluded_apps' ) THEN
        -- 3. TABLA DE EXCLUSIÓN DE APLICACIONES
        CREATE TABLE IF NOT EXISTS audit.conf_excluded_apps (
            app_name text PRIMARY KEY,
            description text,
            created_at timestamptz DEFAULT clock_timestamp()
        );
        
        CREATE INDEX IF NOT EXISTS idx_conf_excluded_apps ON audit.conf_excluded_apps (app_name);
    END IF;


    -- 3. Crear tabla de auditoría espejo (Dynamic DDL)
    v_sql := format($sql$
        CREATE TABLE IF NOT EXISTS audit.%I (
            id_log          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            id_origen       %s,
            operacion       text NOT NULL CHECK (operacion IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')),
            fecha_cambio    timestamptz NOT NULL DEFAULT clock_timestamp(),
            valor_anterior  jsonb,
            valor_nuevo     jsonb,
            usuario         text NOT NULL DEFAULT session_user,
            ip_cliente      text,
            query           text
        );
        COMMENT ON TABLE audit.%I IS 'Auditoría automática de la tabla %s.%s';
        $sql$, v_audit_table, v_pk_type, v_audit_table, p_schema, p_table);
    EXECUTE v_sql;

    -- 4. Generar Función de Trigger DML
    v_sql := format($sql$
        CREATE OR REPLACE FUNCTION audit.%I()
        RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
        DECLARE
            v_app_name  text := current_setting('application_name', true);
            v_old_jsonb jsonb; v_new_jsonb jsonb;
            v_diff_old  jsonb := '{}'; v_diff_new  jsonb := '{}';
            v_query     text := current_query();
            v_ip        text := COALESCE(host(inet_client_addr()), '127.0.0.1');
        BEGIN
            IF EXISTS (SELECT 1 FROM audit.conf_excluded_apps WHERE app_name = v_app_name) THEN RETURN NULL; END IF;
            IF TG_OP = 'INSERT' THEN
                INSERT INTO audit.%I (id_origen, operacion, valor_nuevo, usuario, ip_cliente, query)
                VALUES (NEW.%I, 'INSERT', to_jsonb(NEW), session_user, v_ip, v_query);
                RETURN NEW;
            ELSIF TG_OP = 'DELETE' THEN
                INSERT INTO audit.%I (id_origen, operacion, valor_anterior, usuario, ip_cliente, query)
                VALUES (OLD.%I, 'DELETE', to_jsonb(OLD), session_user, v_ip, v_query);
                RETURN OLD;
            ELSIF TG_OP = 'UPDATE' THEN
                v_old_jsonb := to_jsonb(OLD); v_new_jsonb := to_jsonb(NEW);
                SELECT jsonb_object_agg(key, value), jsonb_object_agg(key, (v_new_jsonb -> key))
                INTO v_diff_old, v_diff_new FROM jsonb_each(v_old_jsonb)
                WHERE (v_new_jsonb -> key) IS DISTINCT FROM value;
                IF v_diff_new IS NOT NULL THEN
                    INSERT INTO audit.%I (id_origen, operacion, valor_anterior, valor_nuevo, usuario, ip_cliente, query)
                    VALUES (OLD.%I, 'UPDATE', v_diff_old, v_diff_new, session_user, v_ip, v_query);
                END IF;
                RETURN NEW;
            END IF;
            RETURN NULL;
        EXCEPTION WHEN OTHERS THEN 
            RAISE WARNING 'Audit Error en %I: %%', SQLERRM; RETURN COALESCE(NEW, OLD);
        END; $$;
        $sql$, v_trigger_func, v_audit_table, p_pk_col, v_audit_table, p_pk_col, v_audit_table, p_pk_col, v_trigger_func);
    EXECUTE v_sql;

    -- 5. Generar Función de Trigger TRUNCATE
    v_sql := format($sql$
        CREATE OR REPLACE FUNCTION audit.%I()
        RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
        BEGIN
            INSERT INTO audit.%I (id_origen, operacion, valor_anterior, usuario, ip_cliente, query)
            VALUES (NULL, 'TRUNCATE', jsonb_build_object('info', 'Tabla vaciada'), session_user, COALESCE(host(inet_client_addr()), '127.0.0.1'), current_query());
            RETURN NULL;
        END; $$;
        $sql$, v_trunc_func, v_audit_table);
    EXECUTE v_sql;

    -- 6. Montar Triggers finales según p_events
    -- Limpieza previa
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_dml_%s ON %I.%I', p_table, p_schema, p_table);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_trunc_%s ON %I.%I', p_table, p_schema, p_table);

    -- Trigger DML (Insert, Update, Delete)
    IF v_event_list = 'all' OR v_event_list ~ '(insert|update|delete)' THEN
        DECLARE
            v_actual_events text := '';
        BEGIN
            IF v_event_list = 'all' THEN v_actual_events := 'INSERT OR UPDATE OR DELETE';
            ELSE
                IF v_event_list ~ 'insert' THEN v_actual_events := v_actual_events || 'INSERT OR '; END IF;
                IF v_event_list ~ 'update' THEN v_actual_events := v_actual_events || 'UPDATE OR '; END IF;
                IF v_event_list ~ 'delete' THEN v_actual_events := v_actual_events || 'DELETE OR '; END IF;
                v_actual_events := rtrim(v_actual_events, ' OR ');
            END IF;

            EXECUTE format('CREATE TRIGGER trg_audit_dml_%s AFTER %s ON %I.%I FOR EACH ROW EXECUTE FUNCTION audit.%I()',
                p_table, v_actual_events, p_schema, p_table, v_trigger_func);
        END;
    END IF;

    -- Trigger Truncate
    IF v_event_list = 'all' OR v_event_list ~ 'truncate' THEN
        EXECUTE format('CREATE TRIGGER trg_audit_trunc_%s AFTER TRUNCATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION audit.%I()',
            p_table, p_schema, p_table, v_trunc_func);
    END IF;

-- 7. REGISTRO EN TABLA DE CONTROL (Idempotente)
    INSERT INTO audit.dml_inventory (schema_name, table_name, pk_column, events)
    VALUES (p_schema, p_table, p_pk_col, v_event_list)
    ON CONFLICT (schema_name, table_name) 
    DO UPDATE SET 
        pk_column = EXCLUDED.pk_column,
        events = EXCLUDED.events,
        deployed_at = clock_timestamp(),
        deployed_by = session_user;

    RETURN format('Auditoría desplegada en audit.%s para la tabla %s.%s (Eventos: %s)', v_audit_table, p_schema, p_table, p_events);
END;
$deploy$;


/*
------------------------------------------------------------
-- PRUEBA 1: Auditoría completa (Default)
------------------------------------------------------------
-- Creamos una tabla de ejemplo
 CREATE TABLE public.clientes (id_cli serial PRIMARY KEY, nombre text, saldo numeric);

-- Desplegamos auditoría 'all'
SELECT public.pg_deploy_audit_dml('public', 'clientes', 'id_cli', 'all');

-- Operamos
INSERT INTO public.clientes VALUES (101, 'Empresa X', 5000);
UPDATE public.clientes SET saldo = 6000,nombre = 'Empresa Y' WHERE id_cli = 101;
DELETE FROM public.clientes where id_cli = 101;
TRUNCATE TABLE public.clientes;

-- Verificamos
SELECT * FROM audit.clientes;

------------------------------------------------------------
-- PRUEBA 2: Lista personalizada (Solo Insert y Delete)
------------------------------------------------------------
CREATE TABLE public.productos (id_prod int PRIMARY KEY, sku text);

SELECT public.pg_deploy_audit_dml('public', 'productos', 'id_prod', 'insert,delete');

INSERT INTO public.productos VALUES (1, 'SKU-001');
UPDATE public.productos SET sku = 'SKU-999' WHERE id_prod = 1; -- No debería auditarse
DELETE FROM public.productos WHERE id_prod = 1;

SELECT * FROM audit.productos;


SELECT * FROM audit.dml_inventory;
*/

