-- View-model builder and template renderer for /register (batch entity
-- registration grid).
--
-- Keeps action-button/status-placeholder validation (page.lua) and JSON
-- boot serialization in Luam while keeping the CSS, HTML shell, and
-- grid controller in standalone assets (`ui/register.{css,html,js}`).

asset = require("asset")
html_lib = require("html")
json = require("dkjson")
page_lib = require("page")
render_lib = require("render")

register = {}

function register.render_actions()
    sections = {
        {
            type = "actions",
            buttons = {
                {label = "+ Add Row", id = "btn-add-row", css_class = "btn btn-secondary"},
                {label = "Submit Batch", id = "btn-submit-batch", css_class = "btn btn-primary"},
            },
        },
        {type = "status_placeholder", id = "status-message", css_class = "status-msg"},
    }
    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end
    return page_lib.render(sections)
end

function register.view_model(entity_type, layout_json, locked_fields, header_html, base_css, nonce)
    safe_nonce = nonce
    if safe_nonce == nil then
        safe_nonce = ""
    end
    safe_locked = locked_fields
    if safe_locked == nil then
        safe_locked = {}
    end
    boot_json = html_lib.json_for_script(json.encode({
        entity_type = entity_type,
        locked_fields = safe_locked,
    }))
    return {
        entity_type = entity_type,
        base_css = base_css,
        page_css = asset.read("ui/register.css"),
        header_html = header_html,
        actions_html = register.render_actions(),
        layout_json = html_lib.json_for_script(layout_json),
        boot_json = boot_json,
        nonce = safe_nonce,
        page_js = asset.read("ui/register.js"),
    }
end

function register.render(entity_type, layout_json, locked_fields, header_html, base_css, nonce)
    vm = register.view_model(entity_type, layout_json, locked_fields, header_html, base_css, nonce)
    return render_lib.render(asset.read("ui/register.html"), vm)
end

return register

