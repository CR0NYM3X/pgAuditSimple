/*
 @Function: audit.fn_trg_register_ddl
 @Creation Date: 19/02/2026
 @Description: Centralized DDL event capture. Records all DDL history exclusively 
                into audit.ddl_history, including the affected object name.
 @Parameters: N/A (Event Trigger)
 @Returns: event_trigger
 @Author: CR0NYM3X
 ---------------- HISTORY ----------------
 @Date: 19/02/2026
 @Change: Removed specific cat_server logic. Centralized all logs in ddl_history.
 @Author: CR0NYM3X
*/

-- DROP SCHEMA audit;
CREATE SCHEMA IF NOT EXISTS audit;

-- Centralized audit table
-- DROP TABLE audit.ddl_history;
-- truncate audit.ddl_history RESTART IDENTITY ;
CREATE TABLE IF NOT EXISTS audit.ddl_history (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    server_ip     text,
    port          int,
    app_name      text,
    db_name       text,
    event         text, -- TG_TAG
    object_name   text, -- Affected object (e.g., public.my_table)
    user_name     text,
    client_ip     text,
    query         text,
    created_at    timestamptz DEFAULT clock_timestamp()
);

-- DROP FUNCTION audit.fn_trg_register_ddl();
CREATE OR REPLACE FUNCTION audit.fn_trg_register_ddl()
RETURNS event_trigger
LANGUAGE plpgsql
COST 100
VOLATILE
SECURITY DEFINER
AS $BODY$
DECLARE
    -- Context Variables
    v_app_name  text := current_setting('application_name', true);
    v_query     text := current_query();
    v_timestamp timestamptz := clock_timestamp();
    
    -- Object Identification Variable
    v_obj_name  text;
    
    -- Exception Variables
    v_err_msg   text;
    v_err_ctx   text;
BEGIN
    -- 1. Exclusion filter for automated processes (pg_cron)
    IF v_app_name = 'pg_cron' THEN
        RETURN;
    END IF;

    -- 2. Capture the object identity from the DDL command
    -- We take the first object affected by the command
    SELECT object_identity INTO v_obj_name 
    FROM pg_catalog.pg_event_trigger_ddl_commands() 
    LIMIT 1;

    -- 3. Centralized Audit Recording
    INSERT INTO audit.ddl_history (
        server_ip, 
        port, 
        app_name, 
        db_name, 
        event, 
        object_name,
        user_name, 
        client_ip, 
        query, 
        created_at
    ) 
    VALUES (
        coalesce(host(inet_server_addr()), 'unix_socket'),
        current_setting('port')::int,
        v_app_name,
        current_database(),
        TG_TAG, 
        v_obj_name,
        session_user, 
        coalesce(host(inet_client_addr()), '127.0.0.1'), 
        v_query,
        v_timestamp
    );

-- ERROR HANDLING: Resilience to avoid blocking user's DDL
EXCEPTION 
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_ctx = PG_EXCEPTION_CONTEXT;
        RAISE WARNING 'DDL Audit failed in audit.fn_trg_register_ddl: %. Context: %', v_err_msg, v_err_ctx;
END;
$BODY$;

-- Security and Permissions Configuration
ALTER FUNCTION audit.fn_trg_register_ddl() 
SET search_path TO audit, pg_catalog, public, pg_temp;

REVOKE ALL ON FUNCTION audit.fn_trg_register_ddl() FROM PUBLIC;

---------------- COMMENT ----------------
COMMENT ON FUNCTION audit.fn_trg_register_ddl() IS
'Event trigger for centralized DDL auditing.
- Records all events in audit.ddl_history.
- Captures object_name using pg_event_trigger_ddl_commands().
- Security: SECURITY DEFINER with restricted search_path.';

-- 2. Create the Event Trigger
-- DROP EVENT TRIGGER IF EXISTS trg_audit_ddl_global;
CREATE EVENT TRIGGER trg_audit_ddl_global
ON ddl_command_end
EXECUTE FUNCTION audit.fn_trg_register_ddl();


-- create temp table client123(name varchar);
-- alter table client123 add column phone varchar;
-- select * from audit.ddl_history ;
