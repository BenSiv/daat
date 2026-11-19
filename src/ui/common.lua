-- Shared UI layout constants, CSS/JS asset wrappers, page shell,
-- plugin canvas renderer, and generic entity register/edit wrappers.

const asset = require("asset")
const chat_widget = require("ui.chat_widget")
const config_lib = require("config")
const dkjson = require("dkjson")
const entity_edit = require("ui.entity_edit")
const html_lib = require("html")
const register = require("ui.register")
const render_lib = require("render")
const ui_assets = require("ui.assets")

const ui_common = {}

ui_common.escape = html_lib.escape
ui_common.html_escape = html_lib.html_escape
ui_common.json_for_script = html_lib.json_for_script

const PLATFORM_CONTENT_MAX_WIDTH = 2400
const PLATFORM_GUTTER = 20
const PLATFORM_NAV_WIDTH = 72

const PLATFORM_LAYOUT = {
    gutter = PLATFORM_GUTTER,
    gutter_x2 = PLATFORM_GUTTER * 2,
    nav_width = PLATFORM_NAV_WIDTH,
    content_max_width = PLATFORM_CONTENT_MAX_WIDTH,
}

ui_common.PLATFORM_CONTENT_MAX_WIDTH = PLATFORM_CONTENT_MAX_WIDTH
ui_common.PLATFORM_GUTTER = PLATFORM_GUTTER
ui_common.PLATFORM_NAV_WIDTH = PLATFORM_NAV_WIDTH
ui_common.PLATFORM_LAYOUT = PLATFORM_LAYOUT

const ICON_HOME = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 11l9-8 9 8\"/><path d=\"M5 10v10a1 1 0 0 0 1 1h4v-6h4v6h4a1 1 0 0 0 1-1V10\"/></svg>"
const ICON_NOTEBOOK = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4 5a2 2 0 0 1 2-2h5v18H6a2 2 0 0 1-2-2V5z\"/><path d=\"M20 5a2 2 0 0 0-2-2h-5v18h5a2 2 0 0 0 2-2V5z\"/></svg>"
const ICON_DATA = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><ellipse cx=\"12\" cy=\"5\" rx=\"8\" ry=\"3\"/><path d=\"M4 5v6c0 1.7 3.6 3 8 3s8-1.3 8-3V5\"/><path d=\"M4 11v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6\"/></svg>"
const ICON_KNOWLEDGE = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z\"/><path d=\"M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z\"/></svg>"
const ICON_TASKS = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M9 11l3 3L22 4\"/><path d=\"M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11\"/></svg>"
const ICON_SYSTEM = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"3\"/><path d=\"M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z\"/></svg>"
const ICON_CHAT_BUBBLE = "<svg width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z\"/></svg>"

function ui_common.container_css()
    return render_lib.render(asset.read("ui/container.css"), {layout = PLATFORM_LAYOUT})
end

function ui_common.nav_css()
    return render_lib.render(asset.read("ui/nav.css"), {layout = PLATFORM_LAYOUT})
end

function ui_common.table_wrapper_css()
    return asset.read("ui/table_wrapper.css")
end

function ui_common.cell_editor_css()
    return asset.read("ui/cell_editor.css")
end

function ui_common.button_css()
    return asset.read("ui/button.css")
end

function ui_common.sitemap_css()
    return asset.read("ui/sitemap.css")
end

function ui_common.related_css()
    return asset.read("ui/related.css")
end

function ui_common.page_header_css()
    return asset.read("ui/page_header.css")
end

function ui_common.plot_css()
    return asset.read("ui/plot.css")
end

function ui_common.admin_message_css()
    return asset.read("ui/admin_message.css")
end

function ui_common.error_banner_css()
    return asset.read("ui/error_banner.css")
end

function ui_common.canvas_css()
    return asset.read("ui/canvas.css")
end

function ui_common.view_table_css()
    return asset.read("ui/view_table.css")
end

function ui_common.inline_styles(parts)
    return ui_assets.inline_style(table.concat(parts, "\n"))
end

function ui_common.render_sitemap_item(href, title, description)
    return "<li><a href=\"" .. href .. "\"><strong>" .. html_lib.html_escape(title) .. "</strong><p>" ..
        html_lib.html_escape(description) .. "</p></a></li>"
end

function ui_common.render_page_header(title, extra, action)
    if extra == nil then
        extra = ""
    end
    if action == nil then
        action = ""
    end
    return "<div class=\"platform-header\"><div><h2>" .. title .. "</h2>" .. extra .. "</div>" .. action .. "</div>"
end

function ui_common.validate_canvas(elements)
    if type(elements) != "table" then
        return "canvas must be a list of elements"
    end
    for i, element in ipairs(elements) do
        if element.type == "heading" or element.type == "text" then
            if type(element.text) != "string" or element.text == "" then
                return string.format("canvas element #%d (%s): missing 'text'", i, element.type)
            end
        elseif element.type == "table" then
            if type(element.columns) != "table" or #element.columns == 0 then
                return string.format("canvas element #%d (table): must have a non-empty 'columns' list", i)
            end
            if type(element.rows) != "table" then
                return string.format("canvas element #%d (table): must have a 'rows' list", i)
            end
        elseif element.type == "button" then
            if type(element.label) != "string" or element.label == "" then
                return string.format("canvas element #%d (button): missing 'label'", i)
            end
            if type(element.action) != "string" or element.action == "" then
                return string.format("canvas element #%d (button): missing 'action'", i)
            end
        elseif element.type == "input" then
            if type(element.name) != "string" or element.name == "" then
                return string.format("canvas element #%d (input): missing 'name'", i)
            end
        else
            return string.format("canvas element #%d: invalid type '%s'", i, tostring(element.type))
        end
    end
    return nil
end

function render_canvas_table(element)
    header_cells = ""
    for _, col in ipairs(element.columns) do
        header_cells = header_cells .. "<th>" .. html_lib.html_escape(tostring(col)) .. "</th>"
    end
    body_rows = ""
    for _, row in ipairs(element.rows) do
        cells = ""
        for _, value in ipairs(row) do
            cells = cells .. "<td>" .. html_lib.html_escape(tostring(value)) .. "</td>"
        end
        body_rows = body_rows .. "<tr>" .. cells .. "</tr>"
    end
    return "<div class=\"platform-canvas-element platform-table-wrapper\"><table class=\"platform-canvas-table\"><thead><tr>" ..
        header_cells .. "</tr></thead><tbody>" .. body_rows .. "</tbody></table></div>"
end

function render_canvas_button(element)
    args = element.args
    if args == nil then
        args = {}
    end
    return string.format(
        "<div class=\"platform-canvas-element\"><button type=\"button\" class=\"btn btn-primary platform-canvas-action\" data-action=\"%s\" data-args=\"%s\">%s</button></div>",
        html_lib.html_escape(element.action), html_lib.html_escape(dkjson.encode(args)), html_lib.html_escape(element.label)
    )
end

function render_canvas_input(element)
    label_html = ""
    if element.label != nil and element.label != "" then
        label_html = "<label class=\"platform-canvas-input-label\">" .. html_lib.html_escape(element.label) .. "</label>"
    end
    placeholder = ""
    if element.placeholder != nil then
        placeholder = element.placeholder
    end
    return string.format(
        "<div class=\"platform-canvas-element platform-canvas-input-wrapper\">%s<input type=\"text\" class=\"platform-canvas-input\" data-input-name=\"%s\" placeholder=\"%s\"></div>",
        label_html, html_lib.html_escape(element.name), html_lib.html_escape(placeholder)
    )
end

function ui_common.render_canvas(elements)
    parts = {}
    for _, element in ipairs(elements) do
        if element.type == "heading" then
            table.insert(parts, "<h3 class=\"platform-canvas-element platform-canvas-heading\">" .. html_lib.html_escape(element.text) .. "</h3>")
        elseif element.type == "text" then
            table.insert(parts, "<p class=\"platform-canvas-element platform-canvas-text\">" .. html_lib.html_escape(element.text) .. "</p>")
        elseif element.type == "table" then
            table.insert(parts, render_canvas_table(element))
        elseif element.type == "button" then
            table.insert(parts, render_canvas_button(element))
        elseif element.type == "input" then
            table.insert(parts, render_canvas_input(element))
        end
    end
    return table.concat(parts)
end

function ui_common.canvas_js(nonce)
    return ui_assets.inline_script(nonce, asset.read("ui/canvas.js"))
end

function ui_common.render_plugin_page(label, elements, nonce)
    escaped_label = html_lib.html_escape(label)
    page_header = ui_common.render_page_header(escaped_label, nil, nil)
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.canvas_css(),
    })
    return string.format("""
<div class="fossil-doc" data-title="%s">
    %s
    <div class="platform-container">
        %s
        <div class="platform-canvas-container">%s</div>
    </div>
</div>
%s
""", escaped_label, style_block, page_header, ui_common.render_canvas(elements), ui_common.canvas_js(nonce))
end

function ui_common.popover_css()
    return ui_assets.inline_style(asset.read("ui/popover.css"))
end

function ui_common.popover_js(nonce)
    return ui_assets.inline_script(nonce, asset.read("ui/popover.js"))
end

function ui_common.common_js(nonce)
    return ui_assets.inline_script(nonce, asset.read("ui/common.js"))
end

function ui_common.theme_root_css(theme)
    root_vars = {}
    for _, key in ipairs(config_lib.THEME_COLOR_KEYS) do
        value = theme.colors[key]
        if value != nil then
            css_name = string.gsub(key, "_", "-")
            table.insert(root_vars, "--platform-" .. css_name .. ": " .. value .. ";")
        end
    end
    if #root_vars == 0 then
        return ""
    end
    return ":root { " .. table.concat(root_vars, " ") .. " }"
end

function ui_common.apply_nav_hidden(nav_items, hidden_keys)
    if hidden_keys == nil or #hidden_keys == 0 then
        return nav_items
    end
    hidden_set = {}
    for _, key in ipairs(hidden_keys) do
        hidden_set[key] = true
    end
    result = {}
    for _, item in ipairs(nav_items) do
        if hidden_set[item.key] == nil then
            table.insert(result, item)
        end
    end
    return result
end

function ui_common.apply_nav_order(nav_items, order_keys)
    if order_keys == nil or #order_keys == 0 then
        return nav_items
    end
    by_key = {}
    for _, item in ipairs(nav_items) do
        by_key[item.key] = item
    end
    result = {}
    placed = {}
    for _, key in ipairs(order_keys) do
        item = by_key[key]
        if item != nil and placed[key] == nil then
            table.insert(result, item)
            placed[key] = true
        end
    end
    for _, item in ipairs(nav_items) do
        if placed[item.key] == nil then
            table.insert(result, item)
        end
    end
    return result
end

function ui_common.chat_widget_css()
    return chat_widget.css(PLATFORM_LAYOUT)
end

function ui_common.render_chat_widget(nonce, attachments_enabled)
    return chat_widget.render(nonce, attachments_enabled, ICON_CHAT_BUBBLE)
end

function ui_common.page_shell(title, active, body, nonce, show_sql, show_admin, has_tasks_view, nav_extensions, theme, author, page_context)
    if theme == nil then
        theme = {site_name = "Platform", colors = {}}
    end
    if page_context == nil then
        page_context = {page_type = active, title = title}
    end
    if author != nil then
        page_context.current_user = author
    end
    page_context_json = html_lib.json_for_script(dkjson.encode(page_context))

    root_css = ui_common.theme_root_css(theme)

    nav_items = {}
    if author != nil then
        nav_items = {
            {key = "home", href = "/", label = "Home", icon = ICON_HOME},
            {key = "documents", href = "documents", label = "Documents", icon = ICON_NOTEBOOK},
            {key = "data", href = "data", label = "Data", icon = ICON_DATA},
            {key = "knowledge", href = "knowledge", label = "Knowledge Pool", icon = ICON_KNOWLEDGE},
        }
        if has_tasks_view == true then
            table.insert(nav_items, {key = "tasks", href = "view?view_name=prioritized_tasks", label = "Tasks", icon = ICON_TASKS})
        end
        if show_sql or show_admin then
            table.insert(nav_items, {key = "system", href = "system", label = "System", icon = ICON_SYSTEM})
        end
        if nav_extensions != nil then
            for _, entry in ipairs(nav_extensions) do
                ext_ui = entry.manifest.capabilities.ui
                table.insert(nav_items, {
                    key = "ext:" .. entry.name, href = "ext/" .. entry.name,
                    label = ext_ui.label, icon = html_lib.html_escape(ext_ui.icon),
                })
            end
        end
        nav_config = config_lib.platform_config()
        nav_items = ui_common.apply_nav_hidden(nav_items, nav_config.nav_hidden)
        nav_items = ui_common.apply_nav_order(nav_items, nav_config.nav_order)
    end

    brand_html = ""
    if theme.has_logo == true then
        brand_html = string.format(
            "<a class=\"platform-nav-brand\" href=\"/\" title=\"%s\"><img src=\"theme-asset?name=logo.png\" alt=\"%s\"></a>",
            html_lib.html_escape(theme.site_name), html_lib.html_escape(theme.site_name)
        )
    end

    nav_links = {}
    for _, item in ipairs(nav_items) do
        link_class = "platform-nav-link"
        if item.key == active then
            link_class = link_class .. " platform-nav-link-active"
        end
        table.insert(nav_links, string.format(
            "<a class=\"%s\" href=\"%s\" title=\"%s\">%s<span class=\"platform-nav-label\">%s</span></a>",
            link_class, item.href, html_lib.html_escape(item.label), item.icon, html_lib.html_escape(item.label)
        ))
    end

    user_box = ""
    if author != nil then
        user_box = string.format("""
<div class="platform-nav-user">
    <a class="platform-nav-user-name" href="account">%s</a>
</div>
""", html_lib.html_escape(author))
    end

    chat_widget_html = ""
    if author != nil then
        chat_widget_html = ui_common.render_chat_widget(nonce, config_lib.platform_config().chat_attachments_enabled == true)
    end

    safe_nonce = nonce
    if safe_nonce == nil then
        safe_nonce = ""
    end
    safe_title = title
    if safe_title == nil then
        safe_title = ""
    end
    return render_lib.render(asset.read("ui/page_shell.html"), {
        title = safe_title,
        nonce = safe_nonce,
        page_context_json = page_context_json,
        common_js_html = ui_common.common_js(nonce),
        root_css = root_css,
        nav_css = ui_common.nav_css(),
        chat_widget_css = ui_common.chat_widget_css(),
        brand_html = brand_html,
        nav_links_html = table.concat(nav_links, ""),
        user_box = user_box,
        body = body,
        chat_widget_html = chat_widget_html,
    })
end

function ui_common.render(entity_type, layout_json, nonce, locked_fields)
    escaped_type = html_lib.html_escape(entity_type)
    register_header = ui_common.render_page_header("Register " .. escaped_type,
        "<p>Fill out the sheet. Fields marked with <span class=\"req-dot\">*</span> are required.</p>",
        "<a class=\"btn btn-secondary\" href=\"browse?type=" .. escaped_type .. "\">Browse " .. escaped_type .. "</a>")
    base_css = ui_common.container_css() .. "\n" .. ui_common.page_header_css() .. "\n" ..
        ui_common.table_wrapper_css() .. "\n" .. ui_common.button_css() .. "\n" .. ui_common.cell_editor_css()
    return register.render(entity_type, layout_json, locked_fields, register_header, base_css, nonce)
end

function ui_common.render_entity_edit(entity_type, layout_json, row_json, entity_id, nonce)
    escaped_type = html_lib.html_escape(entity_type)
    escaped_entity_id = tostring(entity_id)
    edit_header = ui_common.render_page_header("Edit " .. escaped_type .. " #" .. escaped_entity_id,
        "<a class=\"btn btn-secondary\" href=\"detail?type=" .. escaped_type .. "&entity_id=" .. escaped_entity_id .. "\">&larr; Back to detail</a>", nil)
    base_css = ui_common.container_css() .. "\n" .. ui_common.button_css() .. "\n" ..
        ui_common.page_header_css() .. "\n" .. ui_common.cell_editor_css()
    return entity_edit.render(entity_type, layout_json, row_json, entity_id, edit_header, base_css, nonce)
end

return ui_common
