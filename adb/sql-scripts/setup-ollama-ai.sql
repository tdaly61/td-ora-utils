-- setup-ollama-ai.sql.tpl
-- Configures outbound network access and registers Ollama as a generative AI
-- provider so the Oracle 26ai Free database can call a local LLM.
-- Run as: ADMIN (connected via sqlplus from the host) against the ADB-Free PDB.
--
-- Substitution tokens (replaced by generate_sql_files in run-adb-26ai.sh):
--   TRACKER1       — the application schema / APEX workspace (e.g. TRACKER1)
--   Welcome_MY_ATP_123   — the application user password
--   https://ollama-proxy:443 — Ollama endpoint from inside Docker (e.g. http://host.docker.internal:11434)
--   llama3.2:3b    — Ollama model name (e.g. llama3.2:3b)

SET SERVEROUTPUT ON;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Network ACL — allow the APEX schema owner and TRACKER1 to connect out
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE
  v_apex_installed NUMBER;
  v_apex_owner     VARCHAR2(128);
BEGIN
  -- In Oracle 26ai ADB-Free, APEX_PUBLIC_USER does not exist. Detect APEX by
  -- looking for the versioned schema (e.g. APEX_240200) the same way create-users.sql does.
  SELECT COUNT(*) INTO v_apex_installed FROM dba_users
  WHERE username LIKE 'APEX_%' AND oracle_maintained = 'Y'
  AND username NOT IN ('APEX_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','APEX_PUBLIC_ROUTER');

  IF v_apex_installed > 0 THEN
    SELECT username INTO v_apex_owner FROM dba_users
    WHERE username LIKE 'APEX_%' AND oracle_maintained = 'Y'
    AND username NOT IN ('APEX_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','APEX_PUBLIC_ROUTER')
    AND ROWNUM = 1;

    -- Use the schema name directly rather than APEX_APPLICATION.g_flow_schema_owner,
    -- which requires an initialized APEX request context (not available via external sqlplus).
    EXECUTE IMMEDIATE 'BEGIN
      DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
        host => ''*'',
        ace  => xs$ace_type(
                  privilege_list => xs$name_list(''connect''),
                  principal_name => ''' || v_apex_owner || ''',
                  principal_type => xs_acl.ptype_db));
    END;';
    DBMS_OUTPUT.PUT_LINE('Network ACL granted to APEX schema owner (' || v_apex_owner || ').');
  ELSE
    DBMS_OUTPUT.PUT_LINE('APEX schema owner not found — skipping APEX flow schema owner ACL.');
  END IF;
END;
/

-- Grant connect privilege to the application user directly
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect', 'resolve'),
              principal_name => 'TRACKER1',
              principal_type => xs_acl.ptype_db));
  DBMS_OUTPUT.PUT_LINE('Network ACL granted to TRACKER1.');
END;
/

-- Grant to SYSTEM and ADMIN so admin scripts can test connectivity via UTL_HTTP
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

BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect', 'resolve'),
              principal_name => 'ADMIN',
              principal_type => xs_acl.ptype_db));
  DBMS_OUTPUT.PUT_LINE('Network ACL granted to ADMIN.');
END;
/

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Grant UTL_HTTP and DBMS_VECTOR_CHAIN to TRACKER1
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN
  EXECUTE IMMEDIATE 'GRANT EXECUTE ON SYS.UTL_HTTP TO TRACKER1';
  DBMS_OUTPUT.PUT_LINE('GRANT EXECUTE ON UTL_HTTP to TRACKER1 succeeded.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('UTL_HTTP grant note: ' || SQLERRM);
END;
/

BEGIN
  EXECUTE IMMEDIATE 'GRANT EXECUTE ON CTXSYS.DBMS_VECTOR_CHAIN TO TRACKER1';
  DBMS_OUTPUT.PUT_LINE('GRANT EXECUTE ON DBMS_VECTOR_CHAIN to TRACKER1 succeeded.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('DBMS_VECTOR_CHAIN grant note: ' || SQLERRM);
END;
/

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Create DB credential for Ollama (used by DBMS_VECTOR_CHAIN).
--    Ollama has no auth, but Oracle requires a credential object.
--    ADMIN may lack CREATE CREDENTIAL privilege on ADB-Free — wrap in exception
--    so the script continues; DBMS_VECTOR_CHAIN JSON config works without it.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM all_credentials
   WHERE owner = 'ADMIN' AND credential_name = 'OLLAMA_CRED';
  IF v_count > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Credential OLLAMA_CRED already exists — dropping and recreating.');
    DBMS_CREDENTIAL.DROP_CREDENTIAL(credential_name => 'OLLAMA_CRED');
  END IF;
  DBMS_CREDENTIAL.CREATE_CREDENTIAL(
    credential_name => 'OLLAMA_CRED',
    username        => 'OLLAMA',
    password        => 'not-needed');
  DBMS_OUTPUT.PUT_LINE('Credential OLLAMA_CRED created.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Note: OLLAMA_CRED skipped (' || SQLERRM || ')');
    DBMS_OUTPUT.PUT_LINE('  DBMS_VECTOR_CHAIN JSON config works without a named credential.');
END;
/

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Connectivity note
-- ─────────────────────────────────────────────────────────────────────────────
PROMPT Note: Ollama connectivity is validated from inside the DB container by run-adb-26ai.sh.
PROMPT       Skipping UTL_HTTP test here (host.docker.internal does not resolve on the host).

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Register Ollama as an APEX Generative AI Service for the TRACKER1
--    workspace so it appears under Workspace Utilities > Generative AI.
--    Uses the OpenAI-compatible endpoint (/v1) that Ollama exposes.
--
--    VPD on wwv_credentials and wwv_remote_servers enforces that queries
--    only return rows for the current APEX security_group_id.  We must call
--    apex_util.set_workspace BEFORE accessing those tables, otherwise the
--    ADMIN session defaults to the INTERNAL context and ORA-41900 is raised.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE
  v_ws_id      NUMBER;
  v_srv_id     NUMBER;
  v_cred_id    NUMBER;
  v_apex_owner VARCHAR2(128);
  v_static_id  VARCHAR2(100) := 'OLLAMA_llama3.2:3b';
  v_cred_sid   VARCHAR2(100) := 'OLLAMA_llama3.2:3b_CRED';
  v_sql        VARCHAR2(4000);
BEGIN
  -- Look up the workspace ID for TRACKER1
  SELECT workspace_id INTO v_ws_id
    FROM apex_workspaces
   WHERE workspace = 'TRACKER1';

  -- Set workspace context FIRST so VPD on wwv_credentials/wwv_remote_servers
  -- allows access and uses the correct security_group_id.
  apex_util.set_workspace(p_workspace => 'TRACKER1');
  apex_util.set_security_group_id(p_security_group_id => v_ws_id);

  -- Discover the current APEX schema owner (e.g. APEX_240200).
  SELECT username INTO v_apex_owner
    FROM dba_users
   WHERE username LIKE 'APEX_%'
     AND oracle_maintained = 'Y'
     AND username NOT IN ('APEX_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','APEX_PUBLIC_ROUTER')
     AND ROWNUM = 1;

  -- Step A: Create or look up the APEX workspace credential (HTTP_HEADER type).
  -- Ollama ignores the Authorization header, but APEX requires a credential for
  -- OpenAI-type providers.
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
        'Ollama llama3.2:3b Credential', v_cred_sid;
      DBMS_OUTPUT.PUT_LINE('APEX credential created: ' || v_cred_sid);
  END;

  -- Step B: Create or update the remote server (AI service).
  v_sql := 'SELECT id FROM ' || v_apex_owner || '.wwv_remote_servers'
        || ' WHERE security_group_id = :ws AND static_id = :sid';
  BEGIN
    EXECUTE IMMEDIATE v_sql INTO v_srv_id USING v_ws_id, v_static_id;
    DBMS_OUTPUT.PUT_LINE('APEX AI service ' || v_static_id || ' already exists — updating.');
    v_sql := 'UPDATE ' || v_apex_owner || '.wwv_remote_servers'
          || ' SET base_url = :url, ai_model_name = :mdl,'
          || '     credential_id = :cid,'
          || '     last_updated_on = SYSDATE, last_updated_by = USER'
          || ' WHERE id = :id';
    EXECUTE IMMEDIATE v_sql USING 'https://ollama-proxy:443/v1', 'llama3.2:3b', v_cred_id, v_srv_id;
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
        'Ollama llama3.2:3b', v_static_id,
        'https://ollama-proxy:443/v1', 'llama3.2:3b', v_cred_id;
      DBMS_OUTPUT.PUT_LINE('APEX AI service created: ' || v_static_id || ' -> https://ollama-proxy:443/v1 (model: llama3.2:3b)');
  END;

  -- Step C: Encrypt the credential secret via the APEX API so APEX can decrypt
  -- it at runtime with DBMS_CRYPTO (direct INSERT stores plaintext → ORA-28817).
  BEGIN
    apex_credential.set_persistent_credentials(
      p_credential_static_id => v_cred_sid,
      p_key                  => 'Authorization',
      p_value                => 'Bearer ollama-no-auth-needed'
    );
    DBMS_OUTPUT.PUT_LINE('Credential secret encrypted: ' || v_cred_sid);
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Credential encrypt note: ' || SQLERRM);
  END;

  COMMIT;
END;
/

PROMPT Ollama AI service setup complete.
PROMPT Ollama endpoint: https://ollama-proxy:443
PROMPT Ollama model:    llama3.2:3b
PROMPT
PROMPT Test from SQL:
PROMPT   SELECT DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT(
PROMPT     'Hello, tell me a joke',
PROMPT     JSON('{"provider":"ollama","host":"https://ollama-proxy:443","model":"llama3.2:3b"}')
PROMPT   ) FROM dual;

select sysdate from dual;
exit;
