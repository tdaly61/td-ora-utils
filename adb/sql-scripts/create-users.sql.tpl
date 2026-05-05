-- Idempotent: IF NOT EXISTS is supported in Oracle 23ai / 26ai
create user if not exists __APEX_USER__ identified by __APEX_PASSWORD__;
grant CONNECT, RESOURCE, unlimited tablespace to __APEX_USER__;
grant create view to __APEX_USER__;
grant create materialized view to __APEX_USER__;
grant create procedure to __APEX_USER__;
GRANT DB_DEVELOPER_ROLE, CREATE MINING MODEL TO __APEX_USER__;
GRANT READ ON DIRECTORY DATA_PUMP_DIR TO __APEX_USER__;
GRANT WRITE ON DIRECTORY DATA_PUMP_DIR TO __APEX_USER__;
-- Grant access to the ONNX model loaded in the SYSTEM schema by vector-setup.sql
GRANT SELECT ON MINING MODEL SYSTEM.ALL_MINILM TO __APEX_USER__;
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
    FROM apex_workspaces WHERE workspace = '__APEX_USER__';

    IF v_ws_exists = 0 THEN
      EXECUTE IMMEDIATE 'BEGIN apex_instance_admin.add_workspace(p_workspace => ''__APEX_USER__'', p_primary_schema => ''__APEX_USER__''); END;';
      DBMS_OUTPUT.PUT_LINE('APEX workspace __APEX_USER__ created.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('APEX workspace __APEX_USER__ already exists - skipped.');
    END IF;

    EXECUTE IMMEDIATE 'BEGIN apex_util.set_workspace(p_workspace => ''__APEX_USER__''); END;';

    SELECT COUNT(*) INTO v_user_exists
    FROM apex_workspace_apex_users
    WHERE workspace_name = '__APEX_USER__' AND user_name = '__APEX_USER__';

    IF v_user_exists = 0 THEN
      EXECUTE IMMEDIATE q'[BEGIN
        apex_util.create_user(
          p_user_name => '__APEX_USER__',
          p_web_password => '__APEX_PASSWORD__',
          p_developer_privs => 'ADMIN:CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL',
          p_email_address => '__APEX_USER__@withoracle.cloud',
          p_default_schema => '__APEX_USER__',
          p_change_password_on_first_use => 'N');
      END;]';
      DBMS_OUTPUT.PUT_LINE('APEX user __APEX_USER__ created successfully.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('APEX user __APEX_USER__ already exists - skipped.');
    END IF;

    -- apex_util.create_user ignores p_account_expiry in APEX 24.2; fix it directly.
    -- Must run as APEX schema owner for the UPDATE to match (internal context check).
    EXECUTE IMMEDIATE
      'ALTER SESSION SET CURRENT_SCHEMA = APEX_240200';
    EXECUTE IMMEDIATE
      'UPDATE wwv_flow_fnd_user
       SET    account_expiry = ADD_MONTHS(SYSDATE, 1200),
              first_password_use_occurred = ''Y''
       WHERE  user_name = ''__APEX_USER__''
       AND    security_group_id = (
                SELECT workspace_id FROM apex_workspaces
                WHERE  workspace = ''__APEX_USER__'')';
    EXECUTE IMMEDIATE 'COMMIT';
    DBMS_OUTPUT.PUT_LINE('Account expiry set to 100 years.');

  ELSE
    DBMS_OUTPUT.PUT_LINE('APEX not installed - skipping APEX workspace setup for __APEX_USER__');
  END IF;
END;
/
select sysdate from dual;
exit
