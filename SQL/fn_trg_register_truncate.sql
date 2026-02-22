/*
 @Function: chg_ctl.fn_trg_register_truncate
 @Creation Date: 22/05/2024
 @Description: Trigger function para auditar la ejecución de comandos TRUNCATE.
 @Parameters:
   - N/A (Trigger Function)
 @Returns: trigger
 @Author: CR0NYM3X
 ---------------- HISTORY ----------------
 @Date: 23/05/2024
 @Change: Creación inicial para captura de vaciado de tablas.
 @Author: CR0NYM3X
*/

CREATE OR REPLACE FUNCTION chg_ctl.fn_trg_register_truncate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
DECLARE
    v_query text := current_query();
    v_ip    text := COALESCE(host(inet_client_addr()), '127.0.0.1');
BEGIN
    -- Insertamos el evento de TRUNCATE
    -- id_origen es NULL porque se eliminan todos los registros
    INSERT INTO chg_ctl.cat_servidores (
        id_origen,
        operacion,
        valor_anterior,
        valor_nuevo,
        usuario,
        ip_cliente,
        query
    )
    VALUES (
        NULL,
        'TRUNCATE', -- O puedes usar un check 'TRUNCATE' si alteras el constraint de la tabla
        jsonb_build_object('info', 'Tabla vaciada mediante TRUNCATE'),
        NULL,
        session_user,
        v_ip,
        v_query
    );

    RETURN NULL; -- En triggers STATEMENT el retorno se ignora
END;
$func$;

-- Ajuste de seguridad
ALTER FUNCTION chg_ctl.fn_trg_register_truncate() SET search_path TO chg_ctl, public, pg_temp;

---------------- COMMENT ----------------
COMMENT ON FUNCTION chg_ctl.fn_trg_register_truncate() IS 
'Audita el comando TRUNCATE en la tabla cat_servidores.';

---------------- TRIGGER ----------------
-- Nota: TRUNCATE solo soporta FOR EACH STATEMENT
CREATE TRIGGER trg_auditoria_truncate_cat_servidores
AFTER TRUNCATE ON public.cat_servidores
FOR EACH STATEMENT EXECUTE FUNCTION chg_ctl.fn_trg_register_truncate();


-- 1. Ejecutar el truncate
TRUNCATE TABLE public.cat_servidores;

-- 2. Revisar la auditoría
SELECT * FROM chg_ctl.cat_servidores WHERE operacion = 'TRUNCATE';
