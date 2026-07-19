-- oci-admin-grants.sql.tpl
-- Generic ADMIN grants for handing an APEX app + its schema over to an Oracle
-- ADB (on OCI, or any Oracle 23ai/26ai instance reached via SQL Developer /
-- Database Actions / sqlplus). Run as ADMIN, BEFORE importing the APEX app.
--
-- Set the two substitution variables below before running.
--   APEX_SCHEMA   the schema that will own the app (e.g. TRACKER1, MYAPP)
--   LLM_HOST      hostname ONLY (no scheme, no port) of the LLM endpoint your
--                 app's remote servers / Python workers call, e.g.
--                 api.x.ai, 10.0.1.23, or your own ollama-proxy host.
--                 Leave the placeholder if your app makes no outbound LLM calls.

DEFINE APEX_SCHEMA = __SCHEMA__
DEFINE LLM_HOST     = __LLM_HOST__

SET SERVEROUTPUT ON SIZE UNLIMITED

-- The schema owner must exist first. On ADB, create it via Database Actions >
-- Database Users, or:
--   CREATE USER &APEX_SCHEMA IDENTIFIED BY "<pwd>";
--   GRANT CONNECT, RESOURCE TO &APEX_SCHEMA;
--   ALTER USER &APEX_SCHEMA QUOTA UNLIMITED ON DATA;

GRANT CREATE SESSION      TO &APEX_SCHEMA;
GRANT CREATE TABLE        TO &APEX_SCHEMA;
GRANT CREATE VIEW         TO &APEX_SCHEMA;
GRANT CREATE SEQUENCE     TO &APEX_SCHEMA;
GRANT CREATE PROCEDURE    TO &APEX_SCHEMA;
GRANT CREATE TRIGGER      TO &APEX_SCHEMA;
GRANT CREATE JOB          TO &APEX_SCHEMA;

-- Needed only if your app's Supporting Objects create a property graph
-- (23ai/26ai feature). Harmless to grant if unused.
GRANT CREATE PROPERTY GRAPH TO &APEX_SCHEMA;

-- Needed only if your app loads an ONNX embedding model (see
-- load-onnx-model.sql.tpl) — a mining model is a generic Oracle 23ai/26ai
-- object, not tied to any particular app.
GRANT CREATE MINING MODEL TO &APEX_SCHEMA;
GRANT EXECUTE ON DBMS_VECTOR              TO &APEX_SCHEMA;
GRANT EXECUTE ON CTXSYS.DBMS_VECTOR_CHAIN TO &APEX_SCHEMA;
GRANT EXECUTE ON UTL_HTTP                 TO &APEX_SCHEMA;

-- Outbound ACL for the LLM host: required for APEX AI services and any
-- DBMS_VECTOR_CHAIN / UTL_HTTP call that leaves the database (including
-- load-onnx-model.sql.tpl fetching the model file).
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '&LLM_HOST',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('http', 'connect', 'resolve'),
              principal_name => '&APEX_SCHEMA',
              principal_type => xs_acl.ptype_db));
  DBMS_OUTPUT.PUT_LINE('ACL granted: &APEX_SCHEMA -> &LLM_HOST');
END;
/

-- APEX calls out as the APEX_YYMMDD schema, not as the app schema, so it needs
-- its own ACE on the same host for in-app AI services (Remote Servers) to work.
DECLARE
  l_apex_user VARCHAR2(128);
BEGIN
  SELECT username INTO l_apex_user
  FROM   all_users
  WHERE  username LIKE 'APEX\_2%' ESCAPE '\'
  ORDER  BY username DESC
  FETCH FIRST 1 ROW ONLY;

  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '&LLM_HOST',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('http', 'connect', 'resolve'),
              principal_name => l_apex_user,
              principal_type => xs_acl.ptype_db));
  DBMS_OUTPUT.PUT_LINE('ACL granted: ' || l_apex_user || ' -> &LLM_HOST');
END;
/

PROMPT
PROMPT === admin-grants complete ===
PROMPT Next: import the APEX app in Builder with "Install Supporting Objects" CHECKED,
PROMPT       then connect AS &APEX_SCHEMA and run any post-import SQL (app users, ONNX model).
