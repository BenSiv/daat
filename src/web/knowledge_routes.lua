-- Document tree/detail/editor, Knowledge Pool pages & graph data, and
-- reusable document entry templates (/documents, /document*, /knowledge*,
-- /templates, /template).

const config = require("config")
const schema = require("schema")
const entity = require("entity")
const document = require("document")
const knowledge = require("knowledge")
const template = require("template")
const json = require("dkjson")
const ui = require("ui")
const web_ctx = require("web.context")

const knowledge_routes = {}

function knowledge_routes.handle(req)
    path_info = req.path_info
    method = req.method
    db_path = req.db_path
    root = req.root
    params = req.params
    author = req.author
    csrf_val = web_ctx.default_value(req.cookies.csrf, "")

    if path_info == "/knowledge" then
        stats = knowledge.stats(db_path)
        body = ui.render_knowledge_pool(stats)
        return web_ctx.render_page(req, "Knowledge Pool", "knowledge", body)
    end

    if path_info == "/knowledge-documents" then
        tier = tonumber(params.tier)
        rows = knowledge.list_documents(db_path, tier)
        body = ui.render_knowledge_documents(rows, tier)
        return web_ctx.render_page(req, "Knowledge Pool", "knowledge", body)
    end

    if path_info == "/knowledge-reviewed" then
        rows = knowledge.reviewed_documents(db_path)
        body = ui.render_knowledge_documents(rows, nil, "Reviewed notes")
        return web_ctx.render_page(req, "Knowledge Pool", "knowledge", body)
    end

    if path_info == "/knowledge-graph" then
        body = ui.render_knowledge_graph(req.nonce)
        return web_ctx.render_page(req, "Knowledge Pool", "knowledge", body)
    end

    if path_info == "/knowledge-graph-data" then
        nodes = knowledge.graph_nodes(db_path)
        edges = document.graph_edges(db_path)
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({nodes = nodes, edges = edges}))
    end

    if path_info == "/knowledge-retrievals" then
        rows = knowledge.recent_retrievals(db_path, 500)
        body = ui.render_knowledge_retrievals(rows)
        return web_ctx.render_page(req, "Knowledge Pool", "knowledge", body)
    end

    if path_info == "/documents" then
        rows = document.all_active(db_path)
        query = params.q
        search_results = nil
        if query != nil and query != "" then
            search_results = knowledge.search_for_display(db_path, query, 10, nil, author, false)
        end
        body = ui.render_document_tree(rows, true, req.nonce, query, search_results)
        return web_ctx.render_page(req, "Pages", "documents", body)
    end

    if path_info == "/document" then
        entity_id = tonumber(params.entity_id)
        if entity_id == nil then
            return web_ctx.error_html(req, "400 Bad Request", "Missing 'entity_id' parameter")
        end
        doc = entity.get(db_path, "document", entity_id)
        if doc == nil then
            return web_ctx.error_html(req, "404 Not Found", "no such document #" .. tostring(entity_id))
        end
        rendered_html = document.render_html(db_path, doc.content)
        rendered_html = ui.expand_inline_views(db_path, rendered_html)
        breadcrumbs = document.breadcrumbs(db_path, entity_id)
        children = document.children(db_path, entity_id)
        links = document.links(db_path, entity_id)
        related = web_ctx.document_related_records(db_path, entity_id)
        body = ui.render_document(db_path, doc, rendered_html, breadcrumbs, children, links, true, related)
        page_context = {page_type = "document", entity_type = "document", entity_id = doc.id, title = doc.title}
        return web_ctx.render_page(req, doc.title, "documents", body, page_context)
    end

    if path_info == "/document-edit" then
        doc = nil
        entity_id = tonumber(params.entity_id)
        if entity_id != nil then
            doc = entity.get(db_path, "document", entity_id)
            if doc == nil then
                return web_ctx.error_html(req, "404 Not Found", "no such document #" .. tostring(entity_id))
            end
        end

        prefill = nil
        if doc == nil and params.from_template != nil and params.from_template != "" then
            if not schema.valid_resource_name(params.from_template) then
                return web_ctx.error_html(req, "400 Bad Request", "Invalid 'from_template' parameter")
            end
            templates_dir = config.templates_dir(root)
            template_def, template_err = template.load(templates_dir, params.from_template)
            if template_def == nil then
                return web_ctx.error_html(req, "404 Not Found", template_err)
            end
            default_path = template_def.default_path
            if default_path == nil then
                default_path = template_def.label
            end
            prefill = {title = default_path, content = template.render(template_def)}
        end
        if doc == nil and tonumber(params.connect_a) != nil and tonumber(params.connect_b) != nil then
            prefill = document.connection_draft(db_path, tonumber(params.connect_a), tonumber(params.connect_b), nil)
        end

        parent_id = nil
        if doc != nil then
            parent_id = doc.parent_id
        elseif prefill != nil and prefill.parent_id != nil then
            parent_id = prefill.parent_id
        end
        parent_options_html = ui.document_parent_options(document.all_active(db_path), parent_id, entity_id)
        body = ui.render_document_edit(doc, parent_options_html, csrf_val, nil, req.nonce, prefill)
        page_context = {page_type = "document_edit", entity_type = "document", entity_id = entity_id, title = "Edit document"}
        return web_ctx.render_page(req, "Edit document", "documents", body, page_context)
    end

    if path_info == "/document-save" and method == "POST" then
        form = web_ctx.parse_query(io.read("*all"))
        if not web_ctx.require_csrf(req, form.csrf_token) then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: CSRF check failed</h3>")
        end

        entity_id = tonumber(form.entity_id)
        parent_id = nil
        if form.parent_id != nil and form.parent_id != "" then
            parent_id = tonumber(form.parent_id)
        end

        if entity_id != nil and document.would_create_cycle(db_path, entity_id, parent_id) then
            doc = entity.get(db_path, "document", entity_id)
            parent_options_html = ui.document_parent_options(document.all_active(db_path), parent_id, entity_id)
            body = ui.render_document_edit(doc, parent_options_html, csrf_val,
                "Can't move a document underneath its own sub-document.", req.nonce)
            page_context = {page_type = "document_edit", entity_type = "document", entity_id = entity_id, title = "Edit document"}
            return web_ctx.render_page(req, "Edit document", "documents", body, page_context)
        end

        saved_id = nil
        issues = nil
        if entity_id != nil then
            saved_id, issues = document.update_page(db_path, author, entity_id, form.title, parent_id, form.content,
                web_ctx.source_from_params(params))
        else
            saved_id, issues = document.create_page(db_path, author, form.title, parent_id, form.content,
                web_ctx.source_from_params(params))
        end

        if saved_id == nil then
            doc = nil
            if entity_id != nil then
                doc = entity.get(db_path, "document", entity_id)
            end
            parent_options_html = ui.document_parent_options(document.all_active(db_path), parent_id, entity_id)
            body = ui.render_document_edit(doc, parent_options_html, csrf_val,
                web_ctx.issues_to_message(issues), req.nonce)
            page_context = {page_type = "document_edit", entity_type = "document", entity_id = entity_id, title = "Edit document"}
            return web_ctx.render_page(req, "Edit document", "documents", body, page_context)
        end

        return web_ctx.respond(req, "302 Found", "text/plain", "", {"Location: document?entity_id=" .. tostring(saved_id)})
    end

    if path_info == "/templates" then
        templates_dir = config.templates_dir(root)
        body = ui.render_templates_list(template.all(templates_dir))
        return web_ctx.render_page(req, "Templates", "system", body)
    end

    if path_info == "/template" then
        template_name = params.template_name
        if template_name == nil or template_name == "" then
            return web_ctx.error_html(req, "400 Bad Request", "Missing 'template_name' parameter")
        end
        if not schema.valid_resource_name(template_name) then
            return web_ctx.error_html(req, "400 Bad Request", "Invalid 'template_name' parameter")
        end

        templates_dir = config.templates_dir(root)
        template_def, err = template.load(templates_dir, template_name)
        if template_def == nil then
            return web_ctx.error_html(req, "404 Not Found", err)
        end

        rendered = template.render(template_def)
        body = ui.render_template(template_def, rendered, req.nonce)
        return web_ctx.render_page(req, template_name, "system", body)
    end

    return false
end

return knowledge_routes
