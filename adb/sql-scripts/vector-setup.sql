-- vector-setup.sql
-- Placeholder — ONNX model loading has moved to app-level SQL.
--
-- run-adb-26ai.sh handles all infrastructure:
--   - downloads model.onnx to ~/model.onnx
--   - creates Oracle DIRECTORY 'ONNX_STAGING' pointing to the DBFS-visible path
--   - copies model.onnx into that path
--
-- Each app then loads its own named model via load-apex-app.sh -v <vector-setup.sql>.
-- Example: caseweave/apex-sql-src/Set_Up_Vector_Stuff.sql loads DOC_MODEL for WEAVE32.

select sysdate from dual;
exit;
