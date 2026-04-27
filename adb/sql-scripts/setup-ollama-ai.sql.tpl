-- setup-ollama-ai.sql
-- Configures outbound network access and registers Ollama as a generative AI
-- provider so the Oracle 23ai Free database can call a local LLM.
-- Run as: SYSTEM (connected via sqlplus from the host) against FREEPDB1.
-- Grants that require SYS are executed inside the DB container by
-- run-adb-26ai.sh (see run_sql_file_as_sysdba).
--
-- Substitution tokens (replaced by generate_sql_files in run-adb-26ai.sh):
--   __APEX_USER__      — the application schema (e.g. TRACKER1)
--   __OLLAMA_BASE_URL__— Ollama endpoint from inside Docker (e.g. http://host.docker.internal:11434)
--   __OLLAMA_MODEL__   — Ollama model name (e.g. llama3)

SET SERVEROUTPUT ON;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Network ACL — allow the APEX schema owner and __APEX_USER__ to connect out
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE
  v_apex_installed NUMBER;
BEGIN
  -- Grant to APEX flow schema owner (needed for APEX restful services)
  SELECT COUNT(*) INTO v_apex_installed FROM dba_users WHERE username = 'APEX_PUBLIC_USER';
  IF v_apex_installed > 0 THEN
    EXECUTE IMMEDIATE q'[
      BEGIN
        DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
          host => '*',
          ace  => xs$ace_type(
                    privilege_list => xs$name_list('connect'),
                    principal_name => APEX_APPLICATION.g_flow_schema_owner,
                    principal_type => xs_acl.ptype_db));
      END;]';
    DBMS_OUTPUT.PUT_LINE('Network ACL granted to APEX flow schema owner.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('APEX not installed — skipping APEX flow schema owner ACL.');
  END IF;
END;
/

-- Grant connect privilege to the application user directly
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect', 'resolve'),
              principal_name => '__APEX_USER__',
              principal_type => xs_acl.ptype_db));
  DBMS_OUTPUT.PUT_LINE('Network ACL granted to __APEX_USER__.');
END;
/

-- Also grant to SYSTEM so admin scripts can test connectivity
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect', 'resolve'),
              principal_name => 'SYSTEM',
              principal_type => xs_acl.ptype_db));
  DBMS_OUTPUT.PUT_LINE('Network ACL granted to SYSTEM.');
END;
/

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Grant UTL_HTTP and DBMS_VECTOR_CHAIN to __APEX_USER__
--    These are SYS-owned packages so we need to grant via SYS.
--    SYSTEM can grant them using EXECUTE IMMEDIATE from the SYS context
--    available through the DBA role granted to SYSTEM in Oracle Free.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN
  EXECUTE IMMEDIATE 'GRANT EXECUTE ON SYS.UTL_HTTP TO __APEX_USER__';
  DBMS_OUTPUT.PUT_LINE('GRANT EXECUTE ON UTL_HTTP to __APEX_USER__ succeeded.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('UTL_HTTP grant note: ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('Will be granted by run-adb-26ai.sh via SYS inside container.');
END;
/

BEGIN
  EXECUTE IMMEDIATE 'GRANT EXECUTE ON CTXSYS.DBMS_VECTOR_CHAIN TO __APEX_USER__';
  DBMS_OUTPUT.PUT_LINE('GRANT EXECUTE ON DBMS_VECTOR_CHAIN to __APEX_USER__ succeeded.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('DBMS_VECTOR_CHAIN grant note: ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('Will be granted by run-adb-26ai.sh via SYS inside container.');
END;
/

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Create DB credential for Ollama (used by DBMS_VECTOR_CHAIN).
--    Ollama has no auth, but Oracle requires a credential object.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM all_credentials
   WHERE owner = 'SYSTEM' AND credential_name = 'OLLAMA_CRED';
  IF v_count > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Credential OLLAMA_CRED already exists — dropping and recreating.');
    DBMS_CREDENTIAL.DROP_CREDENTIAL(credential_name => 'OLLAMA_CRED');
  END IF;
  DBMS_CREDENTIAL.CREATE_CREDENTIAL(
    credential_name => 'OLLAMA_CRED',
    username        => 'OLLAMA',
    password        => 'not-needed');
  DBMS_OUTPUT.PUT_LINE('Credential OLLAMA_CRED created.');
END;
/

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Connectivity test — skipped when running from host sqlplus because
--    __OLLAMA_BASE_URL__ (host.docker.internal) only resolves inside Docker.
--    The validate_ollama_from_db() function in run-adb-26ai.sh performs the
--    definitive test from inside the DB container.
-- ─────────────────────────────────────────────────────────────────────────────
PROMPT Note: Ollama connectivity is validated from inside the DB container by run-adb-26ai.sh.
PROMPT       Skipping UTL_HTTP test here (host.docker.internal does not resolve on the host).

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Register Ollama as an APEX Generative AI Service for the __APEX_USER__
--    workspace so it appears under Workspace Utilities > Generative AI.
--    Uses the OpenAI-compatible endpoint (/v1) that Ollama exposes.
--    Also creates an APEX workspace credential (HTTP_HEADER type with a
--    dummy Bearer token) since APEX requires one for OpenAI-type providers.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE
  v_ws_id      NUMBER;
  v_srv_id     NUMBER;
  v_cred_id    NUMBER;
  v_apex_owner VARCHAR2(128);
  v_static_id  VARCHAR2(100) := 'OLLAMA___OLLAMA_MODEL__';
  v_cred_sid   VARCHAR2(100) := 'OLLAMA___OLLAMA_MODEL___CRED';
  v_sql        VARCHAR2(4000);
BEGIN
  -- Look up the workspace ID for __APEX_USER__
  SELECT workspace_id INTO v_ws_id
    FROM apex_workspaces
   WHERE workspace = '__APEX_USER__';

  -- Discover the current APEX schema owner (e.g. APEX_240200) so this
  -- script survives APEX upgrades without hard-coding the version.
  SELECT username INTO v_apex_owner
    FROM dba_users
   WHERE username LIKE 'APEX_%'
     AND oracle_maintained = 'Y'
     AND username NOT IN ('APEX_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','APEX_PUBLIC_ROUTER')
     AND ROWNUM = 1;

  -- Step A: Create or update the APEX workspace credential (HTTP_HEADER type).
  -- APEX sends this as "Authorization: Bearer <key>" on each request to Ollama.
  -- Ollama ignores the header, but APEX requires a credential for OpenAI providers.
  v_sql := 'SELECT id FROM ' || v_apex_owner || '.wwv_credentials'
        || ' WHERE security_group_id = :ws AND static_id = :sid';
  BEGIN
    EXECUTE IMMEDIATE v_sql INTO v_cred_id USING v_ws_id, v_cred_sid;
    DBMS_OUTPUT.PUT_LINE('APEX credential ' || v_cred_sid || ' already exists (id=' || v_cred_id || ').');
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      v_sql := 'SELECT ' || v_apex_owner || '.wwv_seq.nextval FROM dual';
      EXECUTE IMMEDIATE v_sql INTO v_cred_id;
      v_sql := 'INSERT INTO ' || v_apex_owner || '.wwv_credentials'
            || ' (id, security_group_id, name, static_id,'
            || '  authentication_type, client_id, client_secret,'
            || '  prompt_on_install,'
            || '  created_by, created_on, last_updated_by, last_updated_on)'
            || ' VALUES (:id, :ws, :name, :sid,'
            || '  ''HTTP_HEADER'', ''Authorization'', ''Bearer ollama-no-auth-needed'','
            || '  ''Y'','
            || '  USER, SYSDATE, USER, SYSDATE)';
      EXECUTE IMMEDIATE v_sql USING v_cred_id, v_ws_id,
        'Ollama __OLLAMA_MODEL__ Credential', v_cred_sid;
      DBMS_OUTPUT.PUT_LINE('APEX credential created: ' || v_cred_sid);
  END;

  -- Step B: Create or update the remote server (AI service).
  v_sql := 'SELECT id FROM ' || v_apex_owner || '.wwv_remote_servers'
        || ' WHERE security_group_id = :ws AND static_id = :sid';
  BEGIN
    EXECUTE IMMEDIATE v_sql INTO v_srv_id USING v_ws_id, v_static_id;
    DBMS_OUTPUT.PUT_LINE('APEX AI service ' || v_static_id || ' already exists (id=' || v_srv_id || ') — updating.');
    v_sql := 'UPDATE ' || v_apex_owner || '.wwv_remote_servers'
          || ' SET base_url = :url, ai_model_name = :mdl,'
          || '     credential_id = :cid,'
          || '     last_updated_on = SYSDATE, last_updated_by = USER'
          || ' WHERE id = :id';
    EXECUTE IMMEDIATE v_sql USING '__OLLAMA_BASE_URL__/v1', '__OLLAMA_MODEL__', v_cred_id, v_srv_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      v_sql := 'SELECT ' || v_apex_owner || '.wwv_seq.nextval FROM dual';
      EXECUTE IMMEDIATE v_sql INTO v_srv_id;
      v_sql := 'INSERT INTO ' || v_apex_owner || '.wwv_remote_servers'
            || ' (id, security_group_id, name, static_id, base_url,'
            || '  server_type, ai_provider_type, ai_is_builder_service,'
            || '  ai_model_name, credential_id, prompt_on_install,'
            || '  created_by, created_on, last_updated_by, last_updated_on)'
            || ' VALUES (:id, :ws, :name, :sid, :url,'
            || '  ''GENERATIVE_AI'', ''OPENAI'', ''N'','
            || '  :mdl, :cid, ''Y'','
            || '  USER, SYSDATE, USER, SYSDATE)';
      EXECUTE IMMEDIATE v_sql USING v_srv_id, v_ws_id,
        'Ollama __OLLAMA_MODEL__', v_static_id,
        '__OLLAMA_BASE_URL__/v1', '__OLLAMA_MODEL__', v_cred_id;
      DBMS_OUTPUT.PUT_LINE('APEX AI service created: ' || v_static_id || ' -> __OLLAMA_BASE_URL__/v1 (model: __OLLAMA_MODEL__)');
  END;
  COMMIT;
END;
/

PROMPT Ollama AI service setup complete.
PROMPT Ollama endpoint: __OLLAMA_BASE_URL__
PROMPT Ollama model:    __OLLAMA_MODEL__
PROMPT
PROMPT Test from SQL:
PROMPT   SELECT DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT(
PROMPT     'Hello, tell me a joke',
PROMPT     JSON('{"provider":"ollama","host":"__OLLAMA_BASE_URL__","model":"__OLLAMA_MODEL__"}')
PROMPT   ) FROM dual;

select sysdate from dual;
exit;
