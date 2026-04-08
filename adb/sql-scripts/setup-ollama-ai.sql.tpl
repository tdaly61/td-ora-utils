-- setup-ollama-ai.sql
-- Configures outbound network access and registers Ollama as a generative AI
-- provider so the Oracle 23ai Free database can call a local LLM.
-- Run as: SYS (or SYSTEM with DBA privileges) against FREEPDB1.
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
-- 2. Grant UTL_HTTP and network privileges to __APEX_USER__
-- ─────────────────────────────────────────────────────────────────────────────
GRANT EXECUTE ON UTL_HTTP TO __APEX_USER__;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Create credential for Ollama (Ollama has no auth, but Oracle requires a
--    credential object). Uses a dummy key.
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

GRANT EXECUTE ON DBMS_VECTOR_CHAIN TO __APEX_USER__;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Test connectivity to Ollama from inside the database
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE
  v_url      VARCHAR2(500) := '__OLLAMA_BASE_URL__/api/tags';
  v_req      UTL_HTTP.REQ;
  v_resp     UTL_HTTP.RESP;
  v_body     VARCHAR2(4000);
BEGIN
  UTL_HTTP.SET_TRANSFER_TIMEOUT(10);
  v_req  := UTL_HTTP.BEGIN_REQUEST(v_url, 'GET');
  v_resp := UTL_HTTP.GET_RESPONSE(v_req);
  UTL_HTTP.READ_TEXT(v_resp, v_body, 4000);
  UTL_HTTP.END_RESPONSE(v_resp);
  DBMS_OUTPUT.PUT_LINE('Ollama connectivity test PASSED (HTTP ' || v_resp.status_code || ')');
  DBMS_OUTPUT.PUT_LINE('Available models: ' || SUBSTR(v_body, 1, 500));
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Ollama connectivity test FAILED: ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('Ensure ollama is running on the host with OLLAMA_HOST=0.0.0.0');
    DBMS_OUTPUT.PUT_LINE('Attempted URL: ' || v_url);
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
