-- setup-ee-network-ai.sql.tpl
-- Configures outbound network access so this database can call a local
-- Ollama instance on the host, without the ollama-proxy TLS-termination
-- layer the adb-free setup needs (neither Database Free nor Enterprise
-- Edition force REQUIRE_OUT_HTTPS=Y the way ADB-Free does).
--
-- Scope note: this script is DB-layer only (ACLs + grants + a shared
-- credential on ADMIN) — it does NOT register an APEX Generative AI service
-- for a workspace, because at this stage of the POC no app/workspace exists
-- yet. Per-app AI service registration (wwv_remote_servers/wwv_credentials)
-- happens later, at app-import time, the same way
-- adb/load-apex-app.sh's Step 5 already does it for the adb-free setup —
-- reuse that pattern once an app is actually being imported.
--
-- Run as: ADMIN (the compat user created by create-admin-compat-user.sql.tpl)
-- against the target PDB.
--
-- Substitution tokens (replaced by run-ee.sh):
--   __OLLAMA_BASE_URL__ — Ollama endpoint from inside Docker (e.g. http://host.docker.internal:11434)
--   __OLLAMA_MODEL__    — Ollama model name (e.g. llama3.2:3b)

SET SERVEROUTPUT ON;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Network ACL — allow ADMIN and SYSTEM to connect out (UTL_HTTP)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect', 'resolve'),
              principal_name => 'ADMIN',
              principal_type => xs_acl.ptype_db));
  DBMS_OUTPUT.PUT_LINE('Network ACL granted to ADMIN.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('ADMIN ACL note: ' || SQLERRM);
END;
/

BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect', 'resolve'),
              principal_name => 'SYSTEM',
              principal_type => xs_acl.ptype_db));
  DBMS_OUTPUT.PUT_LINE('Network ACL granted to SYSTEM.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('SYSTEM ACL note: ' || SQLERRM);
END;
/

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Grant UTL_HTTP and DBMS_VECTOR_CHAIN to ADMIN (smoke-test callable)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN
  EXECUTE IMMEDIATE 'GRANT EXECUTE ON SYS.UTL_HTTP TO ADMIN';
  DBMS_OUTPUT.PUT_LINE('GRANT EXECUTE ON UTL_HTTP to ADMIN succeeded.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('UTL_HTTP grant note: ' || SQLERRM);
END;
/

BEGIN
  EXECUTE IMMEDIATE 'GRANT EXECUTE ON CTXSYS.DBMS_VECTOR_CHAIN TO ADMIN';
  DBMS_OUTPUT.PUT_LINE('GRANT EXECUTE ON DBMS_VECTOR_CHAIN to ADMIN succeeded.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('DBMS_VECTOR_CHAIN grant note: ' || SQLERRM);
END;
/

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Create DB credential for Ollama (used by DBMS_VECTOR_CHAIN).
--    Ollama has no auth, but Oracle requires a credential object. On a real
--    DBA-privileged ADMIN (unlike ADB-Free's constrained account) this should
--    just succeed — a failure here is worth investigating, not expected.
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
    DBMS_OUTPUT.PUT_LINE('Note: OLLAMA_CRED creation failed (' || SQLERRM || ') — unexpected on a DBA-privileged account, investigate.');
END;
/

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Connectivity smoke test — confirms UTL_HTTP can actually reach Ollama.
-- ─────────────────────────────────────────────────────────────────────────────
SET SERVEROUTPUT ON;
DECLARE
  v_result CLOB;
BEGIN
  v_result := DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT(
    'Reply with the single word: OK',
    JSON('{"provider":"ollama","host":"__OLLAMA_BASE_URL__","model":"__OLLAMA_MODEL__"}')
  );
  DBMS_OUTPUT.PUT_LINE('Ollama connectivity test response: ' || SUBSTR(v_result, 1, 200));
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Ollama connectivity test FAILED (non-fatal for this script): ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('  Check that Ollama is running on the host and __OLLAMA_MODEL__ is pulled.');
END;
/

PROMPT Network/AI setup complete.
select sysdate from dual;
exit;
