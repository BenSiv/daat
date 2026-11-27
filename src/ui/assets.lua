-- Wraps bundled JS/CSS assets in inline <script nonce="...">/<style> tags.
-- Callers must pass literal asset.read("ui/...") results so static builds bundle them.

const render_lib = require("render")

const ui_assets = {}

const INLINE_SCRIPT_TEMPLATE = """
<script nonce="{{ nonce }}">
{{{ code }}}</script>
"""

const INLINE_STYLE_TEMPLATE = """
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
