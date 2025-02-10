create user TRACKER1 identified by Welcome_MY_ATP_123;
grant DWROLE, CONNECT, RESOURCE, SODA_APP, unlimited tablespace to TRACKER1;
grant create view to TRACKER1;
grant create materialized view to TRACKER1;
grant create procedure to TRACKER1;
GRANT DB_DEVELOPER_ROLE, CREATE MINING MODEL TO TRACKER1;
GRANT READ ON DIRECTORY DATA_PUMP_DIR TO TRACKER1;
GRANT WRITE ON DIRECTORY DATA_PUMP_DIR TO TRACKER1;
exec apex_instance_admin.add_workspace(p_workspace => 'TRACKER1', p_primary_schema => 'TRACKER1');
begin
apex_util.set_workspace(p_workspace => 'TRACKER1');
apex_util.create_user(
  p_user_name => 'TRACKER1',
  p_web_password => 'Welcome_MY_ATP_123',
  p_developer_privs => 'ADMIN:CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL',
  p_email_address => 'TRACKER1@withoracle.cloud',
  p_default_schema => 'TRACKER1',
  p_change_password_on_first_use => 'N');
end;
/ 
select sysdate from dual; 
exit  

-- -- Create user tracker1
-- CREATE USER tracker1 IDENTIFIED BY Welcome_MY_ATP_123;
-- GRANT CONNECT, RESOURCE TO tracker1;
-- ALTER USER tracker1 QUOTA UNLIMITED ON USERS;

-- -- Grant additional privileges to tracker1
-- GRANT CREATE SESSION TO tracker1;
-- GRANT CREATE TABLE TO tracker1;
-- GRANT CREATE VIEW TO tracker1;
-- GRANT CREATE PROCEDURE TO tracker1;
-- GRANT CREATE SEQUENCE TO tracker1;
-- GRANT CREATE TRIGGER TO tracker1;
-- GRANT CREATE TYPE TO tracker1;
-- GRANT CREATE MATERIALIZED VIEW TO tracker1;
-- -- Grant DW_ROLE to tracker1;
-- grant execute on DBMS_VECTOR to tracker1;
-- grant CREATE MINING MODEL to tracker1;
-- grant create mining model to tracker1;
-- grant execute on c##cloud$service.dbms_cloud to tracker1;
-- grant execute on sys.dbms_vector to tracker1;
-- grant execute on ctxsys.dbms_vector_chain to tracker1;
-- CREATE OR REPLACE directory MODELSDIR as '.';
-- GRANT READ,WRITE  on  DIRECTORY MODELSDIR to tracker1;

-- Enable Graph and REST for tracker1
-- GRANT GRAPH_DEVELOPER TO tracker1;
-- EXEC DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
--     host => '*',
--     ace => xs$ace_type(privilege_list => xs$name_list('http'),
--                        principal_name => 'TRACKER1',
--                        principal_type => xs_acl.ptype_db));