-- probe-report-type.sql
-- Discovers the valid p_report_type value for WWV_FLOW_WIZARD_API.CREATE_REPORT_PAGE
-- in this APEX version by trying candidate values and printing the first one that works.
-- Run as SYSTEM. Outputs one line: REPORT_TYPE=<value>

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET HEADING OFF
WHENEVER SQLERROR CONTINUE

DECLARE
  l_ws_id NUMBER;
  l_types SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST(
    'IR', 'INTERACTIVE_REPORT', 'interactive_report', 'ir',
    'CLASSIC', 'CR', 'REPORT', 'classic_report', 'report'
  );
  l_found VARCHAR2(100) := NULL;
BEGIN
  SELECT workspace_id INTO l_ws_id FROM apex_workspaces WHERE workspace = '__APEX_USER__';
  wwv_flow_api.set_security_group_id(p_security_group_id => l_ws_id);

  FOR i IN 1..l_types.COUNT LOOP
    EXIT WHEN l_found IS NOT NULL;
    BEGIN
      SAVEPOINT before_probe;
      apex_240200.wwv_flow_wizard_api.create_report_page(
        p_flow_id    => 100,
        p_page_id    => 9999,
        p_page_name  => 'Probe',
        p_page_mode  => 'NORMAL',
        p_table_owner => '__APEX_USER__',
        p_table_name  => 'NOTES',
        p_report_type => l_types(i)
      );
      l_found := l_types(i);
      ROLLBACK TO before_probe;
    EXCEPTION WHEN OTHERS THEN
      ROLLBACK TO before_probe;
    END;
  END LOOP;

  IF l_found IS NOT NULL THEN
    DBMS_OUTPUT.PUT_LINE('REPORT_TYPE=' || l_found);
  ELSE
    -- Fall back to NULL (the default), which lets APEX pick
    DBMS_OUTPUT.PUT_LINE('REPORT_TYPE=');
  END IF;
END;
/
exit
