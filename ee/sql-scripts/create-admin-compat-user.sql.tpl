-- create-admin-compat-user.sql.tpl
-- Mints a compatibility ADMIN DBA user in the target PDB so that
-- adb/load-apex-app.sh (which always connects as
-- admin/$DEFAULT_PASSWORD@$SERVICE_NAME for its bootstrap/ACL/AI-service
-- steps) works completely unmodified against this two-container stack.
-- Plain Oracle Database (Enterprise Edition here) has no ADMIN user by default —
-- only SYS/SYSTEM/PDBADMIN — unlike ADB-Free where ADMIN is the universal
-- top-level account.
--
-- Run as: SYS/SYSDBA against the target PDB (e.g. via
--   sqlplus -s "sys/<ORACLE_PWD>@//localhost:1521/<ORACLE_PDB> as sysdba"
-- ).
--
-- Substitution tokens (replaced by run-ee.sh):
--   __ADMIN_PASSWORD__ — password for the compat ADMIN user

SET SERVEROUTPUT ON;

DECLARE
  v_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_exists FROM dba_users WHERE username = 'ADMIN';
  IF v_exists = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER ADMIN IDENTIFIED BY "__ADMIN_PASSWORD__"';
    EXECUTE IMMEDIATE 'GRANT DBA TO ADMIN';
    EXECUTE IMMEDIATE 'GRANT UNLIMITED TABLESPACE TO ADMIN';
    DBMS_OUTPUT.PUT_LINE('Compat ADMIN user created and granted DBA.');
  ELSE
    -- Idempotent re-run: keep the existing account, just resync the password
    -- so re-running run-ee.sh after an .env change stays consistent.
    EXECUTE IMMEDIATE 'ALTER USER ADMIN IDENTIFIED BY "__ADMIN_PASSWORD__"';
    DBMS_OUTPUT.PUT_LINE('Compat ADMIN user already exists — password resynced.');
  END IF;

  -- Plain DBA is not enough for apex_instance_admin.add_workspace (called
  -- by adb/load-apex-app.sh for every app import) — that specifically
  -- checks for APEX_ADMINISTRATOR_ROLE, not just DBA, and fails with
  -- ORA-20987 ("User ADMIN requires ADMIN privilege") without it. Granted
  -- unconditionally so this also self-heals pre-existing installs that
  -- predate this fix.
  EXECUTE IMMEDIATE 'GRANT APEX_ADMINISTRATOR_ROLE TO ADMIN';
  DBMS_OUTPUT.PUT_LINE('APEX_ADMINISTRATOR_ROLE granted to ADMIN.');
END;
/

PROMPT Compat ADMIN user ready.
select sysdate from dual;
exit;
