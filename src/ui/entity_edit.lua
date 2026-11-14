-- View-model builder and template renderer for /entity-edit (single-row
-- entity edit form).
--
-- Keeps action-button/status-placeholder validation (page.lua) and JSON
-- boot serialization in Luam while keeping the CSS, HTML shell, and
-- form controller in standalone assets (`ui/entity_edit.{css,html,js}`).

asset = require("asset")
html_lib = require("html")
json = require("dkjson")
page_lib = require("page")
render_lib = require("render")

entity_edit = {}

function entity_edit.render_actions()
    sections = {
        {
            type = "actions",
            buttons = {{label = "Save changes", id = "btn-save", css_class = "btn btn-primary"}},
            style = "margin-top: 20px;",
        },
        {type = "status_placeholder", id = "status-message", css_class = "status-msg"},
    }
    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end
    return page_lib.render(sections)
end

function entity_edit.view_model(entity_type, layout_json, row_json, entity_id, header_html, base_css, nonce)
    safe_nonce = nonce
    if safe_nonce == nil then
        safe_nonce = ""
    end
    id_str = tostring(entity_id)
    boot_id = tonumber(entity_id)
    if boot_id == nil then
        boot_id = id_str
    end
    boot_json = html_lib.json_for_script(json.encode({
        entity_type = entity_type,
        entity_id = boot_id,
    }))
    return {
        entity_type = entity_type,
        entity_id = id_str,
        base_css = base_css,
        page_css = asset.read("ui/entity_edit.css"),
        header_html = header_html,
        actions_html = entity_edit.render_actions(),
        layout_json = html_lib.json_for_script(layout_json),
        row_json = html_lib.json_for_script(row_json),
        boot_json = boot_json,
        nonce = safe_nonce,
        page_js = asset.read("ui/entity_edit.js"),
    }
end

function entity_edit.render(entity_type, layout_json, row_json, entity_id, header_html, base_css, nonce)
    vm = entity_edit.view_model(entity_type, layout_json, row_json, entity_id, header_html, base_css, nonce)
    return render_lib.render(asset.read("ui/entity_edit.html"), vm)
end

return entity_edit

