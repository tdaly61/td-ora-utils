-- load-onnx-model.sql.tpl
-- Generic ONNX embedding-model loader for Oracle 23ai/26ai (DBMS_VECTOR).
-- Fetches the model bytes over plain HTTPS via UTL_HTTP (works equally against a
-- local ollama-proxy URL or a public OCI object-storage pre-authenticated URL —
-- no OCI-specific client library required), then registers it as a named mining
-- model. Idempotent: skips the load if the model already exists.
--
-- Substitute the two tokens before running (sed, or via a wrapper script):
--   __MODEL_NAME__   the mining-model name your app references, e.g. MY_EMBED_MODEL
--   __ONNX_URL__     HTTPS URL to the .onnx file
--
-- Run connected AS THE SCHEMA OWNER (not ADMIN) — user_mining_models is scoped
-- per-account, and the owner needs CREATE MINING MODEL + EXECUTE ON DBMS_VECTOR
-- (granted by the generic admin-grants template) for LOAD_ONNX_MODEL to succeed.
-- This file assumes the caller has already connected; it contains no CONNECT
-- statement of its own so it composes cleanly whether invoked interactively,
-- via `sqlplus ... @this_file`, or wrapped by another script.
--
-- Requires: outbound network ACL for the schema owner to the __ONNX_URL__ host
-- (UTL_HTTP privilege + DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE — see the generic
-- admin-grants template).

SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_exists    NUMBER;
  l_http_req  UTL_HTTP.REQ;
  l_http_resp UTL_HTTP.RESP;
  l_raw       RAW(32767);
  l_blob      BLOB;
BEGIN
  SELECT COUNT(*) INTO v_exists
  FROM   user_mining_models
  WHERE  model_name = '__MODEL_NAME__';

  IF v_exists > 0 THEN
    DBMS_OUTPUT.PUT_LINE('__MODEL_NAME__ already loaded — skipping.');
    RETURN;
  END IF;

  DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);

  l_http_req := UTL_HTTP.BEGIN_REQUEST('__ONNX_URL__');
  UTL_HTTP.SET_HEADER(l_http_req, 'User-Agent', 'td-ora-utils/load-onnx-model');
  l_http_resp := UTL_HTTP.GET_RESPONSE(l_http_req);

  BEGIN
    LOOP
      UTL_HTTP.READ_RAW(l_http_resp, l_raw, 32767);
      DBMS_LOB.WRITEAPPEND(l_blob, UTL_RAW.LENGTH(l_raw), l_raw);
    END LOOP;
  EXCEPTION
    WHEN UTL_HTTP.END_OF_BODY THEN
      UTL_HTTP.END_RESPONSE(l_http_resp);
  END;

  DBMS_OUTPUT.PUT_LINE('Fetched ' || DBMS_LOB.GETLENGTH(l_blob) || ' bytes from __ONNX_URL__');

  DBMS_VECTOR.LOAD_ONNX_MODEL(
    model_name => '__MODEL_NAME__',
    model_data => l_blob,
    metadata   => JSON('{
                    "function"        : "embedding",
                    "embeddingOutput" : "embedding",
                    "input"           : {"input": ["DATA"]}
                  }'));

  DBMS_LOB.FREETEMPORARY(l_blob);
  DBMS_OUTPUT.PUT_LINE('__MODEL_NAME__ loaded successfully.');
END;
/

-- Smoke test: must return a vector.
SELECT TO_VECTOR(VECTOR_EMBEDDING(__MODEL_NAME__ USING 'The cat sat on the mat' AS DATA)) AS test_embedding
FROM   dual;

PROMPT
PROMPT === __MODEL_NAME__ load complete ===
PROMPT If the SELECT above returned a vector, __MODEL_NAME__ is working.
