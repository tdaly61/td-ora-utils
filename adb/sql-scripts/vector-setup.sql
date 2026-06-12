-- Model setup
-- Loads all_MiniLM_L12_v2 ONNX model as DOC_MODEL (matches VECTOR_EMBEDDING(DOC_MODEL ...) usage)
-- Prerequisite: model.onnx must be copied into the DATA_PUMP_DIR inside the Oracle container
--   docker cp /home/ubuntu/model.onnx oracle-db:<DATA_PUMP_DIR_PATH>/model.onnx

BEGIN
   -- Drop existing model if present so this script is idempotent
   BEGIN
      DBMS_VECTOR.DROP_ONNX_MODEL(model_name => 'DOC_MODEL', force => TRUE);
   EXCEPTION
      WHEN OTHERS THEN NULL; -- model didn't exist, fine
   END;

   DBMS_VECTOR.LOAD_ONNX_MODEL(
        directory  => 'DATA_PUMP_DIR',
        file_name  => 'model.onnx',
        model_name => 'DOC_MODEL',
        metadata   => JSON('{"function":"embedding","embeddingOutput":"embedding","input":{"input":["DATA"]}}'));
END;
/

 
 
-- Check it is “loaded”
select
  model_name
  , mining_function
  , algorithm
  , (model_size/1024/1024) as model_size_mb
from user_mining_models
order by model_name;
 

select sysdate from dual; 
exit; 