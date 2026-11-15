-- Small helper shared by UI modules that inline extracted JS/CSS
-- assets into CGI HTML responses while binding the per-request CSP
-- nonce via render.lua's HTML-escaped {{ nonce }} placeholder.
--
-- Callers pass `asset.read("ui/...")` directly as `code` / `css` (a
-- literal `asset.read("...")` at the call site, just like `require`, so
-- `luam/lib/static/build.lua` discovers every bundled asset statically
-- at compile time).

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

function ui_assets.inline_script(nonce, code)
    safe_nonce = nonce
    if safe_nonce == nil then
        safe_nonce = ""
    end
    return render_lib.render(INLINE_SCRIPT_TEMPLATE, {
        nonce = safe_nonce,
        code = code,
    })
end

function ui_assets.inline_style(css)
    return render_lib.render(INLINE_STYLE_TEMPLATE, {
        css = css,
    })
end

return ui_assets
