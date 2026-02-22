
# 🚀 PostgreSQL Advanced Audit Framework (PAAF)

Este framework con funciones que nos permite el rastreo de cambios en bases de datos PostgreSQL. Diseñado para DBAs y desarrolladores que necesitan **trazabilidad total** con un impacto mínimo en la configuración.

---

## 📂 Estructura e Instalación

El framework se compone de tres módulos principales. Para instalarlos de una sola exhibición, utiliza el comando `psql` desde tu terminal:

```bash
# Instalación masiva de los tres componentes principales
psql -h localhost -U postgres -d test -f pg_deploy_audit_ddl.sql
psql -h localhost -U postgres -d test -f pg_deploy_audit_dml.sql
psql -h localhost -U postgres -d test -f pg_generate_rollback.sql
```

## ⚖️ Ventajas y Desventajas

| Ventajas | Desventajas |
| --- | --- |
| **Despliegue Instantáneo:** Una sola línea de código activa la auditoría por tabla. | **Almacenamiento:** En tablas con millones de cambios, el esquema `audit` crecerá considerablemente. |
| **Rollback Quirúrgico:** Genera SQL para restaurar filas individuales sin usar Backups. | **Impacto en Write:** Los triggers `AFTER ROW` añaden una mínima latencia en operaciones de escritura. |
| **Configurable:** Puedes excluir aplicaciones (ej. `pg_cron`) o comandos específicos. | **Complejidad JSONB:** Requiere conocimientos básicos de JSONB para consultas manuales complejas. |
| **Seguridad:** Ejecución bajo `SECURITY DEFINER` para evitar manipulaciones de usuarios. |  |


## 🎯 ¿Dónde usarlo y dónde no?

### ✅ Usar en:

* **Tablas Maestras:** Catálogos de clientes, productos, configuraciones de servidores.
* **Entornos de Producción:** Donde saber "quién cambió qué" es crítico para el negocio.
* **Bases de Datos con múltiples administradores:** Para control de cambios DDL.

### ❌ No usar en:

* **Tablas de Logs/Temporales:** Tablas que reciben miles de registros por segundo (ej. logs de sensores).
* **Cargas Masivas:** Desactivar antes de procesos de ETL masivos para evitar saturación de logs.
* **Bases de Datos con poco espacio en disco:** Sin una política de depuración (retention policy).

---

## 🛠 Requisitos del Sistema

Para garantizar el funcionamiento de las operaciones JSONB avanzadas y los triggers de eventos, se requiere:

* **Versión Mínima:** PostgreSQL 12.0+ (Soporta desde 10.0 con ajustes menores).
* **Extensiones:** Ninguna externa (Usa PL/pgSQL nativo).
* **Privilegios:** Superusuario o permisos para crear `EVENT TRIGGERS` y esquemas.



## ⚡ Auditoría de Datos (DML)

Captura cambios a nivel de fila (INSERT, UPDATE, DELETE, TRUNCATE) de forma automática.

### Ejemplo de Ejecución:

```sql
-- Creamos una tabla de ejemplo
CREATE TABLE public.clientes (id_cli serial PRIMARY KEY, nombre text, saldo numeric);

-- Desplegamos auditoría 'all'
SELECT public.pg_deploy_audit_dml('public', 'clientes', 'id_cli', 'all');

-- Operamos
INSERT INTO public.clientes VALUES (101, 'Empresa X', 5000);
UPDATE public.clientes SET saldo = 6000, nombre = 'Empresa Y' WHERE id_cli = 101;
DELETE FROM public.clientes WHERE id_cli = 101;
TRUNCATE TABLE public.clientes;

```

### Salida Esperada en `audit.clientes`:

```text
postgres@test# SELECT * FROM audit.clientes;
+-[ RECORD 1 ]---+----------------------------------------------------------------------------------+
| id_log         | 1                                                                                |
| id_origen      | 101                                                                              |
| operacion      | INSERT                                                                           |
| fecha_cambio   | 2026-02-22 02:55:27.508306-07                                                    |
| valor_anterior | NULL                                                                             |
| valor_nuevo    | {"saldo": 5000, "id_cli": 101, "nombre": "Empresa X"}                            |
| usuario        | postgres                                                                         |
| ip_cliente     | 127.0.0.1                                                                        |
| query          | INSERT INTO public.clientes VALUES (101, 'Empresa X', 5000);                     |
+-[ RECORD 2 ]---+----------------------------------------------------------------------------------+
| id_log         | 2                                                                                |
| id_origen      | 101                                                                              |
| operacion      | UPDATE                                                                           |
| fecha_cambio   | 2026-02-22 02:55:27.510016-07                                                    |
| valor_anterior | {"saldo": 5000, "nombre": "Empresa X"}                                           |
| valor_nuevo    | {"saldo": 6000, "nombre": "Empresa Y"}                                           |
| usuario        | postgres                                                                         |
| ip_cliente     | 127.0.0.1                                                                        |
| query          | UPDATE public.clientes SET saldo = 6000,nombre = 'Empresa Y' WHERE id_cli = 101; |
+-[ RECORD 3 ]---+----------------------------------------------------------------------------------+
| id_log         | 3                                                                                |
| id_origen      | 101                                                                              |
| operacion      | DELETE                                                                           |
| fecha_cambio   | 2026-02-22 02:55:27.511028-07                                                    |
| valor_anterior | {"saldo": 6000, "id_cli": 101, "nombre": "Empresa Y"}                            |
| valor_nuevo    | NULL                                                                             |
| usuario        | postgres                                                                         |
| ip_cliente     | 127.0.0.1                                                                        |
| query          | DELETE FROM public.clientes where id_cli = 101;                                  |
+-[ RECORD 4 ]---+----------------------------------------------------------------------------------+
| id_log         | 4                                                                                |
| id_origen      | NULL                                                                             |
| operacion      | TRUNCATE                                                                         |
| fecha_cambio   | 2026-02-22 02:55:27.512541-07                                                    |
| valor_anterior | {"info": "Tabla vaciada"}                                                        |
| valor_nuevo    | NULL                                                                             |
| usuario        | postgres                                                                         |
| ip_cliente     | 127.0.0.1                                                                        |
| query          | TRUNCATE TABLE public.clientes;                                                  |
+----------------+----------------------------------------------------------------------------------+

```

---

## 🕰️ Recuperación de Datos (Time-Travel)

Genera dinámicamente el SQL necesario para revertir cualquier cambio.

```sql
-- Consultas de Rollback
SELECT audit.fn_sql_time_travel('clientes', 1); -- Revierte el INSERT (hace un DELETE)
SELECT audit.fn_sql_time_travel('clientes', 2); -- Revierte el UPDATE (restaura valores)
SELECT audit.fn_sql_time_travel('clientes', 3); -- Revierte el DELETE (hace un INSERT)
SELECT audit.pg_generate_rollback('clientes', 4); -- Es el Truncate
```

### Salida del Generador:

```text
postgres@test#  SELECT audit.pg_generate_rollback('clientes', 1);
+---------------------------------------------------+
|               pg_generate_rollback                |
+---------------------------------------------------+
| DELETE FROM public.clientes WHERE id_cli = '101'; |
+---------------------------------------------------+
(1 row)

postgres@test#  SELECT audit.pg_generate_rollback('clientes', 2);
+---------------------------------------------------------------------------------------+
|                                 pg_generate_rollback                                  |
+---------------------------------------------------------------------------------------+
| UPDATE public.clientes SET saldo = '5000', nombre = 'Empresa X' WHERE id_cli = '101'; |
+---------------------------------------------------------------------------------------+
(1 row)

postgres@test#  SELECT audit.pg_generate_rollback('clientes', 3);
+------------------------------------------------------------------------------------------+
|                                   pg_generate_rollback                                   |
+------------------------------------------------------------------------------------------+
| INSERT INTO public.clientes (saldo, id_cli, nombre) VALUES ('6000', '101', 'Empresa Y'); |
+------------------------------------------------------------------------------------------+
(1 row)

postgres@test#  SELECT audit.pg_generate_rollback('clientes', 4);
+--------------------------------------------------------------------------------------+
|                                 pg_generate_rollback                                 |
+--------------------------------------------------------------------------------------+
| -- El ROLLBACK de TRUNCATE no es posible desde logs granulares. Use Backup de disco. |
+--------------------------------------------------------------------------------------+
(1 row)

```

---

## 🏛️ Auditoría de Estructura (DDL)

Control total sobre cambios en el esquema. Incluye filtrado por aplicación y matriz de comandos.

### Ejemplo de Configuración y Filtrado:

```text
postgres@test# SELECT public.pg_deploy_audit_ddl();
+---------------------------------------------------------------------------------+
|                               pg_deploy_audit_ddl                               |
+---------------------------------------------------------------------------------+
| Motor de Auditoría DDL instalado/actualizado correctamente en el esquema audit. |
+---------------------------------------------------------------------------------+

postgres@test# CREATE TABLE test_a(id int); DROP TABLE test_a;

postgres@test# SELECT id, app_name, event, object_name, query FROM audit.ddl_history;
+----+----------+--------------+---------------+------------------------------+
| id | app_name |    event     |  object_name  |            query             |
+----+----------+--------------+---------------+------------------------------+
|  1 | psql     | CREATE TABLE | public.test_a | CREATE TABLE test_a(id int); |
|  2 | psql     | DROP TABLE   | public.test_a | DROP TABLE test_a;           |
+----+----------+--------------+---------------+------------------------------+

```

### Filtros Avanzados:

* **Exclusión de Apps (ej. pg_cron) en audit DDL:**
`SELECT * FROM audit.conf_excluded_apps;`
*(Si el app_name coincide, no se genera registro para evitar ruido).*
* **Desactivar Comandos Específicos DDL:**
`UPDATE audit.conf_event_matrix SET is_active = false WHERE command_tag = 'DROP TABLE';`

 
 


**Desarrollado por:** `CR0NYM3X` | **Fecha:** 2026

 
# Referencias
```

--------------- audit ---------
https://github.com/cmabastar/audit-trigger/blob/master/audit.sql
https://github.com/2ndQuadrant/audit-trigger
https://wiki.postgresql.org/wiki/Audit_trigger
https://github.com/iloveitaly/audit-trigger
https://github.com/supabase/supa_audit
https://ttu.github.io/postgres-simple-audit-trail/

https://medium.com/israeli-tech-radar/postgresql-trigger-based-audit-log-fd9d9d5e412c
https://www.tigerdata.com/learn/what-is-audit-logging-and-how-to-enable-it-in-postgresql

--- Forma de hacer un trigger para login
https://www.dbi-services.com/blog/postgresql-17-login-event-triggers/


```
