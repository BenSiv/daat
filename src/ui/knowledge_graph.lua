-- View-model builder and template renderer for /knowledge-graph (see doc/knowledge-graph-explorer.md).

const asset = require("asset")
const html_lib = require("html")
const json = require("dkjson")
const render_lib = require("render")

const knowledge_graph = {}

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

