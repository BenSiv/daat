-- Public UI rendering facade, delegating to focused submodules under src/ui/:
--   ui.common          - layout constants, shared CSS/JS, page shell, plugin canvas, register/edit wrappers
--   ui.data_pages      - entity labels, word diffs, browse, detail, views, SVG ERD, data index, SQL console
--   ui.admin_pages     - login/reset/verify/account cards, home, system, settings, user/API-key/trigger admin
--   ui.knowledge_pages - knowledge pool/graph/tables, entry templates, documents, and chat history browser

const ui_admin = require("ui.admin_pages")
const ui_common = require("ui.common")
const ui_data = require("ui.data_pages")
const ui_knowledge = require("ui.knowledge_pages")

const html = {}

-- Escaping & shared shell/canvas/widget primitives (ui.common)
html.escape = ui_common.escape
html.html_escape = ui_common.html_escape
html.plot_css = ui_common.plot_css
html.validate_canvas = ui_common.validate_canvas
html.render_canvas = ui_common.render_canvas
html.canvas_js = ui_common.canvas_js
html.render_plugin_page = ui_common.render_plugin_page
html.popover_css = ui_common.popover_css
html.popover_js = ui_common.popover_js
html.theme_root_css = ui_common.theme_root_css
html.page_shell = ui_common.page_shell
html.render = ui_common.render
html.render_entity_edit = ui_common.render_entity_edit
html.render_chat_widget = ui_common.render_chat_widget
html.apply_nav_hidden = ui_common.apply_nav_hidden
html.apply_nav_order = ui_common.apply_nav_order

-- Structured data pages & helpers (ui.data_pages)
html.entity_display_label = ui_data.entity_display_label
html.own_row_label = ui_data.own_row_label
html.display_field_value = ui_data.display_field_value
html.render_browse = ui_data.render_browse
html.render_detail = ui_data.render_detail
html.render_view_table = ui_data.render_view_table
html.render_view = ui_data.render_view
html.expand_inline_views = ui_data.expand_inline_views
html.render_relation_diagram = ui_data.render_relation_diagram
html.relation_diagram_css = ui_data.relation_diagram_css
html.diagram_js = ui_data.diagram_js
html.render_index = ui_data.render_index
html.render_sql = ui_data.render_sql
html.word_diff_runs = ui_data.word_diff_runs
html.word_diff_html = ui_data.word_diff_html

-- Auth, account, landing & admin pages (ui.admin_pages)
html.render_login = ui_admin.render_login
html.render_forgot_password = ui_admin.render_forgot_password
html.render_reset_password = ui_admin.render_reset_password
html.render_verify_email = ui_admin.render_verify_email
html.render_account = ui_admin.render_account
html.render_admin_users = ui_admin.render_admin_users
html.render_admin_api_keys = ui_admin.render_admin_api_keys
html.render_settings = ui_admin.render_settings
html.render_home = ui_admin.render_home
html.render_system = ui_admin.render_system
html.render_admin_triggers = ui_admin.render_admin_triggers

-- Knowledge pool, templates, documents & chat pages (ui.knowledge_pages)
html.render_knowledge_pool = ui_knowledge.render_knowledge_pool
html.render_knowledge_graph = ui_knowledge.render_knowledge_graph
html.render_knowledge_documents = ui_knowledge.render_knowledge_documents
html.render_knowledge_retrievals = ui_knowledge.render_knowledge_retrievals
html.render_templates_list = ui_knowledge.render_templates_list
html.render_template = ui_knowledge.render_template
html.document_parent_options = ui_knowledge.document_parent_options
html.render_document_tree = ui_knowledge.render_document_tree
html.render_document = ui_knowledge.render_document
html.render_document_edit = ui_knowledge.render_document_edit
html.CHAT_MARKDOWN_ROLES = ui_knowledge.CHAT_MARKDOWN_ROLES
html.render_chat = ui_knowledge.render_chat
html.render_chat_unavailable = ui_knowledge.render_chat_unavailable

return html
