-- Small helper shared by UI modules that inline extracted JS/CSS
-- assets into CGI HTML responses while binding the per-request CSP
-- nonce via render.lua's HTML-escaped {{ nonce }} placeholder.

asset = require("asset")
render_lib = require("render")

ui_assets = {}

INLINE_SCRIPT_TEMPLATE = """
<script nonce="{{ nonce }}">
{{{ code }}}</script>
"""

INLINE_STYLE_TEMPLATE = """
<style>
{{{ css }}}</style>
"""

function ui_assets.inline_script(nonce, relpath)
    safe_nonce = nonce
    if safe_nonce == nil then
        safe_nonce = ""
    end
    return render_lib.render(INLINE_SCRIPT_TEMPLATE, {
        nonce = safe_nonce,
        code = asset.read(relpath),
    })
end

function ui_assets.inline_style(relpath)
    return render_lib.render(INLINE_STYLE_TEMPLATE, {
        css = asset.read(relpath),
    })
end

return ui_assets
