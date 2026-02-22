/*
 @Function: audit.fn_trg_register_dml
 @Creation Date: 22/05/2024
 @Description: Trigger function para auditoría granular de la tabla cat_servidores. 
                Registra cambios (INSERT, UPDATE, DELETE) en audit.cat_servidores.
 @Parameters:
   - N/A (Trigger Function)
 @Returns: trigger - Registro procesado (OLD/NEW)
 @Author: CR0NYM3X
 ---------------- HISTORY ----------------
 @Date: 22/05/2024
 @Change: Refactorización para optimizar rendimiento usando operadores JSONB y search_path seguro.
 @Author: CR0NYM3X
*/

---------------- DDL ----------------
CREATE SCHEMA IF NOT EXISTS audit;

-- truncate TABLE audit.cat_servidores RESTART IDENTITY ;
CREATE TABLE IF NOT EXISTS audit.cat_servidores (
    id_log          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_origen       integer, -- ID original de la tabla maestra
  
    -- Datos de la Operación
    operacion       text NOT NULL CHECK (operacion IN ('INSERT', 'UPDATE', 'DELETE','TRUNCATE')),
    fecha_cambio    timestamptz NOT NULL DEFAULT clock_timestamp(),
    
    -- Payload de Datos (JSONB para flexibilidad y búsqueda)
    valor_anterior  jsonb,
    valor_nuevo      jsonb,
    
    -- Trazabilidad de Sesión
    usuario         text NOT NULL DEFAULT session_user,
    ip_cliente      text,
    query           text
     
);
 
 

---------------- COMMENT ----------------
COMMENT ON TABLE audit.cat_servidores IS 'Histórico de auditoría optimizado para cat_servidores.';
COMMENT ON COLUMN audit.cat_servidores.id_origen IS 'Llave primaria de la tabla original (public.cat_servidores).';
COMMENT ON TABLE audit.cat_servidores IS 'Histórico de auditoría de la tabla cat_servidores.';
COMMENT ON COLUMN audit.cat_servidores.id_log IS 'ID único de la entrada de auditoría.';
COMMENT ON COLUMN audit.cat_servidores.valor_anterior IS 'Estado de la fila antes del cambio (Solo en UPDATE/DELETE).';
COMMENT ON COLUMN audit.cat_servidores.valor_nuevo IS 'Estado de la fila después del cambio (Solo en INSERT/UPDATE).';
COMMENT ON COLUMN audit.cat_servidores.id_origen IS 'Llave primaria de la tabla original (public.cat_servidores).';


CREATE OR REPLACE FUNCTION audit.fn_trg_register_dml()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
DECLARE
    -- Diagnóstico
    ex_message      text;
    ex_context      text;
    
    -- Variables de Auditoría
    v_old_jsonb     jsonb;
    v_new_jsonb     jsonb;
    v_diff_old      jsonb := '{}';
    v_diff_new      jsonb := '{}';
    v_query         text := current_query();
    v_client_ip     text := COALESCE(host(inet_client_addr()), '127.0.0.1');
BEGIN

    -- 2. Procesamiento por tipo de operación
    IF TG_OP = 'INSERT' THEN
        v_new_jsonb := to_jsonb(NEW);
        
        INSERT INTO audit.cat_servidores (
            id_origen, operacion, valor_anterior, valor_nuevo, usuario, 
            ip_cliente, query
        )
        VALUES (
            NEW.id, 'INSERT', NULL, v_new_jsonb, session_user, 
            v_client_ip, v_query
        );
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        v_old_jsonb := to_jsonb(OLD);
        
        INSERT INTO audit.cat_servidores (
            id_origen, operacion, valor_anterior, valor_nuevo, usuario, 
            ip_cliente, query
        )
        VALUES (
            OLD.id, 'DELETE', v_old_jsonb, NULL, session_user, 
            v_client_ip, v_query
        );
        RETURN OLD;

    ELSIF TG_OP = 'UPDATE' THEN
        v_old_jsonb := to_jsonb(OLD);
        v_new_jsonb := to_jsonb(NEW);

        -- Diferencia simétrica para guardar solo lo que cambió
        SELECT 
            jsonb_object_agg(key, value),
            jsonb_object_agg(key, (v_new_jsonb -> key))
        INTO v_diff_old, v_diff_new
        FROM jsonb_each(v_old_jsonb)
        WHERE (v_new_jsonb -> key) IS DISTINCT FROM value;

        -- Solo insertar si hay cambios reales en los datos
        IF v_diff_new IS NOT NULL THEN
            INSERT INTO audit.cat_servidores (
                id_origen, operacion, valor_anterior, valor_nuevo, usuario, 
                ip_cliente, query
            )
            VALUES (
                OLD.id, 'UPDATE', v_diff_old, v_diff_new, session_user, 
                v_client_ip, v_query
            );
        END IF;
        RETURN NEW;
    END IF;

    RETURN NULL;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS 
            ex_message = MESSAGE_TEXT,
            ex_context = PG_EXCEPTION_CONTEXT;
        RAISE WARNING 'Error en audit.fn_trg_register_dml: % | Contexto: %', ex_message, ex_context;
        RETURN COALESCE(NEW, OLD); 
END;
$func$;

-- Ajuste de seguridad: Fija search_path y quita permisos públicos
ALTER FUNCTION audit.fn_trg_register_dml() SET search_path TO audit, public, pg_temp;
REVOKE EXECUTE ON FUNCTION audit.fn_trg_register_dml() FROM PUBLIC;


---------------- COMMENT ----------------
COMMENT ON FUNCTION audit.fn_trg_register_dml() IS
'Función de trigger para auditoría de cat_servidores.
- Parámetros: Ninguno (Uso interno de trigger)
- Retorno: TRIGGER
- Volatilidad: VOLATILE
- Seguridad: SECURITY DEFINER con search_path fijo.
- Notas: Optimizado para evitar bucles sobre information_schema. Filtra exclusiones por query string.';



------------------------------------------------------------  EJEMPLO ------------------------------------------------------------
---------------- DDL SIMPLIFICADO ----------------
 -- DROP TABLE public.cat_servidores ;
CREATE TABLE IF NOT EXISTS public.cat_servidores (
    id              integer PRIMARY KEY,
    ip_server       character varying(25),
    puerto          integer,
    hostname        character varying(100),
    ambiente        character varying(100),
    dba_asignado    character varying(500)
);


-- DROP TRIGGER IF EXISTS trg_auditoria_cat_servidores ON public.cat_servidores;
CREATE TRIGGER trg_auditoria_cat_servidores
AFTER INSERT OR UPDATE OR DELETE ON public.cat_servidores
FOR EACH ROW EXECUTE FUNCTION audit.fn_trg_register_dml();



INSERT INTO public.cat_servidores (id, ip_server, puerto, hostname, ambiente, dba_asignado)
VALUES (1, '192.168.1.10', 5432, 'srv-db-prod-01', 'PRODUCCION', 'JORGE_DBA');


UPDATE public.cat_servidores 
SET dba_asignado = 'CR0NYM3X', ambiente = 'MANTENIMIENTO'
WHERE id = 1;

DELETE FROM public.cat_servidores WHERE id = 1;


SELECT 
    *
FROM audit.cat_servidores
ORDER BY fecha_cambio asc;
