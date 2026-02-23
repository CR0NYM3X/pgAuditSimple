# Explicación 
hacer una auditoria para select en postgresql es una tarea dificil y hasta el momento no existe como hacerlo de una forma nativa sin sacrificar el rendimiento de nuestro servidor 


### 1. ¿Por qué no con Trigger?

**La respuesta corta:** Porque en PostgreSQL **no existen los Triggers para el evento `SELECT**`.

* **Explicación:** Los triggers están diseñados exclusivamente para eventos de modificación de datos (`INSERT`, `UPDATE`, `DELETE` y `TRUNCATE`). El motor de Postgres no tiene un "gancho" (hook) de trigger que se dispare cuando un usuario simplemente lee una tabla. Intentar crear uno para `SELECT` te daría un error de sintaxis inmediatamente.

### 2. ¿Por qué no con Rule?

**La respuesta corta:** Porque las Rules son para **reescribir consultas**, no para ejecutar acciones secundarias fiables.

* **Explicación:** Una `RULE` de tipo `ON SELECT` transforma la consulta original en otra (así funcionan las vistas). Aunque podrías intentar "inyectar" un `INSERT` mediante reglas complejas, es extremadamente frágil, arruina el rendimiento del optimizador y, lo más importante, **no puede garantizar** que el insert ocurra exactamente una vez por cada consulta de lectura de forma limpia.

---

### Resumen :

> "Elegí **RLS (Row Level Security)** porque es el único mecanismo nativo que permite interceptar una lectura a nivel de fila y condicionarla a la ejecución de una función. Los **Triggers** no soportan `SELECT` y las **Rules** están diseñadas para transformar la estructura de la consulta, no para generar logs de auditoría seguros."

 

### ❌ Desventajas principales

* **Vulnerable al Rollback:** Si el usuario cancela la transacción o hay un error, el log de auditoría **desaparece** (se borra con el rollback).
* **Punto Ciego Transaccional:** Como validas por `txid`, si una misma transacción hace 5 consultas distintas, **solo se grabará la primera**.
* **Falso Positivo de Lectura:** Si la consulta se ejecuta pero no devuelve filas, el log **se inserta igual** (porque la política se evalúa antes de filtrar).
* **Carga en Escritura:** Transformas una operación de "solo lectura" en una de "escritura", lo que genera tráfico innecesario en los archivos WAL y disco.
* **Riesgo de Bloqueo:** Si la tabla de auditoría se bloquea o se llena, **nadie podrá leer** la tabla de clientes (el `SELECT` fallará).
* **Privacidad en Logs:** `current_query()` puede guardar datos sensibles (como filtros con contraseñas o números de tarjeta) en texto plano dentro del log.
* **Inmunidad de Superusuarios:** Aunque quites `BYPASSRLS`, el superusuario siempre tiene formas de evadir estas capas si no se fuerza `FORCE ROW LEVEL SECURITY` correctamente.

### ✅ Recomendación rápida

Para un entorno real, usa **pgAudit**. Escribe en logs del sistema fuera de la base de datos, es inmune al `ROLLBACK` y no afecta el rendimiento de las consultas.


```SQL



 -- Tabla con datos sensibles
CREATE TABLE clientes (
    id SERIAL PRIMARY KEY,
    nombre TEXT,
    tarjeta_credito TEXT
);

-- Tabla de auditoría
CREATE TABLE auditoria_accesos (
    id SERIAL PRIMARY KEY,
    usuario TEXT,
    fecha TIMESTAMP DEFAULT now(),
    query_ejecutada TEXT
);

-- Insertamos datos de prueba
INSERT INTO clientes (nombre, tarjeta_credito) VALUES 
('Juan Perez', '4540-1234-5678-9012'),
('Maria Lopez', '5412-8765-4321-0000');


CREATE OR REPLACE FUNCTION registrar_y_consultar() 
RETURNS boolean AS $$
DECLARE
    v_tx_id text;
    v_audit_check text;
BEGIN
    -- Obtenemos el ID de la transacción actual
    v_tx_id := txid_current()::text;

    -- Intentamos obtener una variable de sesión personalizada
    -- El prefijo 'audit' debe ser algo único. 
    -- 'current_setting' fallará si la variable no existe, por eso usamos el segundo parámetro 'true'
    v_audit_check := current_setting('audit.last_tx_id', true);

    -- Si la variable no coincide con la transacción actual, auditamos
    IF v_audit_check IS NULL OR v_audit_check != v_tx_id THEN
        
        -- Insertamos UNA SOLA VEZ para esta consulta/transacción
        INSERT INTO auditoria_accesos (usuario, query_ejecutada)
        VALUES (current_user, current_query());

        -- Guardamos el ID de la transacción en la memoria de la sesión
        -- 'false' significa que la variable persistirá solo durante la sesión
        PERFORM set_config('audit.last_tx_id', v_tx_id, false);
    END IF;

    RETURN true; 
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Habilitamos la seguridad de nivel de fila
ALTER TABLE clientes ENABLE ROW LEVEL SECURITY;

-- el usuario que creó la tabla clientes se salta el RLS. Si quieres que incluso el dueño de la tabla sea auditado por tu política
ALTER TABLE clientes FORCE ROW LEVEL SECURITY;

-- Creamos la política que se ejecuta en cada SELECT
CREATE POLICY politica_auditoria_clientes 
    ON clientes 
    FOR SELECT 
    USING (registrar_y_consultar());
	


-- Creamos un usuario de prueba
CREATE USER empleado_ventas;
GRANT SELECT ON clientes TO empleado_ventas;
GRANT INSERT ON auditoria_accesos TO empleado_ventas; -- Necesario para el log
GRANT USAGE, SELECT ON SEQUENCE auditoria_accesos_id_seq TO empleado_ventas;

-- Simulamos que entramos como ese usuario
SET ROLE empleado_ventas;

-- El usuario hace una consulta
SELECT * FROM clientes WHERE id = 1;

-- Volvemos a nuestro usuario administrador para ver si se grabó el log
RESET ROLE;
SELECT * FROM auditoria_accesos;


ALTER ROLE postgres NOBYPASSRLS;
select rolbypassrls from pg_authid where rolname = 'postgres';


```
