-- Public UI rendering facade, delegating to focused submodules under src/ui/:
--   ui.common          - layout constants, shared CSS/JS, page shell, plugin canvas, register/edit wrappers
--   ui.data_pages      - entity labels, word diffs, browse, detail, views, SVG ERD, data index, SQL console
--   ui.admin_pages     - login/reset/verify/account cards, home, system, settings, user/API-key/trigger admin
--   ui.knowledge_pages - knowledge pool/graph/tables, entry templates, documents, and chat history browser

const ui_admin = require("ui.admin_pages")
const ui_common = require("ui.common")
const ui_data = require("ui.data_pages")
const ui_knowledge = require("ui.knowledge_pages")

const ui = {}

-- Escaping & shared shell/canvas/widget primitives (ui.common)
ui.escape = ui_common.escape
ui.html_escape = ui_common.html_escape
ui.plot_css = ui_common.plot_css
ui.validate_canvas = ui_common.validate_canvas
ui.render_canvas = ui_common.render_canvas
ui.canvas_js = ui_common.canvas_js
ui.render_plugin_page = ui_common.render_plugin_page
ui.popover_css = ui_common.popover_css
ui.popover_js = ui_common.popover_js
ui.theme_root_css = ui_common.theme_root_css
ui.page_shell = ui_common.page_shell
ui.render = ui_common.render
ui.render_entity_edit = ui_common.render_entity_edit
ui.render_chat_widget = ui_common.render_chat_widget
ui.apply_nav_hidden = ui_common.apply_nav_hidden
ui.apply_nav_order = ui_common.apply_nav_order

-- Structured data pages & helpers (ui.data_pages)
ui.entity_display_label = ui_data.entity_display_label
ui.own_row_label = ui_data.own_row_label
ui.display_field_value = ui_data.display_field_value
ui.render_browse = ui_data.render_browse
ui.render_detail = ui_data.render_detail
ui.render_view_table = ui_data.render_view_table
ui.render_view = ui_data.render_view
ui.expand_inline_views = ui_data.expand_inline_views
ui.render_relation_diagram = ui_data.render_relation_diagram
ui.relation_diagram_css = ui_data.relation_diagram_css
ui.diagram_js = ui_data.diagram_js
ui.render_index = ui_data.render_index
ui.render_sql = ui_data.render_sql
ui.word_diff_runs = ui_data.word_diff_runs
ui.word_diff_html = ui_data.word_diff_html

-- Auth, account, landing & admin pages (ui.admin_pages)
ui.render_login = ui_admin.render_login
ui.render_forgot_password = ui_admin.render_forgot_password
ui.render_reset_password = ui_admin.render_reset_password
ui.render_verify_email = ui_admin.render_verify_email
ui.render_account = ui_admin.render_account
ui.render_admin_users = ui_admin.render_admin_users
ui.render_admin_api_keys = ui_admin.render_admin_api_keys
ui.render_settings = ui_admin.render_settings
ui.render_home = ui_admin.render_home
ui.render_system = ui_admin.render_system
ui.render_system_status = ui_admin.render_system_status
ui.render_admin_triggers = ui_admin.render_admin_triggers

-- Knowledge pool, templates, documents & chat pages (ui.knowledge_pages)
ui.render_knowledge_pool = ui_knowledge.render_knowledge_pool
ui.render_knowledge_graph = ui_knowledge.render_knowledge_graph
ui.render_knowledge_documents = ui_knowledge.render_knowledge_documents
ui.render_knowledge_retrievals = ui_knowledge.render_knowledge_retrievals
ui.render_templates_list = ui_knowledge.render_templates_list
ui.render_template = ui_knowledge.render_template
ui.document_parent_options = ui_knowledge.document_parent_options
ui.render_document_tree = ui_knowledge.render_document_tree
ui.render_document = ui_knowledge.render_document
ui.render_document_edit = ui_knowledge.render_document_edit
ui.CHAT_MARKDOWN_ROLES = ui_knowledge.CHAT_MARKDOWN_ROLES
ui.render_chat = ui_knowledge.render_chat
ui.render_chat_unavailable = ui_knowledge.render_chat_unavailable

return ui
