#!/usr/bin/env bash
# load-sample-app.sh
# Loads the sample Notes & Vector Search APEX application into the running
# Oracle 26ai + APEX environment.
#
# Prerequisites:
#   - run-adb-26ai.sh has already completed successfully
#   - Oracle Instant Client (SQLPlus) is on PATH or at ~/oraclient/
#
# Usage:  ./load-sample-app.sh

set -euo pipefail

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_FILE="$RUN_DIR/config.ini"

# ── Read config ──────────────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
  echo "config.ini not found in $RUN_DIR. Exiting."
  exit 1
fi

ini_val() { grep -m1 "^${1}=" "$CONFIG_FILE" | cut -d'=' -f2- | tr -d ' \n\r'; }

DEFAULT_PASSWORD=$(ini_val DEFAULT_PASSWORD)
SERVICE_NAME=$(ini_val SERVICE_NAME)
ORACLE_CLIENT_DIR="$HOME/oraclient"
APEX_PORT=$(ini_val APEX_PORT); APEX_PORT=${APEX_PORT:-8080}
APEX_USER=$(ini_val APEX_USER);  APEX_USER=${APEX_USER:-TRACKER1}
APEX_PASSWORD=$(ini_val APEX_PASSWORD); APEX_PASSWORD=${APEX_PASSWORD:-$DEFAULT_PASSWORD}

# Pick Mac or Linux Instant Client directory name
if [ "$(uname -s)" = "Darwin" ]; then
  INSTANT_CLIENT=$(ini_val INSTANT_CLIENT_MAC)
fi
INSTANT_CLIENT=${INSTANT_CLIENT:-$(ini_val INSTANT_CLIENT)}

SQLPLUS="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus"
if [ ! -x "$SQLPLUS" ]; then
  echo "SQLPlus not found at $SQLPLUS."
  echo "Run ./setup-for-adb-26ai.sh first, or add Instant Client to PATH."
  exit 1
fi

export TNS_ADMIN="$HOME/auth/tns"
export LD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
export DYLD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"

# ── Generate SQL from templates ──────────────────────────────────────────────
generate_sql() {
  local tpl="$1"
  local out="${tpl%.tpl}"
  sed -e "s/__APEX_USER__/$APEX_USER/g" \
      -e "s/__APEX_PASSWORD__/$APEX_PASSWORD/g" \
      -e "s/__DEFAULT_PASSWORD__/$DEFAULT_PASSWORD/g" \
      -e "s/__SERVICE_NAME__/$SERVICE_NAME/g" \
      -e "s/__APEX_PORT__/$APEX_PORT/g" \
      "$tpl" > "$out"
  echo "$out"
}

SCHEMA_SQL=$(generate_sql "$RUN_DIR/sql-scripts/sample-app/schema.sql.tpl")
CREATE_SQL=$(generate_sql "$RUN_DIR/sql-scripts/sample-app/apex-create.sql.tpl")

# ── Step 1: Create schema objects and sample data ────────────────────────────
echo ""
echo "=== Step 1: Creating NOTES table and loading sample data as $APEX_USER ==="
"$SQLPLUS" -s "$APEX_USER/$APEX_PASSWORD@$SERVICE_NAME" "@$SCHEMA_SQL"
echo "Schema step complete."

# ── Step 2: Grant APEX API access to APEX_USER (requires SYS) ───────────────
echo ""
echo "=== Step 2: Granting APEX API execute to $APEX_USER ==="
"$SQLPLUS" -s "sys/$DEFAULT_PASSWORD@$SERVICE_NAME as sysdba" << SYSDBA_EOF
GRANT EXECUTE ON APEX_240200.WWV_FLOW_WIZARD_API             TO $APEX_USER;
GRANT EXECUTE ON APEX_240200.WWV_FLOW_API                    TO $APEX_USER;
GRANT EXECUTE ON APEX_240200.WWV_IMP_WORKSPACE               TO $APEX_USER;
GRANT EXECUTE ON APEX_240200.WWV_FLOW_IMP                    TO $APEX_USER;
GRANT EXECUTE ON APEX_240200.WWV_FLOW_IMP_SHARED             TO $APEX_USER;
GRANT EXECUTE ON APEX_240200.WWV_FLOW_APPLICATION_INSTALL    TO $APEX_USER;
GRANT SELECT  ON APEX_240200.WWV_FLOW_THEMES                 TO $APEX_USER;
GRANT SELECT  ON APEX_240200.WWV_FLOW_WORKSHEETS             TO $APEX_USER;
exit
SYSDBA_EOF

# ── Step 3: Create APEX application (as workspace schema user) ───────────────
echo ""
echo "=== Step 3: Creating APEX application (App 100) as $APEX_USER ==="
"$SQLPLUS" -s "$APEX_USER/$APEX_PASSWORD@$SERVICE_NAME" "@$CREATE_SQL" 2>&1

# ── Step 4: Wire auth + copy Universal Theme 42 templates (requires SYS) ────
# Two things only SYS can do:
#  a) Set wwv_flows.authentication_id to link the auth scheme we just created
#  b) INSERT a theme record for App 100 by copying all template IDs from the
#     global Universal Theme 42 entry (theme_security_group_id IS NULL).
#     create_theme via PL/SQL only creates a bare record with NULL template IDs;
#     this copy is what makes the pages actually render.
echo ""
echo "=== Step 4: Wiring auth and Universal Theme for App 100 ==="
"$SQLPLUS" -s "sys/$DEFAULT_PASSWORD@$SERVICE_NAME as sysdba" << SYSDBA2_EOF
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
  l_auth_id NUMBER;
  l_ws_id   NUMBER;
BEGIN
  SELECT workspace_id INTO l_ws_id
  FROM   apex_workspaces
  WHERE  workspace = '$APEX_USER';

  -- 4a. Link authentication scheme
  SELECT id INTO l_auth_id
  FROM   apex_240200.wwv_flow_authentications
  WHERE  flow_id = 100
  AND    security_group_id = l_ws_id
  FETCH FIRST 1 ROW ONLY;

  UPDATE apex_240200.wwv_flows
  SET    authentication_id = l_auth_id
  WHERE  id = 100
  AND    security_group_id = l_ws_id;

  DBMS_OUTPUT.PUT_LINE('Auth linked: auth_id=' || l_auth_id);

  -- 4b. Copy Universal Theme 42 template IDs from the global UT entry
  --     (theme_security_group_id IS NULL = APEX-managed global theme definition).
  --     This gives the app real page/region/button templates to render with.
  DELETE FROM apex_240200.wwv_flow_themes
  WHERE  flow_id = 100 AND security_group_id = l_ws_id;

  INSERT INTO apex_240200.wwv_flow_themes (
    id, flow_id, theme_id, navigation_type, nav_bar_type,
    security_group_id,
    theme_name, theme_internal_name, version_identifier, reference_id,
    is_locked, files_version,
    default_page_template, default_dialog_template, error_template,
    printer_friendly_template, login_template,
    default_button_template, default_region_template,
    default_chart_template, default_form_template,
    default_reportr_template, default_tabform_template,
    default_wizard_template, default_menur_template,
    default_listr_template, default_irr_template,
    default_report_template, default_label_template,
    default_menu_template, default_calendar_template,
    default_list_template, default_nav_list_position,
    default_nav_list_template, default_top_nav_list_template,
    default_side_nav_list_template,
    default_required_label, default_dialogr_template,
    default_dialogbtnr_template,
    breadcrumb_display_point, sidebar_display_point,
    default_nav_bar_list_template,
    file_prefix, calendar_icon, calendar_icon_attr,
    custom_icon_classes, custom_library_file_urls,
    custom_icon_prefix_class, icon_library,
    javascript_file_urls, css_file_urls,
    created_by, created_on, last_updated_by, last_updated_on
  )
  SELECT
    ROUND(DBMS_RANDOM.VALUE(1e9, 9e9)), 100, theme_id,
    navigation_type, nav_bar_type,
    l_ws_id,
    theme_name, theme_internal_name, version_identifier, reference_id,
    'N', files_version,
    default_page_template, default_dialog_template, error_template,
    printer_friendly_template, login_template,
    default_button_template, default_region_template,
    default_chart_template, default_form_template,
    default_reportr_template, default_tabform_template,
    default_wizard_template, default_menur_template,
    default_listr_template, default_irr_template,
    default_report_template, default_label_template,
    default_menu_template, default_calendar_template,
    default_list_template, default_nav_list_position,
    default_nav_list_template, default_top_nav_list_template,
    default_side_nav_list_template,
    default_required_label, default_dialogr_template,
    default_dialogbtnr_template,
    breadcrumb_display_point, sidebar_display_point,
    default_nav_bar_list_template,
    file_prefix, calendar_icon, calendar_icon_attr,
    custom_icon_classes, custom_library_file_urls,
    custom_icon_prefix_class, icon_library,
    javascript_file_urls, css_file_urls,
    USER, SYSDATE, USER, SYSDATE
  FROM  apex_240200.wwv_flow_themes
  WHERE theme_id = 42
  AND   theme_security_group_id IS NULL
  FETCH FIRST 1 ROW ONLY;

  -- 4c. Fix login page template (create_login_page defaults to Standard;
  --     must explicitly set it to the Login template from the theme)
  UPDATE apex_240200.wwv_flow_steps
  SET    step_template = (
      SELECT login_template
      FROM   apex_240200.wwv_flow_themes
      WHERE  flow_id = 100 AND security_group_id = l_ws_id
  )
  WHERE  flow_id = 100 AND id = 9999;

  -- 4d. Fix login REGION template (plug_template in wwv_flow_page_plugs).
  --     create_login_page leaves plug_template NULL; must be the UT42 Login region template.
  --     Dynamic lookup: find it from any other app in this installation that has a
  --     properly-rendered login page (step_template = theme's login_template, theme_id = 42).
  --     Falls back to the known APEX 24.2 / UT42 Login region template ID.
  DECLARE
    l_login_region_tpl NUMBER;
  BEGIN
    BEGIN
      SELECT p.plug_template INTO l_login_region_tpl
      FROM   apex_240200.wwv_flow_page_plugs p
      JOIN   apex_240200.wwv_flow_steps      s
               ON s.flow_id = p.flow_id AND s.id = p.page_id
      JOIN   apex_240200.wwv_flow_themes     t
               ON t.flow_id = s.flow_id AND t.theme_id = 42
      WHERE  s.step_template = t.login_template
      AND    p.plug_template IS NOT NULL
      AND    p.flow_id != 100
      FETCH FIRST 1 ROW ONLY;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      -- APEX 24.2 Universal Theme 42 — Login region template (consistent across installs)
      l_login_region_tpl := 2674157997338192145;
    END;

    UPDATE apex_240200.wwv_flow_page_plugs
    SET    plug_template = l_login_region_tpl
    WHERE  flow_id = 100 AND page_id = 9999;

    DBMS_OUTPUT.PUT_LINE('Login region template set: ' || l_login_region_tpl);
  END;

  -- 4e. Wire Navigation Menu + Navigation Bar lists onto wwv_flows.
  --     navigation_list_id  → drives hamburger/side nav
  --     nav_bar_list_id     → drives top-right nav bar (Sign Out, username)
  --     nav_bar_type        → must be 'LIST' (not the default 'NAVBAR')
  --     nav_bar_list_template_id → from theme's default_nav_bar_list_template
  DECLARE
    l_nav_menu_id NUMBER;
    l_nav_bar_id  NUMBER;
    l_nav_bar_tpl NUMBER;
  BEGIN
    SELECT id INTO l_nav_menu_id
    FROM   apex_240200.wwv_flow_lists
    WHERE  flow_id = 100 AND name = 'Navigation Menu';

    SELECT id INTO l_nav_bar_id
    FROM   apex_240200.wwv_flow_lists
    WHERE  flow_id = 100 AND name = 'Navigation Bar';

    SELECT default_nav_bar_list_template INTO l_nav_bar_tpl
    FROM   apex_240200.wwv_flow_themes
    WHERE  flow_id = 100 AND security_group_id = l_ws_id;

    UPDATE apex_240200.wwv_flows
    SET    navigation_list_id       = l_nav_menu_id,
           nav_bar_list_id          = l_nav_bar_id,
           nav_bar_type             = 'LIST',
           nav_bar_list_template_id = l_nav_bar_tpl
    WHERE  id = 100 AND security_group_id = l_ws_id;

    DBMS_OUTPUT.PUT_LINE('Nav Menu wired: ' || l_nav_menu_id || '  Nav Bar wired: ' || l_nav_bar_id);
  END;

  -- 4f. Fix IR region plug_template (create_ir_region_on_col_info leaves it NULL).
  --     Must be the default_irr_template from the theme subscription.
  UPDATE apex_240200.wwv_flow_page_plugs
  SET    plug_template = (
      SELECT default_irr_template
      FROM   apex_240200.wwv_flow_themes
      WHERE  flow_id = 100 AND security_group_id = l_ws_id
  )
  WHERE  flow_id = 100
  AND    plug_source_type = 'NATIVE_IR';
  DBMS_OUTPUT.PUT_LINE('IR region plug_templates fixed: ' || SQL%ROWCOUNT || ' rows');

  -- 4g. Fix login page button template — create_login_page uses an internal default
  --     button template ID, not the UT42 one. Replace with default_button_template
  --     from the theme subscription (same as app 102).
  UPDATE apex_240200.wwv_flow_step_buttons
  SET    button_template_id = (
      SELECT default_button_template
      FROM   apex_240200.wwv_flow_themes
      WHERE  flow_id = 100 AND security_group_id = l_ws_id
  )
  WHERE  flow_id = 100 AND flow_step_id = 9999;
  DBMS_OUTPUT.PUT_LINE('Login button template fixed: ' || SQL%ROWCOUNT || ' rows');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Theme subscription inserted, login page and region templates fixed.');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('Step 4 FAILED: ' || SQLERRM);
  RAISE;
END;
/
exit
SYSDBA2_EOF

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== Sample app ready ==="
echo "  Page 1 — Notes (Interactive Report):"
echo "    http://localhost:$APEX_PORT/ords/f?p=100:1"
echo "  Page 2 — Semantic Vector Search:"
echo "    http://localhost:$APEX_PORT/ords/f?p=100:2"
echo ""
echo "  Login → Workspace: $APEX_USER   User: $APEX_USER   Password: $APEX_PASSWORD"
echo ""
echo "  SSH tunnel (if remote):"
echo "    ssh -L $APEX_PORT:localhost:$APEX_PORT -N ubuntu@<server-ip>"
