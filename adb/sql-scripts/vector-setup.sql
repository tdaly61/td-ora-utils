-- vector-setup.sql
-- Placeholder — ONNX model loading is app-level, using the generic template at
-- sql-scripts/load-onnx-model.sql.tpl (not this file).
--
-- run-adb-26ai.sh handles all infrastructure:
--   - downloads model.onnx to ~/model.onnx
--   - creates Oracle DIRECTORY 'ONNX_STAGING' pointing to the DBFS-visible path
--   - copies model.onnx into that path
--   - serves it over HTTPS at https://ollama-proxy:443/onnx-models/model.onnx
--
-- To load a named model for your app: render load-onnx-model.sql.tpl by
-- substituting __MODEL_NAME__ (e.g. MY_EMBED_MODEL) and __ONNX_URL__ (the
-- ollama-proxy URL above, or a public OCI object-storage URL for cloud
-- deployments), then run it connected as the schema owner — or pass it to
-- load-apex-app.sh -v <rendered_file>.

select sysdate from dual;
exit;
