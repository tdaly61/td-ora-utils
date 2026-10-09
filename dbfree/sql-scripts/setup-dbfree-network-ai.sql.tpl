-- setup-dbfree-network-ai.sql.tpl
-- Configures outbound network access so this database can call a local
-- Ollama instance on the host over plain HTTP (plain Database Free does not
-- force REQUIRE_OUT_HTTPS=Y, so no TLS proxy is needed).
--
-- Scope note: this script is DB-layer only (ACLs + grants + a shared
-- credential on ADMIN) — it does NOT register an APEX Generative AI service
-- for a workspace, because at this stage of the POC no app/workspace exists
-- yet. Per-app AI service registration (wwv_remote_servers/wwv_credentials)
-- happens later, at app-import time, the same way
-- load-apex-app.sh's (this directory) Step 5 already does it —
-- reuse that pattern once an app is actually being imported.
--
-- Run as: ADMIN (the compat user created by create-admin-compat-user.sql.tpl)
-- against the target PDB.
--
-- Substitution tokens (replaced by run-dbfree.sh):
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

-- The native APEX Generative AI feature (apex_ai.generate, used by apps'
-- own "Execute Server-Side Code" processes/dynamic actions) makes its
-- UTL_HTTP call from inside a definer-rights package OWNED BY THE APEX
-- SCHEMA ITSELF (e.g. APEX_260100) — not the calling workspace schema, and
-- not ADMIN. Granting ACL to WEAVE32/ADMIN/SYSTEM is NOT enough for this
-- specific feature: without this grant it fails with ORA-29273 wrapping
-- ORA-24247 ("network access denied by access control list (ACL)"), which
-- reads like a generic HTTP failure and is easy to mistake for a bad
-- Ollama URL or a firewall problem — confirmed empirically (caseweave's
-- "ISet Analyser RAG+" page's apex_ai.generate() call). DBMS_VECTOR_CHAIN
-- calls (the connectivity test below, and the Step 4 vector/ONNX path in
-- load-apex-app.sh) don't need this — only the newer native AI Config
-- feature does. The schema name is version-specific, so detect it rather
-- than hardcode it.
DECLARE
  v_apex_schema VARCHAR2(128);
BEGIN
  SELECT username INTO v_apex_schema
    FROM dba_users
   WHERE username LIKE 'APEX\_2%' ESCAPE '\'
     AND oracle_maintained = 'Y'
     AND username NOT IN ('APEX_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','APEX_PUBLIC_ROUTER')
     AND ROWNUM = 1;
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect', 'resolve'),
              principal_name => v_apex_schema,
              principal_type => xs_acl.ptype_db));
  DBMS_OUTPUT.PUT_LINE('Network ACL granted to ' || v_apex_schema || ' (the APEX owning schema — needed for apex_ai.generate()).');
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE('APEX owning schema not found (APEX not installed yet?) — skipping, this step will need to be re-run after APEX installs.');
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('APEX schema ACL note: ' || SQLERRM);
END;
/

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. UTL_HTTP and DBMS_VECTOR_CHAIN execute privileges — granted to ADMIN by
--    run-dbfree.sh as a SYS pre-step immediately before this script runs, NOT
--    here: this script connects AS ADMIN, and `GRANT ... TO ADMIN` while
--    connected as ADMIN is a self-grant, which Oracle rejects unconditionally
--    with ORA-01749 regardless of whether the grant already took effect —
--    confirmed empirically. Nothing to do in this step.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Create DB credential for Ollama (used by DBMS_VECTOR_CHAIN).
--    Ollama has no auth, but Oracle requires a credential object. On a real
--    DBA-privileged ADMIN this should
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
  -- "host" must literally be the string "local" for a self-hosted Ollama —
  -- it is NOT where the endpoint goes (that was the bug here: passing the
  -- actual URL as "host" raises ORA-20003 invalid HOST value). The real
  -- endpoint, including the /api/generate path, goes in "url".
  v_result := DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT(
    'Reply with the single word: OK',
    JSON('{"provider":"ollama","host":"local","url":"__OLLAMA_BASE_URL__/api/generate","model":"__OLLAMA_MODEL__"}')
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
