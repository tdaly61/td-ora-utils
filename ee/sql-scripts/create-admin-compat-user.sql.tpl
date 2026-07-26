-- create-admin-compat-user.sql.tpl
-- Mints a compatibility ADMIN DBA user in the target PDB so that
-- adb/load-apex-app.sh (which always connects as
-- admin/$DEFAULT_PASSWORD@$SERVICE_NAME for its bootstrap/ACL/AI-service
-- steps) works completely unmodified against this two-container stack.
-- Plain Oracle (Free or Enterprise Edition) has no ADMIN user by default —
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
END;
/

PROMPT Compat ADMIN user ready.
select sysdate from dual;
exit;
