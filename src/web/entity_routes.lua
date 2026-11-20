-- Entity CRUD pages, views, SQL console, and browser UI JSON endpoints
-- (/data, /register, /browse, /detail, /entity-edit, /label, /view, /sql,
-- /api/autocomplete, /api/entity-search, /api/document-search, /api/preview,
-- /api/document-preview, /api/validate, /api/submit, /api/update,
-- /api/archive, /api/unarchive).

const db = require("database")
const schema = require("schema")
const entity = require("entity")
const ledger = require("ledger")
const view = require("view")
const document = require("document")
const label = require("label")
const json = require("dkjson")
const ui = require("ui")
const web_ctx = require("web.context")

const entity_routes = {}

function handle_autocomplete(req)
    db_path = req.db_path
    params = req.params
    ref_type = params.type
    query_str = web_ctx.default_value(params.query, "")
    if ref_type == nil or ref_type == "" then
        return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Missing type"}))
    end
    if not schema.valid_name_syntax(ref_type) then
        return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
    end

    if not db.table_exists(db_path, ref_type) then
        return web_ctx.respond(req, "200 OK", "application/json", "[]")
    end

    cols = db.get_columns(db_path, ref_type)
    if #cols == 0 then
        return web_ctx.respond(req, "200 OK", "application/json", "[]")
    end

    col_set = {}
    for _, col in ipairs(cols) do
        col_set[col] = true
    end

    display_field = nil
    first_identifier_field = nil
    first_user_field = nil
    identifier_fields = {}
    for _, f in ipairs(schema.fields(db_path, ref_type)) do
        if col_set[f.name] == true then
            if first_user_field == nil then
                first_user_field = f.name
            end
            if display_field == nil and tonumber(f.display) == 1 then
                display_field = f.name
            end
            if tonumber(f.identifier) == 1 then
                if first_identifier_field == nil then
                    first_identifier_field = f.name
                end
                table.insert(identifier_fields, f.name)
            end
        end
    end

    search_cols = {}
    seen_search = {}
    function add_search_col(c)
        if c != nil and col_set[c] == true and seen_search[c] == nil then
            seen_search[c] = true
            table.insert(search_cols, c)
        end
    end
    add_search_col("id")
    add_search_col("name")
    add_search_col(display_field)
    for _, id_col in ipairs(identifier_fields) do
        add_search_col(id_col)
    end
    add_search_col("title")
    add_search_col("label")
    if display_field == nil and first_identifier_field == nil then
        add_search_col(first_user_field)
    end
    if #search_cols == 0 then
        table.insert(search_cols, cols[1])
    end

    where = {}
    for _, col in ipairs(search_cols) do
        table.insert(where, db.quote_ident(col) .. " LIKE " .. db.quote("%" .. query_str .. "%"))
    end

    text_col = nil
    if display_field != nil then
        text_col = display_field
    elseif first_identifier_field != nil then
        text_col = first_identifier_field
    elseif col_set["title"] == true then
        text_col = "title"
    elseif col_set["label"] == true then
        text_col = "label"
    elseif first_user_field != nil then
        text_col = first_user_field
    elseif col_set["name"] == true then
        text_col = "name"
    else
        for _, col in ipairs(cols) do
            if schema.is_reserved_field_name(col) == false then
                text_col = col
                break
            end
        end
    end
    if text_col == nil then
        text_col = "id"
    end

    q = nil
    if text_col == "name" then
        q = "SELECT id, name FROM " .. db.quote_ident(ref_type)
    elseif col_set["name"] == true then
        q = "SELECT id, COALESCE(NULLIF(name, ''), " .. db.quote_ident(text_col) .. ") AS name FROM " .. db.quote_ident(ref_type)
    else
        q = "SELECT id, " .. db.quote_ident(text_col) .. " AS name FROM " .. db.quote_ident(ref_type)
    end

    clauses = {}
    if col_set["archived_at"] == true then
        table.insert(clauses, "(archived_at IS NULL OR archived_at = '')")
    end
    if #where > 0 then
        table.insert(clauses, "(" .. table.concat(where, " OR ") .. ")")
    end
    if #clauses > 0 then
        q = q .. " WHERE " .. table.concat(clauses, " AND ")
    end
    q = q .. " LIMIT 15;"

    rows = db.query(db_path, q)
    result = web_ctx.default_value(rows, {})
    return web_ctx.respond(req, "200 OK", "application/json", json.encode(result))
end

function handle_preview(req)
    db_path = req.db_path
    params = req.params
    entity_type = params.type
    entity_id = tonumber(params.entity_id)
    if entity_type == nil or entity_type == "" or entity_id == nil then
        return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
    end
    if not schema.valid_name_syntax(entity_type) then
        return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
    end
    if not db.table_exists(db_path, entity_type) then
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({html = "Unknown entity type."}))
    end

    rows = db.query(db_path, "SELECT * FROM " .. entity_type .. " WHERE id = " .. db.quote(entity_id) .. ";")
    if rows == nil or rows[1] == nil then
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({html = "Not found."}))
    end
    entity.apply_computed_field_overrides(db_path, entity_type, rows)
    row = rows[1]

    title = ui.own_row_label(db_path, entity_type, row)
    if title == nil then
        title = entity_type .. " #" .. tostring(entity_id)
    end

    entity_layout, _ = schema.layout(db_path, entity_type)
    fields = {}
    if entity_layout != nil then
        fields = entity_layout.fields
    end

    field_lines = ""
    shown = 0
    for _, field in ipairs(fields) do
        if shown < 5 then
            value = row[field.name]
            is_empty = value == nil
            if type(value) == "table" then
                is_empty = #value == 0
            elseif tostring(value) == "" then
                is_empty = true
            end
            if is_empty == false then
                field_lines = field_lines .. "<div><strong>" .. ui.html_escape(field.label) .. ":</strong> " ..
                    ui.display_field_value(db_path, field, value) .. "</div>"
                shown = shown + 1
            end
        end
    end
    if field_lines == "" then
        field_lines = "<div style=\"color:#94a3b8;\">No fields to show.</div>"
    end

    preview_html = "<strong>" .. ui.html_escape(title) .. "</strong>" ..
        "<hr style=\"margin:6px 0;border:none;border-top:1px solid #e2e8f0;\">" ..
        field_lines
    return web_ctx.respond(req, "200 OK", "application/json", json.encode({html = preview_html}))
end

function entity_routes.handle(req)
    path_info = req.path_info
    method = req.method
    db_path = req.db_path
    params = req.params
    author = req.author

    if path_info == "/register" then
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return web_ctx.error_html(req, "400 Bad Request", "Missing 'type' parameter")
        end
        if not schema.valid_name_syntax(entity_type) then
            return web_ctx.error_html(req, "400 Bad Request", "Invalid 'type' parameter")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return web_ctx.error_html(req, "404 Not Found", err)
        end
        layout = web_ctx.filter_layout_columns(layout, params.columns)
        layout_json = json.encode(layout)

        locked_fields = web_ctx.collect_locked_fields(db_path, layout, params)
        body = ui.render(entity_type, layout_json, req.nonce, locked_fields)
        page_context = {page_type = "entity_register", entity_type = entity_type, title = entity_type .. " · Register"}
        return web_ctx.render_page(req, entity_type .. " · Register", "data", body, page_context)
    end

    if path_info == "/browse" then
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return web_ctx.error_html(req, "400 Bad Request", "Missing 'type' parameter")
        end
        if not schema.valid_name_syntax(entity_type) then
            return web_ctx.error_html(req, "400 Bad Request", "Invalid 'type' parameter")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return web_ctx.error_html(req, "404 Not Found", err)
        end

        filter_field = nil
        if params.filter_field != nil and params.filter_field != "" and params.filter_value != nil then
            for _, field in ipairs(layout.fields) do
                if field.name == params.filter_field then
                    filter_field = params.filter_field
                end
            end
        end

        page = tonumber(params.page)
        if page == nil or page < 1 then
            page = 1
        end
        offset = (page - 1) * web_ctx.BROWSE_PAGE_SIZE
        total = nil
        rows = nil
        if filter_field != nil then
            total = entity.count_by_field(db_path, entity_type, filter_field, params.filter_value)
            rows = entity.list_by_field(db_path, entity_type, filter_field, params.filter_value, web_ctx.BROWSE_PAGE_SIZE, offset)
        else
            total = entity.count(db_path, entity_type)
            rows = entity.list(db_path, entity_type, web_ctx.BROWSE_PAGE_SIZE, offset)
        end
        body = ui.render_browse(db_path, entity_type, layout, rows, page, web_ctx.BROWSE_PAGE_SIZE, total, req.nonce, filter_field, params.filter_value)
        page_context = {page_type = "entity_browse", entity_type = entity_type, title = entity_type .. " · Browse"}
        return web_ctx.render_page(req, entity_type .. " · Browse", "data", body, page_context)
    end

    if path_info == "/data" then
        entity_types = schema.list(db_path)
        counts_by_name = entity.counts_by_type(db_path, entity_types)
        for _, row in ipairs(entity_types) do
            c = counts_by_name[row.name]
            if c == nil then
                c = 0
            end
            row.count = c
        end
        table.sort(entity_types, function(a, b)
            if a.count != b.count then
                return a.count > b.count
            end
            return a.name < b.name
        end)
        edges = schema.relationships(db_path, entity_types)
        body = ui.render_index(db_path, entity_types, edges, req.nonce)
        return web_ctx.render_page(req, "Data", "data", body)
    end

    if path_info == "/detail" then
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return web_ctx.error_html(req, "400 Bad Request", "Missing 'type' or 'entity_id' parameter")
        end
        if not schema.valid_name_syntax(entity_type) then
            return web_ctx.error_html(req, "400 Bad Request", "Invalid 'type' parameter")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return web_ctx.error_html(req, "404 Not Found", err)
        end

        row = entity.get(db_path, entity_type, entity_id)
        if row == nil then
            return web_ctx.error_html(req, "404 Not Found", "no such " .. entity_type .. " #" .. tostring(entity_id))
        end

        history = ledger.history(db_path, entity_id)
        has_label_template = label.has_template(db_path, entity_type)
        related = web_ctx.related_records(db_path, entity_type, entity_id)
        body = ui.render_detail(db_path, entity_type, layout, row, history, req.nonce, has_label_template, related)
        page_context = {page_type = "entity_detail", entity_type = entity_type, entity_id = entity_id,
                        title = entity_type .. " #" .. tostring(entity_id)}
        return web_ctx.render_page(req, entity_type .. " #" .. tostring(entity_id), "data", body, page_context)
    end

    if path_info == "/entity-edit" then
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return web_ctx.error_html(req, "400 Bad Request", "Missing 'type' or 'entity_id' parameter")
        end
        if not schema.valid_name_syntax(entity_type) then
            return web_ctx.error_html(req, "400 Bad Request", "Invalid 'type' parameter")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return web_ctx.error_html(req, "404 Not Found", err)
        end
        layout_json = json.encode(layout)

        row = entity.get(db_path, entity_type, entity_id)
        if row == nil then
            return web_ctx.error_html(req, "404 Not Found", "no such " .. entity_type .. " #" .. tostring(entity_id))
        end
        row_json = json.encode(row)

        body = ui.render_entity_edit(entity_type, layout_json, row_json, entity_id, req.nonce)
        page_context = {page_type = "entity_edit", entity_type = entity_type, entity_id = entity_id,
                        title = "Edit " .. entity_type .. " #" .. tostring(entity_id)}
        return web_ctx.render_page(req, "Edit " .. entity_type .. " #" .. tostring(entity_id), "data", body, page_context)
    end

    if path_info == "/label" then
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return web_ctx.respond(req, "400 Bad Request", "text/plain", "Missing 'type' or 'entity_id' parameter")
        end
        if not schema.valid_name_syntax(entity_type) then
            return web_ctx.respond(req, "400 Bad Request", "text/plain", "Invalid 'type' parameter")
        end

        zpl, err = label.render(db_path, entity_type, entity_id)
        if zpl == nil then
            return web_ctx.respond(req, "404 Not Found", "text/plain", tostring(err))
        end
        return web_ctx.respond(req, "200 OK", "text/plain", zpl)
    end

    if path_info == "/view" then
        view_name = params.view_name
        if view_name == nil or view_name == "" then
            return web_ctx.error_html(req, "400 Bad Request", "Missing 'view_name' parameter")
        end
        if not schema.valid_resource_name(view_name) then
            return web_ctx.error_html(req, "400 Bad Request", "Invalid 'view_name' parameter")
        end

        view_def, err = view.load(db_path, view_name, req.root)
        if view_def == nil then
            return web_ctx.error_html(req, "404 Not Found", err)
        end
        if view.is_approved(db_path, view_def) == false then
            return web_ctx.error_html(req, "403 Forbidden", "view '" .. view_name .. "' is not approved")
        end

        param_value = nil
        if view_def.param != nil then
            param_value = params[view_def.param.name]
        end

        rows, run_err = view.run(db_path, view_def, param_value)
        if rows == nil then
            return web_ctx.error_html(req, "500 Internal Server Error", run_err)
        end
        body = ui.render_view(view_def, rows, param_value)
        page_context = {page_type = "view", view_name = view_name, title = view_name}
        active_section = "data"
        if view_name == "prioritized_tasks" then
            active_section = "tasks"
        end
        return web_ctx.render_page(req, view_name, active_section, body, page_context)
    end

    if path_info == "/sql" then
        if web_ctx.has_capability(req.capabilities, "s") == false and web_ctx.has_capability(req.capabilities, "a") == false then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Setup or Admin capability</h3>")
        end

        sql_text = params.q
        column_names = nil
        rows = nil
        sql_err = nil
        ref_columns = {}
        truncated = false
        if sql_text == nil then
            sql_text = "SELECT * FROM sample LIMIT 20;"
        elseif sql_text != "" then
            column_names, rows, sql_err, truncated = view.run_adhoc(db_path, sql_text)
            from_table = view.guess_from_table(sql_text)
            ref_columns = view.reference_columns(db_path, view.guess_tables(sql_text))
            if from_table != nil and schema.is_registered(db_path, from_table) then
                ref_columns["id"] = from_table
            end
        end
        body = ui.render_sql(db_path, sql_text, column_names, rows, sql_err, ref_columns, req.nonce, params.embed == "1", req.theme, truncated)
        if params.embed == "1" then
            return web_ctx.respond(req, "200 OK", "text/html", body)
        end
        return web_ctx.render_page(req, "SQL", "system", body,
            {page_type = "sql", title = "SQL", query_ran = (params.q != nil)})
    end

    if path_info == "/api/autocomplete" then
        return handle_autocomplete(req)
    end

    if path_info == "/api/entity-search" then
        query_str = web_ctx.default_value(params.query, "")
        results = entity.search_across_types(db_path, query_str, 5, 20)
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(results))
    end

    if path_info == "/api/document-search" then
        query_str = web_ctx.default_value(params.query, "")
        results = document.search_for_link(db_path, query_str, 20, params.exclude_id)
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(results))
    end

    if path_info == "/api/preview" then
        return handle_preview(req)
    end

    if path_info == "/api/document-preview" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        body_data, _, err = json.decode(io.read("*all"))
        if body_data == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        rendered = document.render_html(db_path, body_data.content)
        rendered = ui.expand_inline_views(db_path, rendered)
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({html = rendered}))
    end

    if path_info == "/api/validate" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Missing type"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        rows_values, _, err = json.decode(io.read("*all"))
        if rows_values == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        batch_issues = entity.validate_batch(db_path, entity_type, rows_values)
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(batch_issues))
    end

    if path_info == "/api/submit" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Missing type"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        if not web_ctx.require_write_capability(req, entity_type) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end
        rows_values, _, err = json.decode(io.read("*all"))
        if rows_values == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end

        created_ids, batch_issues = entity.create_batch(db_path, entity_type, rows_values, author, web_ctx.source_from_params(params))
        response = {issues = batch_issues}
        if created_ids != nil then
            response.created_ids = created_ids
            response.success = true
        else
            response.success = false
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(response))
    end

    if path_info == "/api/update" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        if not web_ctx.require_write_capability(req, entity_type) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end
        values, _, err = json.decode(io.read("*all"))
        if values == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end

        updated_id, issues = entity.update(db_path, entity_type, entity_id, values, author, web_ctx.source_from_params(params), params.reason)
        response = {issues = issues}
        if updated_id != nil then
            response.updated_id = updated_id
            response.success = true
        else
            response.success = false
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(response))
    end

    if path_info == "/api/archive" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        if not web_ctx.require_write_capability(req, entity_type) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end

        archived_id, issues = entity.archive(db_path, entity_type, entity_id, author, web_ctx.source_from_params(params), params.reason)
        response = {issues = issues}
        if archived_id != nil then
            response.archived_id = archived_id
            response.success = true
        else
            response.success = false
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(response))
    end

    if path_info == "/api/unarchive" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        if not web_ctx.require_write_capability(req, entity_type) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end

        unarchived_id, issues = entity.unarchive(db_path, entity_type, entity_id, author, web_ctx.source_from_params(params))
        response = {issues = issues}
        if unarchived_id != nil then
            response.unarchived_id = unarchived_id
            response.success = true
        else
            response.success = false
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(response))
    end

    return false
end

return entity_routes
