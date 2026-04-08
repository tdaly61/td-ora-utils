- TO allow all restful services connect as sys FREEPDB1 and run below:
BEGIN
    DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
        host => '*',
        ace => xs$ace_type(privilege_list => xs$name_list('connect'),
                           principal_name => APEX_APPLICATION.g_flow_schema_owner,
                           principal_type => xs_acl.ptype_db));
END;
