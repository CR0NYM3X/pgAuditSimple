CREATE OR REPLACE FUNCTION pgAuditSimple(
    p_tipo_auditoria TEXT,
    p_evento TEXT DEFAULT 'ALL',
    p_objeto TEXT DEFAULT NULL, -- formato: esquema.objeto o solo objeto
    p_ejecutar BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
AS $_$
DECLARE
    v_tag_list TEXT;
    v_trigger_condition TEXT := '';
    v_ddl_code TEXT := '';
    v_func_name TEXT := 'cdc.fn_ddl_audit';
    v_trig_name TEXT := 'trg_ddl_audit';
    v_objeto TEXT := p_objeto;
    v_schema TEXT := 'public';
    v_object TEXT;
    v_validacion_objeto TEXT := '';
BEGIN
    -- Habilita los mensajes en el cliente
    EXECUTE 'SET client_min_messages = notice';

    -- Crear esquema y tabla de auditoría si no existen
    EXECUTE 'CREATE SCHEMA IF NOT EXISTS cdc';

    EXECUTE '
        CREATE TABLE IF NOT EXISTS cdc.audit (
            id BIGSERIAL PRIMARY KEY,
            audit_type TEXT,
            object_id TEXT,
            operation TEXT,
            object_name TEXT,
            user_name TEXT,
            client_ip TEXT,
            query TEXT,
            previous_value JSONB,
            new_value JSONB,
            date TIMESTAMP DEFAULT CLOCK_TIMESTAMP()
        )';

    EXECUTE '
        CREATE TABLE IF NOT EXISTS cdc.obj_audit (
            id SERIAL PRIMARY KEY,
            object_name TEXT
        )';

    -- Validar tipo de auditoría
    IF lower(p_tipo_auditoria) <> 'ddl' THEN
        RAISE EXCEPTION 'Solo se permite auditoría de tipo DDL en esta función.';
    END IF;

    -- Procesar objeto si se especifica
    IF v_objeto IS NOT NULL THEN
        -- Si no tiene esquema, asumir 'public'
        IF position('.' IN v_objeto) = 0 THEN
            v_objeto := 'public.' || v_objeto;
        END IF;

        -- Separar esquema y objeto
        v_schema := split_part(v_objeto, '.', 1);
        v_object := split_part(v_objeto, '.', 2);

        -- Validar existencia en pg_class solo si se va a ejecutar
        IF p_ejecutar THEN
            IF NOT EXISTS (
                SELECT 1
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = v_schema
                  AND c.relname = v_object
            ) THEN
                RAISE NOTICE 'El objeto "%" no existe en el catálogo del sistema.', v_objeto;
                RAISE EXCEPTION 'No se puede generar auditoría para un objeto inexistente.';
            END IF;
        END IF;

        -- Insertar en cdc.obj_audit si no existe
        IF NOT EXISTS (
            SELECT 1 FROM cdc.obj_audit WHERE object_name = v_objeto
        ) THEN
            INSERT INTO cdc.obj_audit(object_name) VALUES (v_objeto);
        END IF;

        -- Generar nombres limpios para función y trigger
        v_func_name := v_func_name || '_' || replace(v_objeto, '.', '_');
        v_trig_name := v_trig_name || '_' || replace(v_objeto, '.', '_');

        -- Agregar validación interna en la función generada
        v_validacion_objeto := '
            IF EXISTS (
                SELECT 1 FROM cdc.obj_audit WHERE object_name = v_object_identity
            ) THEN';
    END IF;

    -- Si se especifica un evento, buscar los tags
    IF lower(p_evento) <> 'all' THEN
        SELECT string_agg(quote_literal(command_tag), ', ')
        INTO v_tag_list
        FROM (
            VALUES
            ('ALTER AGGREGATE', 'ALTER'), ('ALTER COLLATION', 'ALTER'), ('ALTER CONVERSION', 'ALTER'),
            ('CREATE TABLE', 'CREATE'), ('DROP TABLE', 'DROP'), ('CREATE FUNCTION', 'CREATE'),
            ('DROP FUNCTION', 'DROP'), ('ALTER TABLE', 'ALTER'), ('CREATE VIEW', 'CREATE'),
            ('DROP VIEW', 'DROP')
        ) AS command_tags(command_tag, type)
        WHERE command_tag ~* p_evento;

        IF v_tag_list IS NULL THEN
            RAISE EXCEPTION 'Evento "%", no es válido para auditoría DDL.', p_evento;
        END IF;

        v_trigger_condition := format('WHEN TAG IN (%s)', v_tag_list);
    END IF;

    -- Generar código de función y trigger DDL
    v_ddl_code := format($_code$
        CREATE OR REPLACE FUNCTION %s()
        RETURNS event_trigger
        LANGUAGE plpgsql
        AS $_inner$
        DECLARE
            v_object_identity TEXT;
        BEGIN
            SELECT object_identity INTO v_object_identity FROM pg_event_trigger_ddl_commands();
            %s
                INSERT INTO cdc.audit(
                    audit_type, operation, object_name, user_name, client_ip, query, date
                )
                SELECT
                    'ddl',
                    TG_TAG,
                    v_object_identity,
                    SESSION_USER,
                    COALESCE(host(inet_client_addr()), 'unix_socket')::TEXT,
                    current_query(),
                    CLOCK_TIMESTAMP();
            %s
        END;
        $_inner$;

        CREATE EVENT TRIGGER %I
        ON ddl_command_end
        %s
        EXECUTE FUNCTION %s();
    $_code$,
        v_func_name,
        v_validacion_objeto,
        CASE WHEN v_validacion_objeto <> '' THEN 'END IF;' ELSE '' END,
        v_trig_name,
        v_trigger_condition,
        v_func_name
    );

    -- Imprimir el código generado
    RAISE NOTICE '%', v_ddl_code;

    -- Ejecutar si se indicó
    IF p_ejecutar THEN
        BEGIN
			EXECUTE v_ddl_code;
			RAISE NOTICE E'\n\n SE EJECUTO EXITOSAMENTE LA FUNCION Y TRIGGER\n\n';
		EXCEPTION
			WHEN OTHERS THEN
				RAISE NOTICE '%', SQLERRM;

		END;
    END IF;

	
END;
$_$;
