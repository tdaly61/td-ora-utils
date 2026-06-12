-- Idempotent user creation: ORA-01920 (user exists) is silently ignored.
BEGIN
  EXECUTE IMMEDIATE 'CREATE USER __APEX_USER__ IDENTIFIED BY __APEX_PASSWORD__';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1920 THEN RAISE; END IF;
END;
/
grant CONNECT, RESOURCE, unlimited tablespace to __APEX_USER__;
grant create view to __APEX_USER__;
grant create materialized view to __APEX_USER__;
grant create procedure to __APEX_USER__;
GRANT DB_DEVELOPER_ROLE, CREATE MINING MODEL TO __APEX_USER__;
GRANT READ ON DIRECTORY DATA_PUMP_DIR TO __APEX_USER__;
GRANT WRITE ON DIRECTORY DATA_PUMP_DIR TO __APEX_USER__;
-- Grant access to the ONNX model loaded in the SYSTEM schema by vector-setup.sql
GRANT SELECT ON MINING MODEL SYSTEM.DOC_MODEL TO __APEX_USER__;
-- APEX workspace setup: only runs if APEX is installed (not present by default in database/free)
-- Uses EXECUTE IMMEDIATE so Oracle does not resolve APEX package names at compile time
DECLARE
  v_apex_installed NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_apex_installed FROM dba_users WHERE username = 'APEX_PUBLIC_USER';
  IF v_apex_installed > 0 THEN
    -- ORA-20987: workspace already exists — safe to ignore on re-runs
    BEGIN
      EXECUTE IMMEDIATE 'BEGIN apex_instance_admin.add_workspace(p_workspace => ''__APEX_USER__'', p_primary_schema => ''__APEX_USER__''); END;';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE != -20987 THEN RAISE; END IF;
    END;
    EXECUTE IMMEDIATE 'BEGIN apex_util.set_workspace(p_workspace => ''__APEX_USER__''); END;';
    -- DUP_VAL_ON_INDEX (ORA-00001): APEX user already exists — safe to ignore on re-runs
    BEGIN
      EXECUTE IMMEDIATE q'[BEGIN
        apex_util.create_user(
          p_user_name => '__APEX_USER__',
          p_web_password => '__APEX_PASSWORD__',
          p_developer_privs => 'ADMIN:CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL',
          p_email_address => '__APEX_USER__@withoracle.cloud',
          p_default_schema => '__APEX_USER__',
          p_account_expiry => SYSDATE + 36500,
          p_change_password_on_first_use => 'N');
      END;]';
    EXCEPTION
      WHEN DUP_VAL_ON_INDEX THEN NULL;
    END;
    DBMS_OUTPUT.PUT_LINE('APEX workspace __APEX_USER__ configured.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('APEX not installed - skipping APEX workspace setup for __APEX_USER__');
  END IF;
END;
/
select sysdate from dual;
exit
