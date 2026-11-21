-- Document tree/detail/editor, Knowledge Pool pages & graph data,
-- reusable document entry templates, and their /api/v1 counterparts
-- (/api/v1/documents/*, /api/v1/templates*, /api/v1/knowledge/*).

const config = require("config")
const schema = require("schema")
const entity = require("entity")
const document = require("document")
const knowledge = require("knowledge")
const template = require("template")
const ui = require("ui")
const web_ctx = require("web.context")

const knowledge_routes = {}

function render_document_body(db_path, content)
    rendered_html = document.render_html(db_path, content)
    return ui.expand_inline_views(db_path, rendered_html)
end

function build_document_view(db_path, entity_id)
    doc = entity.get(db_path, "document", entity_id)
    if doc == nil then
        return nil
    end
    rendered_html = render_document_body(db_path, doc.content)
    breadcrumbs = document.breadcrumbs(db_path, entity_id)
    children = document.children(db_path, entity_id)
    links = document.links(db_path, entity_id)
    related = web_ctx.document_related_records(db_path, entity_id)
    return {
        document = doc,
        rendered_html = rendered_html,
        breadcrumbs = web_ctx.as_json_array(breadcrumbs),
        children = web_ctx.as_json_array(children),
        links = web_ctx.as_json_array(links),
        related = web_ctx.as_json_array(related),
    }
end

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
        view_model = build_document_view(db_path, entity_id)
        if view_model == nil then
            return web_ctx.error_html(req, "404 Not Found", "no such document #" .. tostring(entity_id))
        end
        doc = view_model.document
        body = ui.render_document(db_path, doc, view_model.rendered_html, view_model.breadcrumbs,
            view_model.children, view_model.links, true, view_model.related)
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
        form = web_ctx.parse_query(web_ctx.read_body())
        if not web_ctx.require_csrf(req, form.csrf_token) then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: CSRF check failed</h3>")
        end

        entity_id = tonumber(form.entity_id)
        parent_id = nil
        if form.parent_id != nil and form.parent_id != "" then
            parent_id = tonumber(form.parent_id)
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

function knowledge_routes.handle_api_v1(req)
    path_info = req.path_info
    method = req.method
    db_path = req.db_path
    root = req.root
    params = req.params
    author = req.author

    if path_info == "/api/v1/documents/tree" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        rows = document.all_active(db_path)
        return web_ctx.respond_json(req, "200 OK", {documents = web_ctx.as_json_array(rows)})
    end

    if path_info == "/api/v1/documents/search" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        query = web_ctx.default_value(params.q, "")
        limit = tonumber(params.limit)
        if limit == nil or limit < 1 then
            limit = 10
        end
        if query == "" then
            return web_ctx.respond_json(req, "200 OK", {results = web_ctx.as_json_array({})})
        end
        results = knowledge.search_for_display(db_path, query, limit, nil, author, false)
        return web_ctx.respond_json(req, "200 OK", {results = web_ctx.as_json_array(results)})
    end

    if path_info == "/api/v1/documents/link-search" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        query_str = web_ctx.default_value(params.query, "")
        results = document.search_for_link(db_path, query_str, 20, params.exclude_id)
        return web_ctx.respond_json(req, "200 OK", web_ctx.as_json_array(results))
    end

    if path_info == "/api/v1/documents/render" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        body_data, ok_body = web_ctx.read_write_json(req, false)
        if not ok_body then
            return true
        end
        rendered = render_document_body(db_path, body_data.content)
        return web_ctx.respond_json(req, "200 OK", {html = rendered})
    end

    if path_info == "/api/v1/documents/connection-draft" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        a_id = tonumber(params.connect_a)
        b_id = tonumber(params.connect_b)
        if a_id == nil or b_id == nil then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "Missing 'connect_a' or 'connect_b' parameter"})
        end
        draft = document.connection_draft(db_path, a_id, b_id, nil)
        if draft == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "Document not found"})
        end
        return web_ctx.respond_json(req, "200 OK", {draft = draft})
    end

    doc_id_str = string.match(path_info, "^/api/v1/documents/(%d+)$")
    if doc_id_str != nil then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        view_model = build_document_view(db_path, tonumber(doc_id_str))
        if view_model == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "Not found"})
        end
        return web_ctx.respond_json(req, "200 OK", view_model)
    end

    if path_info == "/api/v1/templates" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        templates_dir = config.templates_dir(root)
        items = {}
        for _, entry in ipairs(template.all(templates_dir)) do
            if entry.def != nil then
                def = entry.def
                table.insert(items, {
                    name = def.name,
                    label = def.label,
                    description = def.description,
                    default_path = def.default_path,
                    sections = def.sections,
                })
            elseif entry.err != nil then
                table.insert(items, {
                    name = entry.name,
                    error = entry.err,
                })
            end
        end
        return web_ctx.respond_json(req, "200 OK", {templates = web_ctx.as_json_array(items)})
    end

    if string.sub(path_info, 1, 18) == "/api/v1/templates/" then
        template_name = web_ctx.percent_decode(string.sub(path_info, 19))
        if string.find(template_name, "/", 1, true) != nil then
            return false
        end
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        if not schema.valid_resource_name(template_name) then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "Invalid template name"})
        end
        templates_dir = config.templates_dir(root)
        template_def, err = template.load(templates_dir, template_name)
        if template_def == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = tostring(err)})
        end
        default_path = template_def.default_path
        if default_path == nil then
            default_path = template_def.label
        end
        return web_ctx.respond_json(req, "200 OK", {
            template = template_def,
            default_path = default_path,
            content = template.render(template_def),
        })
    end

    if path_info == "/api/v1/knowledge/stats" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        raw_stats = knowledge.stats(db_path)
        str_tiers = {}
        if type(raw_stats.tier_counts) == "table" then
            for tier = 0, 3 do
                str_tiers[tostring(tier)] = raw_stats.tier_counts[tier]
            end
        end
        raw_stats.tier_counts = str_tiers
        return web_ctx.respond_json(req, "200 OK", raw_stats)
    end

    if path_info == "/api/v1/knowledge/documents" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        rows = nil
        if params.reviewed == "1" then
            rows = knowledge.reviewed_documents(db_path)
        else
            rows = knowledge.list_documents(db_path, tonumber(params.tier))
        end
        return web_ctx.respond_json(req, "200 OK", {documents = web_ctx.as_json_array(rows)})
    end

    if path_info == "/api/v1/knowledge/graph" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        nodes = knowledge.graph_nodes(db_path)
        edges = document.graph_edges(db_path)
        return web_ctx.respond_json(req, "200 OK", {
            nodes = web_ctx.as_json_array(nodes),
            edges = web_ctx.as_json_array(edges),
        })
    end

    if path_info == "/api/v1/knowledge/retrievals" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        limit = tonumber(params.limit)
        if limit == nil or limit < 1 then
            limit = 500
        end
        rows = knowledge.recent_retrievals(db_path, limit)
        return web_ctx.respond_json(req, "200 OK", {retrievals = web_ctx.as_json_array(rows)})
    end

    return false
end

return knowledge_routes
