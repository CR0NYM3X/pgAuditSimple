
-- DROP FUNCTION audit.pg_undeploy_audit_dml(bigint);
CREATE OR REPLACE FUNCTION audit.pg_undeploy_audit_dml(
    p_id_monitored bigint
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $undeploy$
DECLARE
    v_inv_rec      RECORD;
    v_trigger_func text;
    v_trunc_func   text;
    v_sql          text;
BEGIN
    -- 1. Buscar el registro en el inventario de control
    SELECT * INTO v_inv_rec 
    FROM audit.dml_inventory 
    WHERE id_monitored = p_id_monitored;

    -- Si el ID no existe, salimos inmediatamente de forma segura
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El id_monitored % no existe en el inventario de auditoría.', p_id_monitored;
    END IF;

    -- 2. Construir los nombres de los objetos asociados estrictamente a esta configuración
    v_trigger_func := 'fn_trg_audit_' || v_inv_rec.audit_table_name;
    v_trunc_func   := 'fn_trg_trunc_' || v_inv_rec.audit_table_name;

    -- 3. REMOVER TRIGGERS DE LA TABLA MAESTRA/PRODUCTIVA
    -- Esto detiene la captura de datos de inmediato y de forma segura
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_dml_%s ON %I.%I', 
                    v_inv_rec.audit_table_name, v_inv_rec.schema_name, v_inv_rec.table_name);
                    
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_trunc_%s ON %I.%I', 
                    v_inv_rec.audit_table_name, v_inv_rec.schema_name, v_inv_rec.table_name);

    -- 4. REMOVER FUNCIONES DE TRIGGER HUÉRFANAS
    -- Limpia el catálogo de funciones del esquema 'audit'
    EXECUTE format('DROP FUNCTION IF EXISTS audit.%I()', v_trigger_func);
    EXECUTE format('DROP FUNCTION IF EXISTS audit.%I()', v_trunc_func);

    -- 5. ELIMINAR LA TABLA ESPEJO DE AUDITORÍA
    -- Borra la tabla física que guardaba los logs de este monitoreo
    EXECUTE format('DROP TABLE IF EXISTS audit.%I CASCADE', v_inv_rec.audit_table_name);

    -- 6. LIMPIAR EL REGISTRO DEL INVENTARIO
    -- Se elimina la fila de la tabla de control para cerrar el ciclo de vida del objeto
    DELETE FROM audit.dml_inventory 
    WHERE id_monitored = p_id_monitored;

    -- 7. Retornar mensaje de éxito con el detalle de lo removido
    RETURN format('Auditoría removida por completo para la tabla %s.%s. Se eliminó la tabla espejo audit.%s, sus triggers y funciones asociadas.', 
                  v_inv_rec.schema_name, v_inv_rec.table_name, v_inv_rec.audit_table_name);

EXCEPTION 
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error crítico al desmantelar la auditoría id_monitored %: %', p_id_monitored, SQLERRM;
END;
$undeploy$;

-- Seguridad: Asegurar el search_path para evitar ataques de inyección de código
ALTER FUNCTION audit.pg_undeploy_audit_dml(bigint) SET search_path TO audit, public, pg_temp;

-- Revocar la ejecución pública por seguridad
REVOKE EXECUTE ON FUNCTION audit.pg_undeploy_audit_dml(bigint) FROM PUBLIC;


-- select * from audit.pg_undeploy_audit_dml(1);
