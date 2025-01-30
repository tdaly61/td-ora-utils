-- Model setup
BEGIN
   DBMS_VECTOR.LOAD_ONNX_MODEL(
        directory => 'DATA_PUMP_DIR',
        file_name => 'all-MiniLM-L6-v2.onnx',
        model_name => 'ALL_MINILM_L6_V2');
END;
 / 
select sysdate from dual; 
exit 
 
 
-- Check it is “loaded”
-- select
--   model_name
--   , mining_function
--   , algorithm
--   , (model_size/1024/1024) as model_size_mb
-- from user_mining_models
-- order by model_name;
 



-- BEGIN
-- dbms_vector.load_onnx_model(
--     directory => 'MODELSDIR'
--     , file_name => 'all-MiniLM-L6-v2.onnx'
--     , model_name => 'all_minilm_l6_v2'
--     , metadata => json('{"function" : "embedding", "embeddingOutput" : "embedding" , "input": {"input": ["DATA"]}}')
--   );
-- END;

EXIT; 