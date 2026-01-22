# ***************** En desarrollo no esta completo **********

Función de auditoría para PostgreSQL  que permite registrar de forma centralizada y sencilla las operaciones DDL y DML realizadas sobre las tablas.

```
-- Cosas por agregar
1.- Agregar que cree una vista en caso de agregar un objeto a monitorear
2.- Cambiar el comportamiento de las tablas default que solo se creen si se especifica en el parametro p_ejecutar
3.- Hacer que identifique el nombre del objeto cuando se elimina un objeto con sql_drop o filtrando la query
4.- Agregar el tipo DML

Begin;

--- tiene problemas con los drop ya que no los registra  ddl_command_end ya que tienes que usar el sql_drop

CREATE TABLE public.clientes (
    id SERIAL PRIMARY KEY,
    nombre TEXT NOT NULL,
    correo TEXT,
    fecha_registro DATE DEFAULT CURRENT_DATE
);

-- Insertar registros de ejemplo
INSERT INTO public.clientes (nombre, correo) VALUES
('Ana Torres', 'ana.torres@example.com'),
('Luis Gómez', 'luis.gomez@example.com'),
('María López', 'maria.lopez@example.com'),
('Carlos Ruiz', 'carlos.ruiz@example.com');




SELECT pgAuditSimple('ddl','alter','clientes', true);



alter table public.clientes add column new_column INT;
create table jose(num int);

\x
select * from cdc.audit  ;


INSERT INTO cdc.obj_audit(object_name) VALUES ('public.jose');
alter table public.jose add column new_column INT;
drop table public.jose;

select * from cdc.audit  ;
select * from cdc.obj_audit;

rollback;



--------------- audit ---------
https://github.com/cmabastar/audit-trigger/blob/master/audit.sql
https://github.com/2ndQuadrant/audit-trigger
https://wiki.postgresql.org/wiki/Audit_trigger
https://github.com/iloveitaly/audit-trigger
https://github.com/supabase/supa_audit
https://ttu.github.io/postgres-simple-audit-trail/

https://medium.com/israeli-tech-radar/postgresql-trigger-based-audit-log-fd9d9d5e412c
https://www.tigerdata.com/learn/what-is-audit-logging-and-how-to-enable-it-in-postgresql


```
