-- View-model builder and template renderer for /knowledge-graph
-- (doc/knowledge-graph-explorer.md).
--
-- Keeps all server-side preparation in Luam (building the tier legend,
-- escaping the JSON boot payload for inline <script>) and keeps the
-- CSS, HTML shell, and 1,000+ line force-simulation JS as standalone
-- raw assets (`ui/knowledge_graph.{css,html,js}`) with zero string
-- interpolation inside JS or CSS.

asset = require("asset")
html_lib = require("html")
json = require("dkjson")
render_lib = require("render")

knowledge_graph = {}

function knowledge_graph.build_tier_legend(tier_labels, tier_colors)
    legend = {}
    for tier = 0, 3 do
        table.insert(legend, {
            tier = tier,
            label = tier_labels[tier],
            color = tier_colors[tier],
        })
    end
    return legend
end

function knowledge_graph.view_model(tier_labels, tier_colors, header_html, base_css, nonce)
    safe_nonce = nonce
    if safe_nonce == nil then
        safe_nonce = ""
    end
    tier_legend = knowledge_graph.build_tier_legend(tier_labels, tier_colors)
    boot_json = html_lib.json_for_script(json.encode({tier_legend = tier_legend}))
    return {
        base_css = base_css,
        page_css = asset.read("ui/knowledge_graph.css"),
        header_html = header_html,
        boot_json = boot_json,
        nonce = safe_nonce,
        page_js = asset.read("ui/knowledge_graph.js"),
    }
end

function knowledge_graph.render(tier_labels, tier_colors, header_html, base_css, nonce)
    vm = knowledge_graph.view_model(tier_labels, tier_colors, header_html, base_css, nonce)
    return render_lib.render(asset.read("ui/knowledge_graph.html"), vm)
end

return knowledge_graph

