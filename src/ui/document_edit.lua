-- View-model builder and template renderer for /document-edit.
--
-- Computes form field values, prefill handling, error banner HTML, and
-- the JSON boot payload (`initial_value`) in Luam while keeping the
-- page shell, CSS, and ToastUI + inline `[[` / `@` mention controller
-- as raw standalone assets (`ui/document_edit.{html,css,js}`).

asset = require("asset")
html_lib = require("html")
json = require("dkjson")
render_lib = require("render")

document_edit = {}

function document_edit.resolve_initial_fields(doc, prefill)
    heading_text = "New document"
    entity_id_value = ""
    title_value = ""
    content_value_raw = ""
    if doc != nil then
        heading_text = "Edit: " .. doc.title
        entity_id_value = tostring(doc.id)
        title_value = doc.title
        if doc.content != nil then
            content_value_raw = doc.content
        end
    elseif prefill != nil then
        if prefill.title != nil then
            title_value = prefill.title
        end
        if prefill.content != nil then
            content_value_raw = prefill.content
        end
    end
    return {
        heading_text = heading_text,
        entity_id_value = entity_id_value,
        title_value = title_value,
        content_value_raw = content_value_raw,
    }
end

function document_edit.view_model(fields, parent_options_html, csrf_token, error_message, header_html, base_css, nonce)
    safe_nonce = nonce
    if safe_nonce == nil then
        safe_nonce = ""
    end
    safe_csrf = csrf_token
    if safe_csrf == nil then
        safe_csrf = ""
    end
    safe_parent_options = parent_options_html
    if safe_parent_options == nil then
        safe_parent_options = ""
    end
    error_html = ""
    if error_message != nil and error_message != "" then
        error_html = "<div class=\"platform-error-banner\">" .. html_lib.html_escape(error_message) .. "</div>"
    end
    boot_json = html_lib.json_for_script(json.encode({
        initial_value = fields.content_value_raw,
    }))
    return {
        heading_text = fields.heading_text,
        base_css = base_css,
        page_css = asset.read("ui/document_edit.css"),
        header_html = header_html,
        error_html = error_html,
        csrf_token = safe_csrf,
        entity_id_value = fields.entity_id_value,
        title_value = fields.title_value,
        parent_options_html = safe_parent_options,
        nonce = safe_nonce,
        boot_json = boot_json,
        page_js = asset.read("ui/document_edit.js"),
    }
end

function document_edit.render(fields, parent_options_html, csrf_token, error_message, header_html, base_css, nonce)
    vm = document_edit.view_model(fields, parent_options_html, csrf_token, error_message, header_html, base_css, nonce)
    return render_lib.render(asset.read("ui/document_edit.html"), vm)
end

return document_edit
