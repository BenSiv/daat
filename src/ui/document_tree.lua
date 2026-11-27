-- View-model builder and template renderer for /documents.

const asset = require("asset")
const html_lib = require("html")
const json = require("dkjson")
const render_lib = require("render")

const document_tree = {}

function document_tree.build_index(rows)
    by_parent = {}
    for _, row in ipairs(rows) do
        key = "root"
        if row.parent_id != nil and row.parent_id != "" then
            key = tostring(tonumber(row.parent_id))
        end
        if by_parent[key] == nil then
            by_parent[key] = {}
        end
        table.insert(by_parent[key], row)
    end
    return by_parent
end

-- Folder rows toggle children on title click and open their own page via the trailing arrow link.
function document_tree.render_level(by_parent, key, depth)
    children = by_parent[key]
    if children == nil then
        return ""
    end
    items = ""
    for _, row in ipairs(children) do
        child_key = tostring(tonumber(row.id))
        nested = document_tree.render_level(by_parent, child_key, depth + 1)
        link = "<a href=\"document?entity_id=" .. tostring(row.id) .. "\">" .. html_lib.html_escape(row.title) .. "</a>"
        if nested == "" then
            items = items .. "<li class=\"platform-tree-leaf\">" .. link .. "</li>"
        else
            title = html_lib.html_escape(row.title)
            open_link = "<a class=\"platform-tree-open\" href=\"document?entity_id=" .. tostring(row.id) ..
                "\" title=\"Open page\" aria-label=\"Open " .. title .. "\">&#8599;</a>"
            items = items .. "<li><details><summary><span class=\"platform-tree-folder\">" .. title ..
                "</span>" .. open_link .. "</summary><ul>" .. nested .. "</ul></details></li>"
        end
    end
    return items
end

function document_tree.search_index_json(rows)
    index = {}
    for _, row in ipairs(rows) do
        table.insert(index, {id = tonumber(row.id), title = row.title})
    end
    return html_lib.json_for_script(json.encode(index))
end

function document_tree.render_search_results(query, results)
    if query == nil or query == "" then
        return ""
    end
    if results == nil or #results == 0 then
        return "<section class=\"platform-document-content-results\"><p class=\"platform-empty\">No documents match <strong>" ..
            html_lib.html_escape(query) .. "</strong>.</p></section>"
    end
    items = {}
    for _, r in ipairs(results) do
        meta = {}
        if r.created_at != nil and r.created_at != "" then
            table.insert(meta, "created " .. html_lib.html_escape(string.sub(r.created_at, 1, 10)))
        end
        if r.external_id != nil and r.external_id != "" then
            table.insert(meta, html_lib.html_escape(r.external_id))
        end
        if r.same_title_count > 1 then
            table.insert(meta, "one of " .. tostring(r.same_title_count) .. " with this title")
        end
        meta_html = ""
        if #meta > 0 then
            meta_html = "<div class=\"platform-document-result-meta\">" .. table.concat(meta, " &middot; ") .. "</div>"
        end
        table.insert(items, "<li><a href=\"document?entity_id=" .. tostring(r.id) .. "\">" .. html_lib.html_escape(r.title) .. "</a>" ..
            meta_html .. "<div class=\"platform-document-result-excerpt\">" .. html_lib.html_escape(r.excerpt) .. "</div></li>")
    end
    return "<section class=\"platform-document-content-results\"><h3>" .. tostring(#results) .. " documents match <strong>" ..
        html_lib.html_escape(query) .. "</strong></h3><ol>" .. table.concat(items, "") .. "</ol></section>"
end

function document_tree.view_model(rows, header_html, base_css, nonce, query, results)
    safe_nonce = nonce
    if safe_nonce == nil then
        safe_nonce = ""
    end
    query_value = query
    if query_value == nil then
        query_value = ""
    end
    by_parent = document_tree.build_index(rows)
    tree_items = document_tree.render_level(by_parent, "root", 0)
    tree_html = "<ul class=\"platform-document-tree\">" .. tree_items .. "</ul>"
    if tree_items == "" then
        tree_html = "<p class=\"platform-empty\">No documents yet.</p>"
    end
    return {
        base_css = base_css,
        page_css = asset.read("ui/document_tree.css"),
        header_html = header_html,
        query_value = query_value,
        search_results_html = document_tree.render_search_results(query, results),
        tree_html = tree_html,
        search_index_json = document_tree.search_index_json(rows),
        nonce = safe_nonce,
        page_js = asset.read("ui/document_tree.js"),
    }
end

function document_tree.render(rows, header_html, base_css, nonce, query, results)
    vm = document_tree.view_model(rows, header_html, base_css, nonce, query, results)
    return render_lib.render(asset.read("ui/document_tree.html"), vm)
end

return document_tree
