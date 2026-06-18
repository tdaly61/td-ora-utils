SET SERVEROUTPUT ON SIZE UNLIMITED
-- Idempotent: IF NOT EXISTS is supported in Oracle 23ai / 26ai
create user if not exists __APEX_USER__ identified by __APEX_PASSWORD__;
grant CONNECT, RESOURCE, unlimited tablespace to __APEX_USER__;
grant create view to __APEX_USER__;
grant create materialized view to __APEX_USER__;
grant create procedure to __APEX_USER__;
GRANT DB_DEVELOPER_ROLE, CREATE MINING MODEL TO __APEX_USER__;
GRANT READ ON DIRECTORY DATA_PUMP_DIR TO __APEX_USER__;
GRANT WRITE ON DIRECTORY DATA_PUMP_DIR TO __APEX_USER__;
-- Note: GRANT SELECT ON MINING MODEL SYSTEM.ALL_MINILM is in vector-setup.sql,
-- after DBMS_VECTOR.LOAD_ONNX_MODEL, so the model exists before the grant runs.
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

    -- All APEX API calls are in ONE EXECUTE IMMEDIATE so the security_group_id context
    -- stays set throughout.  The block:
    --   (a) Removes __APEX_USER__ from any workspace other than __APEX_USER__ — this
    --       cleans up stale state left by a previous run where the wrong workspace context
    --       was active, which produces "user belongs to another apex workspace" on login.
    --   (b) Creates the user if not present in __APEX_USER__ workspace.
    --   (c) Always runs edit_user to ensure ADMIN developer privs are set, even when the
    --       user already existed (fixes "you are not a developer in this workspace").
    EXECUTE IMMEDIATE q'[DECLARE
      v_sgid     NUMBER;
      v_other_sg NUMBER;
      v_uid      NUMBER;
      v_exists   NUMBER;
    BEGIN
      SELECT workspace_id INTO v_sgid FROM apex_workspaces WHERE workspace = '__APEX_USER__';
      apex_util.set_workspace(p_workspace => '__APEX_USER__');
      apex_util.set_security_group_id(p_security_group_id => v_sgid);

      -- (a) Remove __APEX_USER__ from any workspace it does not belong in.
      FOR rec IN (
        SELECT workspace_name FROM apex_workspace_apex_users
        WHERE  user_name = '__APEX_USER__'
        AND    workspace_name != '__APEX_USER__'
      ) LOOP
        BEGIN
          SELECT workspace_id INTO v_other_sg
            FROM apex_workspaces WHERE workspace = rec.workspace_name;
          apex_util.set_workspace(p_workspace => rec.workspace_name);
          apex_util.set_security_group_id(p_security_group_id => v_other_sg);
          apex_util.remove_user(p_user_name => '__APEX_USER__');
          DBMS_OUTPUT.PUT_LINE('Removed stale __APEX_USER__ from workspace ' || rec.workspace_name);
        EXCEPTION WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE('Cleanup note (' || rec.workspace_name || '): ' || SQLERRM);
        END;
      END LOOP;

      -- Restore __APEX_USER__ workspace context after cleanup loop.
      apex_util.set_workspace(p_workspace => '__APEX_USER__');
      apex_util.set_security_group_id(p_security_group_id => v_sgid);

      -- (b) Create user if not yet in the correct workspace.
      SELECT COUNT(*) INTO v_exists FROM apex_workspace_apex_users
      WHERE workspace_name = '__APEX_USER__' AND user_name = '__APEX_USER__';

      IF v_exists = 0 THEN
        apex_util.create_user(
          p_user_name                    => '__APEX_USER__',
          p_web_password                 => '__APEX_PASSWORD__',
          p_developer_privs              => 'ADMIN:CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL',
          p_email_address                => '__APEX_USER__@withoracle.cloud',
          p_default_schema               => '__APEX_USER__',
          p_change_password_on_first_use => 'N',
          p_first_password_use_occurred  => 'Y');
        DBMS_OUTPUT.PUT_LINE('APEX user __APEX_USER__ created.');
      ELSE
        DBMS_OUTPUT.PUT_LINE('APEX user __APEX_USER__ already exists in correct workspace.');
      END IF;

      -- (c) Always set developer privs — fixes existing users created without admin access.
      v_uid := apex_util.get_user_id('__APEX_USER__');
      IF v_uid IS NOT NULL THEN
        apex_util.edit_user(
          p_user_id                      => v_uid,
          p_user_name                    => '__APEX_USER__',
          p_developer_privs              => 'ADMIN:CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL',
          p_change_password_on_first_use => 'N');
        DBMS_OUTPUT.PUT_LINE('Developer/admin privs confirmed for __APEX_USER__.');
      END IF;
    END;]';

    -- Disable APEX account expiry for this instance (dev/demo container, not production).
    -- apex_instance_admin.set_parameter runs with APEX schema definer rights and succeeds
    -- where direct DML on wwv_flow_fnd_user would be blocked by VPD (ORA-41900).
    BEGIN
      EXECUTE IMMEDIATE q'[BEGIN
        apex_instance_admin.set_parameter('EXPIRE_FND_USER_ACCOUNTS', 'N');
      END;]';
      DBMS_OUTPUT.PUT_LINE('APEX account expiry disabled (EXPIRE_FND_USER_ACCOUNTS=N).');
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('WARN: could not disable account expiry: ' || SQLERRM);
    END;

  ELSE
    DBMS_OUTPUT.PUT_LINE('APEX not installed - skipping APEX workspace setup for __APEX_USER__');
  END IF;
END;
/
select sysdate from dual;
exit
