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
            (1, 'ALTER AGGREGATE', 'ALTER'),
            (2, 'ALTER COLLATION', 'ALTER'),
            (3, 'ALTER CONVERSION', 'ALTER'),
            (4, 'ALTER DOMAIN', 'ALTER'),
            (5, 'ALTER DEFAULT PRIVILEGES', 'ALTER'),
            (6, 'ALTER EXTENSION', 'ALTER'),
            (7, 'ALTER FOREIGN DATA WRAPPER', 'ALTER'),
            (8, 'ALTER FOREIGN TABLE', 'ALTER'),
            (9, 'ALTER FUNCTION', 'ALTER'),
            (10, 'ALTER LANGUAGE', 'ALTER'),
            (11, 'ALTER LARGE OBJECT', 'ALTER'),
            (12, 'ALTER MATERIALIZED VIEW', 'ALTER'),
            (13, 'ALTER OPERATOR', 'ALTER'),
            (14, 'ALTER OPERATOR CLASS', 'ALTER'),
            (15, 'ALTER OPERATOR FAMILY', 'ALTER'),
            (16, 'ALTER POLICY', 'ALTER'),
            (17, 'ALTER PROCEDURE', 'ALTER'),
            (18, 'ALTER PUBLICATION', 'ALTER'),
            (19, 'ALTER ROUTINE', 'ALTER'),
            (20, 'ALTER SCHEMA', 'ALTER'),
            (21, 'ALTER SEQUENCE', 'ALTER'),
            (22, 'ALTER SERVER', 'ALTER'),
            (23, 'ALTER STATISTICS', 'ALTER'),
            (24, 'ALTER SUBSCRIPTION', 'ALTER'),
            (25, 'ALTER TABLE', 'ALTER'),
            (26, 'ALTER TEXT SEARCH CONFIGURATION', 'ALTER'),
            (27, 'ALTER TEXT SEARCH DICTIONARY', 'ALTER'),
            (28, 'ALTER TEXT SEARCH PARSER', 'ALTER'),
            (29, 'ALTER TEXT SEARCH TEMPLATE', 'ALTER'),
            (30, 'ALTER TRIGGER', 'ALTER'),
            (31, 'ALTER TYPE', 'ALTER'),
            (32, 'ALTER USER MAPPING', 'ALTER'),
            (33, 'ALTER VIEW', 'ALTER'),
            (34, 'COMMENT', 'COMMENT'),
            (35, 'CREATE ACCESS METHOD', 'CREATE'),
            (36, 'CREATE AGGREGATE', 'CREATE'),
            (37, 'CREATE CAST', 'CREATE'),
            (38, 'CREATE COLLATION', 'CREATE'),
            (39, 'CREATE CONVERSION', 'CREATE'),
            (40, 'CREATE DOMAIN', 'CREATE'),
            (41, 'CREATE EXTENSION', 'CREATE'),
            (42, 'CREATE FOREIGN DATA WRAPPER', 'CREATE'),
            (43, 'CREATE FOREIGN TABLE', 'CREATE'),
            (44, 'CREATE FUNCTION', 'CREATE'),
            (45, 'CREATE INDEX', 'CREATE'),
            (46, 'CREATE LANGUAGE', 'CREATE'),
            (47, 'CREATE MATERIALIZED VIEW', 'CREATE'),
            (48, 'CREATE OPERATOR', 'CREATE'),
            (49, 'CREATE OPERATOR CLASS', 'CREATE'),
            (50, 'CREATE OPERATOR FAMILY', 'CREATE'),
            (51, 'CREATE POLICY', 'CREATE'),
            (52, 'CREATE PROCEDURE', 'CREATE'),
            (53, 'CREATE PUBLICATION', 'CREATE'),
            (54, 'CREATE RULE', 'CREATE'),
            (55, 'CREATE SCHEMA', 'CREATE'),
            (56, 'CREATE SEQUENCE', 'CREATE'),
            (57, 'CREATE SERVER', 'CREATE'),
            (58, 'CREATE STATISTICS', 'CREATE'),
            (59, 'CREATE SUBSCRIPTION', 'CREATE'),
            (60, 'CREATE TABLE', 'CREATE'),
            (61, 'CREATE TABLE AS', 'CREATE'),
            (62, 'CREATE TEXT SEARCH CONFIGURATION', 'CREATE'),
            (63, 'CREATE TEXT SEARCH DICTIONARY', 'CREATE'),
            (64, 'CREATE TEXT SEARCH PARSER', 'CREATE'),
            (65, 'CREATE TEXT SEARCH TEMPLATE', 'CREATE'),
            (66, 'CREATE TRIGGER', 'CREATE'),
            (67, 'CREATE TYPE', 'CREATE'),
            (68, 'CREATE USER MAPPING', 'CREATE'),
            (69, 'CREATE VIEW', 'CREATE'),
            (70, 'DROP ACCESS METHOD', 'DROP'),
            (71, 'DROP AGGREGATE', 'DROP'),
            (72, 'DROP CAST', 'DROP'),
            (73, 'DROP COLLATION', 'DROP'),
            (74, 'DROP CONVERSION', 'DROP'),
            (75, 'DROP DOMAIN', 'DROP'),
            (76, 'DROP EXTENSION', 'DROP'),
            (77, 'DROP FOREIGN DATA WRAPPER', 'DROP'),
            (78, 'DROP FOREIGN TABLE', 'DROP'),
            (79, 'DROP FUNCTION', 'DROP'),
            (80, 'DROP INDEX', 'DROP'),
            (81, 'DROP LANGUAGE', 'DROP'),
            (82, 'DROP MATERIALIZED VIEW', 'DROP'),
            (83, 'DROP OPERATOR', 'DROP'),
            (84, 'DROP OPERATOR CLASS', 'DROP'),
            (85, 'DROP OPERATOR FAMILY', 'DROP'),
            (86, 'DROP OWNED', 'DROP'),
            (87, 'DROP POLICY', 'DROP'),
            (88, 'DROP PROCEDURE', 'DROP'),
            (89, 'DROP PUBLICATION', 'DROP'),
            (90, 'DROP ROUTINE', 'DROP'),
            (91, 'DROP RULE', 'DROP'),
            (92, 'DROP SCHEMA', 'DROP'),
            (93, 'DROP SEQUENCE', 'DROP'),
            (94, 'DROP SERVER', 'DROP'),
            (95, 'DROP STATISTICS', 'DROP'),
            (96, 'DROP SUBSCRIPTION', 'DROP'),
            (97, 'DROP TABLE', 'DROP'),
            (98, 'DROP TEXT SEARCH CONFIGURATION', 'DROP'),
            (99, 'DROP TEXT SEARCH DICTIONARY', 'DROP'),
            (100, 'DROP TEXT SEARCH PARSER', 'DROP'),
            (101, 'DROP TEXT SEARCH TEMPLATE', 'DROP'),
            (102, 'DROP TRIGGER', 'DROP'),
            (103, 'DROP TYPE', 'DROP'),
            (104, 'DROP USER MAPPING', 'DROP'),
            (105, 'DROP VIEW', 'DROP'),
            (106, 'GRANT', 'GRANT'),
            (107, 'IMPORT FOREIGN SCHEMA', 'IMPORT'),
            (108, 'REFRESH MATERIALIZED VIEW', 'REFRESH'),
            (109, 'REINDEX', 'REINDEX'),
            (110, 'REVOKE', 'REVOKE'),
            (111, 'SECURITY LABEL', 'SECURITY'),
            (112, 'SELECT INTO', 'SELECT')
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
