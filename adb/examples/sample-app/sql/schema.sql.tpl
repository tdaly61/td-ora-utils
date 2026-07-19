-- sample-app-schema.sql
-- Creates the NOTES table (with 26ai VECTOR column) and loads sample data
-- with semantic embeddings generated from the ALL_MINILM ONNX model.
-- Run as __APEX_USER__ (generated from sample-app-schema.sql.tpl)

-- ── Drop if re-running ──────────────────────────────────────────────────────
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE notes PURGE';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

-- ── Table ───────────────────────────────────────────────────────────────────
CREATE TABLE notes (
    note_id      NUMBER         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title        VARCHAR2(200)  NOT NULL,
    body         VARCHAR2(4000) NOT NULL,
    category     VARCHAR2(50)   DEFAULT 'General',
    created_date DATE           DEFAULT SYSDATE,
    embedding    VECTOR         -- 26ai: semantic embedding of title || ' ' || body
);

-- ── Sample data ─────────────────────────────────────────────────────────────
INSERT INTO notes (title, body, category) VALUES (
  'Setting up Oracle Database Free 26ai',
  'Oracle Database Free 26ai runs in a Docker container. Use docker compose to start it alongside ORDS and APEX. The database supports JSON Relational Duality, True Cache, and native vector search.',
  'Database'
);
INSERT INTO notes (title, body, category) VALUES (
  'What is vector search?',
  'Vector search finds semantically similar content by comparing high-dimensional embeddings rather than exact keywords. Oracle 26ai stores vectors natively in the VECTOR datatype and supports approximate nearest-neighbour (ANN) search with HNSW and IVF indexes.',
  'AI'
);
INSERT INTO notes (title, body, category) VALUES (
  'Loading an ONNX model into Oracle',
  'Use DBMS_VECTOR.LOAD_ONNX_MODEL to load a pre-trained ONNX embedding model into the database. The model runs inside the database engine with no external call required. The ALL_MINILM model produces 384-dimensional vectors.',
  'AI'
);
INSERT INTO notes (title, body, category) VALUES (
  'Docker Compose for Oracle APEX',
  'Run two services: oracle-db (database/free) and ords (database/ords). ORDS auto-installs APEX 24.2 on first start from a mounted apex/ directory. Use depends_on with service_healthy to start ORDS only after the DB is ready.',
  'Infrastructure'
);
INSERT INTO notes (title, body, category) VALUES (
  'APEX Interactive Report tips',
  'Interactive Reports let users filter, sort, aggregate and download data without any developer involvement. Use Actions menu to save custom report views. Enable Email, CSV, and XLSX download in the IR attributes.',
  'APEX'
);
INSERT INTO notes (title, body, category) VALUES (
  'Oracle Instant Client SQLPlus',
  'Oracle Instant Client provides a lightweight SQLPlus client without a full Oracle installation. Download the Basic and SQLPlus packages, unzip them to the same directory, set LD_LIBRARY_PATH, and add to PATH.',
  'Database'
);
INSERT INTO notes (title, body, category) VALUES (
  'Creating APEX workspaces via PL/SQL',
  'Use APEX_INSTANCE_ADMIN.ADD_WORKSPACE to create an APEX workspace programmatically. Then APEX_UTIL.SET_WORKSPACE and APEX_UTIL.CREATE_USER to add an admin user. Useful in automated deployment scripts.',
  'APEX'
);
INSERT INTO notes (title, body, category) VALUES (
  'JSON Relational Duality in 26ai',
  'Duality Views expose relational tables as JSON documents. Applications can read and write JSON while the database stores it relationally. Changes via the JSON interface are immediately visible in relational queries and vice versa.',
  'Database'
);
INSERT INTO notes (title, body, category) VALUES (
  'SSH tunnels for remote APEX access',
  'When Oracle APEX runs on a remote server, forward local ports with: ssh -L 8080:localhost:8080 -L 5500:localhost:5500 -N user@server. Then access APEX at http://localhost:8080/ords/apex from your laptop browser.',
  'Infrastructure'
);
INSERT INTO notes (title, body, category) VALUES (
  'Monitoring Oracle containers',
  'Use docker logs -f oracle-db to stream database alert log output. docker logs -f ords shows APEX installation progress and ORDS runtime logs. docker ps shows container health status. EM Express is available at https://localhost:5500/em.',
  'Infrastructure'
);
COMMIT;

-- ── Populate vector embeddings ───────────────────────────────────────────────
-- Generates embeddings from title + body text using the ALL_MINILM ONNX model
-- ALL_MINILM was loaded into the SYSTEM schema by vector-setup.sql.
-- SYSTEM.ALL_MINILM was granted to __APEX_USER__ via create-users.sql.
UPDATE notes
SET    embedding = DBMS_VECTOR.UTL_TO_EMBEDDING(
           title || '. ' || body,
           JSON('{"provider":"database","model":"SYSTEM.ALL_MINILM"}')
       );
COMMIT;

SELECT note_id, title, category,
       ROUND(VECTOR_NORM(embedding), 4) AS emb_norm
FROM   notes
ORDER  BY note_id;

SELECT 'Sample data loaded: ' || COUNT(*) || ' notes with embeddings.' AS status
FROM   notes
WHERE  embedding IS NOT NULL;

exit
