-- Idempotent: IF NOT EXISTS is supported in Oracle 23ai / 26ai
create user if not exists TRACKER1 identified by Welcome_MY_ATP_123;
grant CONNECT, RESOURCE, unlimited tablespace to TRACKER1;
grant create view to TRACKER1;
grant create materialized view to TRACKER1;
grant create procedure to TRACKER1;
GRANT DB_DEVELOPER_ROLE, CREATE MINING MODEL TO TRACKER1;
GRANT READ ON DIRECTORY DATA_PUMP_DIR TO TRACKER1;
GRANT WRITE ON DIRECTORY DATA_PUMP_DIR TO TRACKER1;
-- Grant access to the ONNX model loaded in the SYSTEM schema by vector-setup.sql
GRANT SELECT ON MINING MODEL SYSTEM.ALL_MINILM TO TRACKER1;
-- APEX workspace setup: only runs if APEX is installed (not present by default in database/free)
-- Uses EXECUTE IMMEDIATE so Oracle does not resolve APEX package names at compile time
DECLARE
  v_apex_installed NUMBER;
  v_ws_exists      NUMBER;
  v_user_exists    NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_apex_installed FROM dba_users
  WHERE username LIKE 'APEX_%' AND oracle_maintained = 'Y'
  AND username NOT IN ('APEX_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','APEX_PUBLIC_ROUTER');

  IF v_apex_installed > 0 THEN

    SELECT COUNT(*) INTO v_ws_exists
    FROM apex_workspaces WHERE workspace = 'TRACKER1';

    IF v_ws_exists = 0 THEN
      EXECUTE IMMEDIATE 'BEGIN apex_instance_admin.add_workspace(p_workspace => ''TRACKER1'', p_primary_schema => ''TRACKER1''); END;';
      DBMS_OUTPUT.PUT_LINE('APEX workspace TRACKER1 created.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('APEX workspace TRACKER1 already exists - skipped.');
    END IF;

    EXECUTE IMMEDIATE 'BEGIN apex_util.set_workspace(p_workspace => ''TRACKER1''); END;';

    SELECT COUNT(*) INTO v_user_exists
    FROM apex_workspace_apex_users
    WHERE workspace_name = 'TRACKER1' AND user_name = 'TRACKER1';

    IF v_user_exists = 0 THEN
      EXECUTE IMMEDIATE q'[BEGIN
        apex_util.create_user(
          p_user_name => 'TRACKER1',
          p_web_password => 'Welcome_MY_ATP_123',
          p_developer_privs => 'ADMIN:CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL',
          p_email_address => 'TRACKER1@withoracle.cloud',
          p_default_schema => 'TRACKER1',
          p_account_expiry => SYSDATE + 36500,
          p_change_password_on_first_use => 'N');
      END;]';
      DBMS_OUTPUT.PUT_LINE('APEX user TRACKER1 created successfully.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('APEX user TRACKER1 already exists - skipped.');
    END IF;

  ELSE
    DBMS_OUTPUT.PUT_LINE('APEX not installed - skipping APEX workspace setup for TRACKER1');
  END IF;
END;
/
select sysdate from dual;
exit
