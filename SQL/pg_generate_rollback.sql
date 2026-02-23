CREATE SCHEMA IF NOT EXISTS audit;

CREATE OR REPLACE FUNCTION audit.pg_generate_rollback(
    p_audit_table text,
    p_id_log      bigint
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $body$
DECLARE
    r_audit       record;
    v_sql         text := '';
    v_cols        text := '';
    v_vals        text := '';
    v_updates     text := '';
    r_json        record;
    v_schema_orig text;
    v_table_orig  text;
    v_pk_col      text;
BEGIN
    -- 1. Obtener los metadatos de la tabla monitoreada
    SELECT schema_name,  COALESCE(audit_table_name, schema_name || '_' || table_name) as table_name, pk_column 
    INTO v_schema_orig, v_table_orig, v_pk_col
    FROM audit.dml_inventory 
    WHERE audit_table_name = p_audit_table 
    LIMIT 1;



    IF NOT FOUND THEN
        RAISE EXCEPTION 'La tabla % no está registrada en dml_inventory', p_audit_table;
    END IF;

    -- 2. Obtener el registro de auditoría
    EXECUTE format('SELECT * FROM audit.%I WHERE id_log = $1', p_audit_table)
    INTO r_audit USING p_id_log;

    IF r_audit.id_log IS NULL THEN
        RAISE EXCEPTION 'No se encontró el id_log % en audit.%', p_id_log, p_audit_table;
    END IF;

    -- 3. Generar SQL según la operación original
    CASE r_audit.operacion
            WHEN 'DELETE' THEN
            -- USAMOS jsonb_each_text para evitar las dobles comillas en strings
            SELECT string_agg(format('%I', key), ', '),
                   string_agg(format('%L', value), ', ')
            INTO v_cols, v_vals
            FROM jsonb_each_text(r_audit.valor_anterior); -- <-- Cambiado a _text

            v_sql := format('INSERT INTO %I.%I (%s) VALUES (%s);', 
                            v_schema_orig, v_table_orig, v_cols, v_vals);

        WHEN 'UPDATE' THEN
            -- También aquí usamos _text para que el SET nombre = 'Empresa X' sea limpio
            SELECT string_agg(format('%I = %L', key, value), ', ')
            INTO v_updates
            FROM jsonb_each_text(r_audit.valor_anterior); -- <-- Cambiado a _text

            v_sql := format('UPDATE %I.%I SET %s WHERE %I = %L;', 
                            v_schema_orig, v_table_orig, v_updates, v_pk_col, r_audit.id_origen);

        WHEN 'INSERT' THEN
            v_sql := format('DELETE FROM %I.%I WHERE %I = %L;', 
                            v_schema_orig, v_table_orig, v_pk_col, r_audit.id_origen);

        WHEN 'TRUNCATE' THEN
            v_sql := '-- El ROLLBACK de TRUNCATE no es posible desde logs granulares. Use Backup de disco.';
    END CASE;

    RETURN v_sql;

EXCEPTION WHEN OTHERS THEN
    RETURN 'Error generando Rollback: ' || SQLERRM;
END;
$body$;

-- Seguridad  Asegurar search_path
ALTER FUNCTION audit.pg_generate_rollback(text, bigint) SET search_path TO audit, public, pg_temp;

-- Revocar ejecución pública
REVOKE EXECUTE ON FUNCTION audit.pg_generate_rollback(text, bigint) FROM PUBLIC;


 


/*
-- Colocamos el nombre de la tabla que audit_table_name que aparece en la tabla audit.dml_inventory y el id_log que queremos hacerle rollback
SELECT audit.pg_generate_rollback('public_clientes', 1);
SELECT audit.pg_generate_rollback('public_clientes', 2);
SELECT audit.pg_generate_rollback('public_clientes', 3);
SELECT audit.pg_generate_rollback('public_clientes', 4);


postgres@test#  SELECT id_log,operacion,audit.pg_generate_rollback('public_clientes',id_log) FROM audit.public_clientes;
+--------+-----------+-------------------------------------------------------------------------------------------------+
| id_log | operacion |                                      pg_generate_rollback                                       |
+--------+-----------+-------------------------------------------------------------------------------------------------+
|      1 | INSERT    | DELETE FROM public.public_clientes WHERE id_cli = '101';                                        |
|      2 | UPDATE    | UPDATE public.public_clientes SET saldo = '5000', nombre = 'Empresa X' WHERE id_cli = '101';    |
|      3 | DELETE    | INSERT INTO public.public_clientes (saldo, id_cli, nombre) VALUES ('6000', '101', 'Empresa Y'); |
|      4 | TRUNCATE  | -- El ROLLBACK de TRUNCATE no es posible desde logs granulares. Use Backup de disco.            |
+--------+-----------+-------------------------------------------------------------------------------------------------+
(4 rows)



*/
