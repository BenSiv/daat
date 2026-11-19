-- Knowledge pool, graph, entry templates, documents, and chat history UI pages:
-- /knowledge, /knowledge-graph, /knowledge-documents, /knowledge-retrievals,
-- /templates, /template, /documents, /document, /document-edit, /chat.

const asset = require("asset")
const document_edit = require("ui.document_edit")
const document_tree = require("ui.document_tree")
const knowledge_graph = require("ui.knowledge_graph")
const ui_common = require("ui.common")
const ui_data = require("ui.data_pages")

const html_escape = ui_common.html_escape

const ui_knowledge = {}

const KNOWLEDGE_TIER_LABELS = {
    [0] = "Tier 0: Raw Intake",
    [1] = "Tier 1: Curated Draft",
    [2] = "Tier 2: Developed Reference",
    [3] = "Tier 3: Atomic Record",
}

const KNOWLEDGE_TIER_CAPTIONS = {
    [0] = "Captured, not yet worked on.",
    [1] = "Lightly edited -- summarized or cleaned up.",
    [2] = "Fully developed -- multi-section, covers a nuanced subject.",
    [3] = "Short, single-subject, distilled to one idea.",
}

const KNOWLEDGE_TIER_COLORS = {
    [0] = "#b0abf0",
    [1] = "#8880ec",
    [2] = "#5c52e0",
    [3] = "#332ba8",
}

ui_knowledge.KNOWLEDGE_TIER_LABELS = KNOWLEDGE_TIER_LABELS
ui_knowledge.KNOWLEDGE_TIER_CAPTIONS = KNOWLEDGE_TIER_CAPTIONS
ui_knowledge.KNOWLEDGE_TIER_COLORS = KNOWLEDGE_TIER_COLORS

function ui_knowledge.render_knowledge_pool(stats)
    tier_tiles = ""
    for tier = 0, 3 do
        tier_tiles = tier_tiles .. string.format(
            "<a class=\"platform-knowledge-tier\" href=\"knowledge-documents?tier=%d\" style=\"border-left: 4px solid var(--platform-tier-%d, %s);\"><strong>%s</strong><span class=\"dimmed\">%d note(s)</span>" ..
            "<p class=\"platform-knowledge-tier-caption\">%s</p></a>",
            tier, tier, KNOWLEDGE_TIER_COLORS[tier], html_escape(KNOWLEDGE_TIER_LABELS[tier]), stats.tier_counts[tier],
            html_escape(KNOWLEDGE_TIER_CAPTIONS[tier])
        )
    end

    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.page_header_css(),
        asset.read("ui/knowledge_pool.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Knowledge Pool">
    %s
    <div class="platform-container">
        %s
        <div class="platform-knowledge-stats">
            <a href="knowledge-documents"><strong>%d</strong><span class="dimmed">pool records</span></a>
            <a href="knowledge-retrievals"><strong>%d</strong><span class="dimmed">retrieval runs</span></a>
            <a href="knowledge-reviewed"><strong>%d</strong><span class="dimmed">reviewed notes</span></a>
            <a href="chat"><strong>%d</strong><span class="dimmed">chat sessions</span></a>
        </div>
        <div class="platform-knowledge-panel">
            <h4>Processing Tiers</h4>
            <div class="platform-knowledge-tiers">
%s
            </div>
        </div>
        <p style="margin-top: 14px;"><a class="btn btn-secondary" href="knowledge-graph">Explore the knowledge graph &rarr;</a></p>
    </div>
</div>
""", style_block,
     ui_common.render_page_header("Knowledge Pool", "<p>Notes promote through processing tiers as they're retrieved and reinforced; every retrieval is logged.</p>", nil),
     stats.note_count, stats.retrieval_count, stats.reviewed_note_count,
     stats.session_count, tier_tiles)
end

function ui_knowledge.render_knowledge_graph(nonce)
    kg_header = ui_common.render_page_header("Knowledge Graph",
        "<p>Documents sized by heat, connections weighted by link strength -- see <a href=\"knowledge\">Knowledge Pool</a> for the tier/heat breakdown this visualizes.</p>",
        "<a class=\"btn btn-secondary\" href=\"knowledge\">&larr; Back to Knowledge Pool</a>")
    base_css = ui_common.container_css() .. "\n" .. ui_common.button_css() .. "\n" .. ui_common.page_header_css()
    return knowledge_graph.render(KNOWLEDGE_TIER_LABELS, KNOWLEDGE_TIER_COLORS, kg_header, base_css, nonce)
end

function ui_knowledge.render_knowledge_documents(rows, tier, title_override)
    title = "Pool records"
    if tier != nil then
        title = KNOWLEDGE_TIER_LABELS[tier]
        if title == nil then
            title = "Pool records"
        end
    end
    if title_override != nil then
        title = title_override
    end

    body_rows = ""
    for _, row in ipairs(rows) do
        tier_label = KNOWLEDGE_TIER_LABELS[tonumber(row.tier)]
        if tier_label == nil then
            tier_label = tostring(row.tier)
        end
        body_rows = body_rows .. string.format(
            "<tr><td><a href=\"document?entity_id=%s\">%s</a></td><td>%s</td><td>%s</td>" ..
            "<td>%s</td><td>%s</td></tr>",
            tostring(row.id), html_escape(row.title), html_escape(tier_label),
            tostring(row.retrieval_count), string.format("%.2f", row.effective_heat), ui_data.display_value(row.source_type)
        )
    end

    table_or_empty = "<p class=\"platform-empty\">No documents.</p>"
    if #rows > 0 then
        table_or_empty = "<div class=\"platform-table-wrapper\"><table class=\"platform-view-table\"><thead><tr>" ..
            "<th>Title</th><th>Tier</th><th>Retrievals</th><th>Effective heat</th><th>Source</th>" ..
            "</tr></thead><tbody>" .. body_rows .. "</tbody></table></div>"
    end

    escaped_title = html_escape(title)
    kd_header = ui_common.render_page_header(escaped_title, "<p>" .. tostring(#rows) .. " document(s)</p>",
        "<a class=\"btn btn-secondary\" href=\"knowledge\">&larr; Back to Knowledge Pool</a>")
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.table_wrapper_css(),
        ui_common.page_header_css(),
        ui_common.view_table_css(),
    })
    return string.format("""
<div class="fossil-doc" data-title="%s">
    %s
    <div class="platform-container">
        %s
        %s
    </div>
</div>
""", escaped_title, style_block, kd_header, table_or_empty)
end

function ui_knowledge.render_knowledge_retrievals(rows)
    body_rows = ""
    for _, r in ipairs(rows) do
        body_rows = body_rows .. string.format(
            "<tr><td>#%s</td><td>%s</td><td>%s</td><td>%s</td></tr>",
            tostring(r.id), html_escape(r.query_text), html_escape(r.created_at), tostring(r.hit_count)
        )
    end

    table_or_empty = "<p class=\"platform-empty\">No retrievals yet.</p>"
    if #rows > 0 then
        table_or_empty = "<div class=\"platform-table-wrapper\"><table class=\"platform-view-table\"><thead><tr>" ..
            "<th>ID</th><th>Query</th><th>When</th><th>Hits</th>" ..
            "</tr></thead><tbody>" .. body_rows .. "</tbody></table></div>"
    end

    header = ui_common.render_page_header("Retrieval runs", "<p>" .. tostring(#rows) .. " run(s)</p>",
        "<a class=\"btn btn-secondary\" href=\"knowledge\">&larr; Back to Knowledge Pool</a>")
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.table_wrapper_css(),
        ui_common.page_header_css(),
        ui_common.view_table_css(),
    })
    return string.format("""
<div class="fossil-doc" data-title="Retrieval runs">
    %s
    <div class="platform-container">
        %s
        %s
    </div>
</div>
""", style_block, header, table_or_empty)
end

function ui_knowledge.render_templates_list(entries)
    items = ""
    for _, entry in ipairs(entries) do
        escaped_name = html_escape(entry.name)
        if entry.def == nil then
            items = items .. "<li class=\"platform-template-error\">" .. escaped_name ..
                " -- ERROR: " .. html_escape(entry.err) .. "</li>"
        else
            label = entry.def.label
            if label == nil then
                label = entry.name
            end
            description = entry.def.description
            if description == nil then
                description = ""
            end
            escaped_label = html_escape(label)
            escaped_desc = html_escape(description)
            items = items .. "<li><a href=\"template?template_name=" .. escaped_name .. "\">" ..
                escaped_label .. "</a><p>" .. escaped_desc .. "</p>" ..
                "<p><a class=\"btn btn-primary\" href=\"document-edit?from_template=" .. escaped_name .. "\">+ New document</a></p></li>"
        end
    end

    list_or_empty = "<ul class=\"platform-index-list\">" .. items .. "</ul>"
    if #entries == 0 then
        list_or_empty = "<p class=\"platform-empty\">No entry templates yet.</p>"
    end

    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.table_wrapper_css(),
        ui_common.page_header_css(),
        asset.read("ui/templates.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Entry templates">
    %s
    <div class="platform-container">
        %s
        %s
    </div>
</div>
""", style_block, ui_common.render_page_header("Entry templates", "<p>Pick a template to see its rendered Markdown.</p>", nil), list_or_empty)
end

function ui_knowledge.render_template(def, rendered_markdown, nonce)
    if nonce == nil then
        nonce = ""
    end
    label = def.label
    if label == nil then
        label = def.name
    end
    description = def.description
    if description == nil then
        description = ""
    end
    escaped_label = html_escape(label)
    escaped_desc = html_escape(description)
    escaped_body = html_escape(rendered_markdown)
    escaped_name = html_escape(def.name)

    template_header = ui_common.render_page_header(escaped_label,
        "<p>" .. escaped_desc .. "</p><p><a class=\"btn btn-secondary\" href=\"templates\">&larr; All templates</a></p>",
        "<a class=\"btn btn-primary\" href=\"document-edit?from_template=" .. escaped_name .. "\">+ New document from template</a>")
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.page_header_css(),
        asset.read("ui/templates.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Template: %s">
    %s
    <div class="platform-container">
        %s
        <p>Or select-all and copy the rendered snippet below.</p>
        <textarea class="platform-snippet" id="platform-template-content" readonly>%s</textarea>
    </div>
</div>
""", escaped_label, style_block, template_header, escaped_body)
end

function ui_knowledge.document_parent_options(rows, selected_id, exclude_id)
    title_counts = {}
    by_id = {}
    for _, row in ipairs(rows) do
        current_count = title_counts[row.title]
        if current_count == nil then
            current_count = 0
        end
        title_counts[row.title] = current_count + 1
        by_id[tostring(tonumber(row.id))] = row
    end

    options = ""
    for _, row in ipairs(rows) do
        if exclude_id == nil or tonumber(row.id) != tonumber(exclude_id) then
            selected_attr = ""
            if selected_id != nil and tonumber(row.id) == tonumber(selected_id) then
                selected_attr = " selected"
            end
            label = html_escape(row.title)
            if title_counts[row.title] > 1 then
                bits = {}
                if row.parent_id != nil then
                    parent_row = by_id[tostring(tonumber(row.parent_id))]
                    if parent_row != nil then
                        table.insert(bits, "under " .. parent_row.title)
                    end
                end
                if row.created_at != nil and row.created_at != "" then
                    table.insert(bits, string.sub(row.created_at, 1, 10))
                end
                if row.external_id != nil and row.external_id != "" then
                    table.insert(bits, row.external_id)
                end
                if #bits > 0 then
                    label = label .. " (" .. html_escape(table.concat(bits, ", ")) .. ")"
                end
            end
            options = options .. "<option value=\"" .. tostring(row.id) .. "\"" .. selected_attr .. ">" ..
                label .. "</option>"
        end
    end
    return options
end

function ui_knowledge.render_document_tree(rows, can_create, nonce, query, results)
    new_page_link = ""
    if can_create == true then
        new_page_link = "<a class=\"btn btn-primary\" href=\"document-edit\">+ New document</a> " ..
            "<a class=\"btn btn-secondary\" href=\"templates\">From template&hellip;</a>"
    end
    doc_tree_header = ui_common.render_page_header("Documents", nil, new_page_link)
    base_css = ui_common.container_css() .. "\n" .. ui_common.button_css() .. "\n" .. ui_common.page_header_css()
    return document_tree.render(rows, doc_tree_header, base_css, nonce, query, results)
end

function render_document_connection(link, doc_id, can_edit)
    arrow = "&larr;"
    arrow_title = "links here"
    if link.direction == "out" then
        arrow = "&rarr;"
        arrow_title = "this document links to it"
    end
    context_html = "<span class=\"platform-connection-context platform-connection-context-empty\">Nothing in the text says why yet.</span>"
    if link.context != nil and link.context != "" then
        context_html = "<span class=\"platform-connection-context\">" .. html_escape(link.context) .. "</span>"
    end
    explain_html = ""
    if can_edit == true then
        explain_html = " <a class=\"platform-connection-explain\" href=\"document-edit?connect_a=" .. tostring(doc_id) ..
            "&amp;connect_b=" .. tostring(link.id) .. "\">Explain connection</a>"
    end
    return "<li><span class=\"platform-connection-arrow\" title=\"" .. arrow_title .. "\">" .. arrow .. "</span> " ..
        "<a href=\"document?entity_id=" .. tostring(link.id) .. "\">" .. html_escape(link.title) .. "</a>" ..
        "<div class=\"platform-connection-detail\">" .. context_html .. explain_html .. "</div></li>"
end

function ui_knowledge.render_document(db_path, doc, rendered_html, breadcrumbs, children, links, can_edit, related)
    breadcrumb_html = ""
    for i, crumb in ipairs(breadcrumbs) do
        if i > 1 then
            breadcrumb_html = breadcrumb_html .. " / "
        end
        if i == #breadcrumbs then
            breadcrumb_html = breadcrumb_html .. html_escape(crumb.title)
        else
            breadcrumb_html = breadcrumb_html .. "<a href=\"document?entity_id=" .. tostring(crumb.id) .. "\">" ..
                html_escape(crumb.title) .. "</a>"
        end
    end

    children_html = ""
    for _, child in ipairs(children) do
        children_html = children_html .. "<li><a href=\"document?entity_id=" .. tostring(child.id) .. "\">" ..
            html_escape(child.title) .. "</a></li>"
    end
    children_block = ""
    if children_html != "" then
        children_block = "<div class=\"platform-document-children\"><h4>Sub-documents</h4><ul>" .. children_html .. "</ul></div>"
    end

    connections_html = ""
    for _, link in ipairs(links) do
        connections_html = connections_html .. render_document_connection(link, doc.id, can_edit)
    end
    connections_block = ""
    if connections_html != "" then
        connections_block = "<div class=\"platform-document-connections\"><h4>Connections</h4><ul>" .. connections_html .. "</ul></div>"
    end

    edit_link = ""
    if can_edit == true then
        edit_link = "<a class=\"btn btn-secondary\" href=\"document-edit?entity_id=" .. tostring(doc.id) .. "\">Edit</a>"
    end
    history_link = "<a class=\"btn btn-secondary\" href=\"detail?type=document&entity_id=" .. tostring(doc.id) .. "\">History</a>"

    related_block = ""
    related_html = ui_data.related_records_html(db_path, related, doc.id)
    if related_html != "" then
        related_block = "<div class=\"platform-document-related\">" .. related_html .. "</div>"
    end

    escaped_doc_title = html_escape(doc.title)
    doc_header = ui_common.render_page_header(escaped_doc_title, nil, "<div class=\"platform-header-actions\">" .. history_link .. edit_link .. "</div>")
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.page_header_css(),
        ui_common.related_css(),
        ui_common.plot_css(),
        asset.read("ui/document_view.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="%s">
    %s
    <div class="platform-container">
        <div class="platform-document-breadcrumbs">%s <a href="documents">(all documents)</a></div>
        %s
        <div class="platform-document-content">
%s
        </div>
        %s
        %s
        %s
    </div>
</div>
""", escaped_doc_title, style_block, breadcrumb_html, doc_header, rendered_html, children_block, connections_block, related_block)
end

function ui_knowledge.render_document_edit(doc, parent_options_html, csrf_token, error_message, nonce, prefill)
    fields = document_edit.resolve_initial_fields(doc, prefill)
    doc_edit_header = ui_common.render_page_header(html_escape(fields.heading_text), nil, nil)
    base_css = ui_common.container_css() .. "\n" .. ui_common.button_css() .. "\n" ..
        ui_common.page_header_css() .. "\n" .. ui_common.error_banner_css()
    return document_edit.render(fields, parent_options_html, csrf_token, error_message, doc_edit_header, base_css, nonce)
end

ui_knowledge.CHAT_MARKDOWN_ROLES = {assistant = true, self_check = true, compaction_summary = true, progress = true}

function render_chat_sessions_list(sessions, current_session_id)
    items = ""
    for _, s in ipairs(sessions) do
        css_class = "platform-chat-session-row"
        if current_session_id != nil and s.id == current_session_id then
            css_class = css_class .. " platform-chat-session-active"
        end
        label = s.title
        if label == nil or label == "" then
            label = "Untitled chat"
        end
        started_at = ""
        if s.created_at != nil then
            started_at = "<span class=\"platform-chat-session-started\">" .. html_escape(s.created_at) .. "</span>"
        end
        items = items .. "<li><a class=\"" .. css_class .. "\" href=\"chat?session_id=" .. s.id .. "\">" ..
            "<span class=\"platform-chat-session-title\">" .. html_escape(label) .. "</span>" ..
            started_at .. "</a></li>"
    end
    if items == "" then
        return "<p class=\"platform-empty\">No chats yet.</p>"
    end
    return "<ul class=\"platform-chat-sessions\">" .. items .. "</ul>"
end

function ui_knowledge.render_chat(sessions, current_session_id, nonce, viewed_foreign_session)
    foreign_banner = ""
    if viewed_foreign_session != nil then
        foreign_title = viewed_foreign_session.title
        if foreign_title == nil or foreign_title == "" then
            foreign_title = "Untitled chat"
        end
        foreign_owner = viewed_foreign_session.login
        if foreign_owner == nil or foreign_owner == "" then
            foreign_owner = "another user"
        end
        foreign_started = ""
        if viewed_foreign_session.created_at != nil then
            foreign_started = "<span class=\"platform-chat-session-started\">" .. html_escape(viewed_foreign_session.created_at) .. "</span>"
        end
        foreign_banner = "<div class=\"platform-chat-foreign-banner\">" ..
            "<div class=\"platform-chat-foreign-meta\">Viewing conversation by <strong>" .. html_escape(foreign_owner) .. "</strong> (read-only)</div>" ..
            "<div class=\"platform-chat-session-row platform-chat-session-active\">" ..
            "<span class=\"platform-chat-session-title\">" .. html_escape(foreign_title) .. "</span>" ..
            foreign_started .. "</div></div>"
    end
    sessions_html = render_chat_sessions_list(sessions, current_session_id)

    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.page_header_css(),
        ui_common.table_wrapper_css(),
        asset.read("ui/chat_pages.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Chat">
    %s
    <div class="platform-container">
        %s
        %s
        %s
    </div>
</div>
""", style_block,
     ui_common.render_page_header("Chat", "<p>Pick a conversation to continue it in the chat widget.</p>", nil),
     foreign_banner,
     sessions_html)
end

function ui_knowledge.render_chat_unavailable()
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.page_header_css(),
        ui_common.button_css(),
        asset.read("ui/chat_pages.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Chat">
    %s
    <div class="platform-container">
        %s
        <div class="platform-chat-unavailable">
            <p>Raw chat conversations are private — only the conversation's owner and administrators can open them (or this session does not exist).</p>
            <a class="btn btn-secondary" href="chat">Back to your chats</a>
        </div>
    </div>
</div>
""", style_block, ui_common.render_page_header("Conversation unavailable", nil, nil))
end

return ui_knowledge
