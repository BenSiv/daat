-- View-model builder and asset renderer for the floating chat widget
-- embedded in html.page_shell.
--
-- Keeps server-side state decisions in Luam (whether PDF/DOCX
-- attachments are enabled, layout constants, CSP nonce) and keeps the
-- CSS, HTML skeleton, and ~600-line client-side controller in raw
-- standalone assets (`ui/chat_widget.{css,html,js}`).

asset = require("asset")
render_lib = require("render")

chat_widget = {}

ATTACH_CONTROLS_HTML = """<button type="button" class="platform-chat-widget-attach-btn" id="platform-chat-widget-attach-btn" title="Attach a PDF or Word document for context">&#128206;</button><input type="file" id="platform-chat-widget-file" accept=".pdf,.docx" style="display:none;">"""

function chat_widget.css(layout)
    return render_lib.render(asset.read("ui/chat_widget.css"), {layout = layout})
end

function chat_widget.view_model(nonce, attachments_enabled, icon_svg)
    safe_nonce = nonce
    if safe_nonce == nil then
        safe_nonce = ""
    end
    attach_html = ""
    if attachments_enabled == true then
        attach_html = ATTACH_CONTROLS_HTML
    end
    return {
        attach_html = attach_html,
        icon_svg = icon_svg,
        nonce = safe_nonce,
        widget_js = asset.read("ui/chat_widget.js"),
    }
end

function chat_widget.render(nonce, attachments_enabled, icon_svg)
    vm = chat_widget.view_model(nonce, attachments_enabled, icon_svg)
    return render_lib.render(asset.read("ui/chat_widget.html"), vm)
end

return chat_widget
