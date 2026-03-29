-- sample-app-create.sql
-- Creates the Sample Notes & Vector Search APEX application (App 100)
-- in the TRACKER1 workspace programmatically via wwv_flow_api.
-- Run as SYSTEM: sqlplus system/Welcome_MY_ATP_123@FREEPDB1 @sample-app-create.sql

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
  c_workspace  CONSTANT VARCHAR2(100) := 'TRACKER1';
  c_schema     CONSTANT VARCHAR2(100) := 'TRACKER1';
  c_app_id     CONSTANT NUMBER        := 100;
  c_app_name   CONSTANT VARCHAR2(100) := 'Notes & Vector Search';
  c_app_alias  CONSTANT VARCHAR2(100) := 'SAMPLE-NOTES';
  l_ws_id      NUMBER;

BEGIN
  -- ── Locate workspace ────────────────────────────────────────────────────
  l_ws_id := wwv_flow_api.find_security_group_id(p_company => c_workspace);
  IF l_ws_id IS NULL THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Workspace "' || c_workspace || '" not found. '
      || 'Run run-adb-26ai.sh first to create the workspace.');
  END IF;
  wwv_flow_api.set_security_group_id(p_security_group_id => l_ws_id);
  wwv_flow_application_install.set_application_id(c_app_id);
  DBMS_OUTPUT.PUT_LINE('Workspace ID: ' || l_ws_id);

  -- ── Remove existing app if present ─────────────────────────────────────
  BEGIN
    wwv_flow_api.remove_flow(c_app_id);
    DBMS_OUTPUT.PUT_LINE('Removed existing App ' || c_app_id);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- ── Create application ──────────────────────────────────────────────────
  wwv_flow_api.create_flow(
    p_id                         => c_app_id,
    p_owner                      => c_schema,
    p_name                       => c_app_name,
    p_alias                      => c_app_alias,
    p_page_view_logging          => 'YES',
    p_flow_language              => 'en',
    p_flow_language_derived_from => 'FLOW_PRIMARY_LANGUAGE',
    p_date_format                => 'DD-MON-YYYY',
    p_ui_type_name               => 'DESKTOP',
    p_bookmark_checksum_function => 'SH512',
    p_accept_old_checksums       => 'N'
  );
  DBMS_OUTPUT.PUT_LINE('Application ' || c_app_id || ' skeleton created.');

  -- ── Page 1: Notes Interactive Report ────────────────────────────────────
  wwv_flow_api.create_page(
    p_id                       => 1,
    p_flow_id                  => c_app_id,
    p_flow_step_id             => 1,
    p_step_title               => 'Notes',
    p_reload_on_submit         => 'A',
    p_warn_on_unsaved_changes  => 'N',
    p_protection_level         => 'C'
  );

  -- Interactive Report region (no template ID — APEX uses theme default)
  wwv_flow_api.create_page_plug(
    p_id                         => 10,
    p_flow_id                    => c_app_id,
    p_page_id                    => 1,
    p_plug_name                  => 'Notes',
    p_plug_display_sequence      => 10,
    p_plug_display_point         => 'BODY',
    p_plug_query_stmt            =>
      'SELECT NOTE_ID, TITLE, CATEGORY, CREATED_DATE, BODY ' ||
      'FROM   NOTES ' ||
      'ORDER  BY CREATED_DATE DESC',
    p_plug_type                  => 'Native_IR',
    p_ajax_enabled               => 'Y',
    p_query_type                 => 'SQL',
    p_plug_query_headings_type   => 'QUERY_COLUMNS',
    p_plug_query_show_nulls_as   => '-',
    p_pagination_display_position => 'BOTTOM_RIGHT'
  );

  -- ── Page 2: Semantic (Vector) Search ────────────────────────────────────
  wwv_flow_api.create_page(
    p_id                       => 2,
    p_flow_id                  => c_app_id,
    p_flow_step_id             => 2,
    p_step_title               => 'Semantic Search',
    p_reload_on_submit         => 'A',
    p_warn_on_unsaved_changes  => 'N',
    p_protection_level         => 'C'
  );

  -- Search input item
  wwv_flow_api.create_page_item(
    p_id                       => 20,
    p_flow_id                  => c_app_id,
    p_flow_step_id             => 2,
    p_name                     => 'P2_SEARCH',
    p_item_sequence            => 10,
    p_item_plug_id             => 0,
    p_display_as               => 'NATIVE_TEXT_FIELD',
    p_label                    => 'Search',
    p_cSize                    => 60,
    p_field_template           => 0,
    p_item_template_options    => '#DEFAULT#',
    p_attribute_01             => 'N',
    p_attribute_02             => 'N',
    p_attribute_04             => 'text',
    p_attribute_05             => 'both'
  );

  -- Results region: top-5 nearest neighbours by cosine distance
  wwv_flow_api.create_page_plug(
    p_id                         => 21,
    p_flow_id                    => c_app_id,
    p_page_id                    => 2,
    p_plug_name                  => 'Nearest Notes',
    p_plug_display_sequence      => 20,
    p_plug_display_point         => 'BODY',
    p_plug_query_stmt            =>
      'SELECT n.note_id, ' ||
      '       n.title, ' ||
      '       n.category, ' ||
      '       n.created_date, ' ||
      '       n.body, ' ||
      '       ROUND(VECTOR_DISTANCE( ' ||
      '           n.embedding, ' ||
      '           DBMS_VECTOR.UTL_TO_EMBEDDING( ' ||
      '               :P2_SEARCH, ' ||
      '               JSON(''{"provider":"database","model":"ALL_MINILM"}'') ' ||
      '           ), COSINE ' ||
      '       ), 4) AS similarity_distance ' ||
      'FROM   notes n ' ||
      'WHERE  :P2_SEARCH IS NOT NULL ' ||
      'ORDER  BY similarity_distance ' ||
      'FETCH FIRST 5 ROWS ONLY',
    p_plug_type                  => 'Native_IR',
    p_ajax_enabled               => 'Y',
    p_query_type                 => 'SQL',
    p_plug_query_headings_type   => 'QUERY_COLUMNS',
    p_plug_query_show_nulls_as   => '-',
    p_pagination_display_position => 'BOTTOM_RIGHT'
  );

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('=== App ' || c_app_id || ' created successfully ===');
  DBMS_OUTPUT.PUT_LINE('Page 1 — Notes IR:       http://localhost:8080/ords/f?p=' || c_app_id || ':1');
  DBMS_OUTPUT.PUT_LINE('Page 2 — Vector Search:  http://localhost:8080/ords/f?p=' || c_app_id || ':2');
  DBMS_OUTPUT.PUT_LINE('Login: workspace=' || c_workspace || '  user=' || c_workspace);

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('ERROR creating app via PL/SQL API: ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Create the app manually in APEX Builder (2 minutes):');
    DBMS_OUTPUT.PUT_LINE('  1. Open http://localhost:8080/ords/apex');
    DBMS_OUTPUT.PUT_LINE('  2. Log in: workspace=' || c_workspace || '  user=' || c_workspace);
    DBMS_OUTPUT.PUT_LINE('  3. App Builder → Create → New Application');
    DBMS_OUTPUT.PUT_LINE('  4. Name: "Notes & Vector Search"  Schema: ' || c_schema);
    DBMS_OUTPUT.PUT_LINE('  5. Add Page → Interactive Report → Table: NOTES');
    DBMS_OUTPUT.PUT_LINE('  6. Create Application');
    RAISE;
END;
/

exit
