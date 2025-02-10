-- Model setup

BEGIN
   DBMS_VECTOR.LOAD_ONNX_MODEL(
        directory => 'DATA_PUMP_DIR',
        file_name => 'model.onnx',
        model_name => 'ALL_MINILM');
END;
/

 
 
Check it is “loaded”
select
  model_name
  , mining_function
  , algorithm
  , (model_size/1024/1024) as model_size_mb
from user_mining_models
order by model_name;
 

select sysdate from dual; 
exit; 