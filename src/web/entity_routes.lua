-- Entity CRUD pages, saved SQL views, ad-hoc SQL console, and their
-- /api/v1 counterparts (/api/v1/schemas*, /api/v1/entities*, /api/v1/views*,
-- /api/v1/sql).

const db = require("database")
const schema = require("schema")
const entity = require("entity")
const ledger = require("ledger")
const view = require("view")
const label = require("label")
const json = require("dkjson")
const ui = require("ui")
const web_ctx = require("web.context")

const entity_routes = {}

function autocomplete_rows(db_path, ref_type, query_str)
    if not db.table_exists(db_path, ref_type) then
        return {}
    end

    cols = db.get_columns(db_path, ref_type)
    if #cols == 0 then
        return {}
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
    return web_ctx.default_value(rows, {})
end

function build_preview(db_path, entity_type, entity_id)
    if not db.table_exists(db_path, entity_type) then
        return nil
    end

    rows = db.query(db_path, "SELECT * FROM " .. db.quote_ident(entity_type) .. " WHERE id = " .. db.quote(entity_id) .. ";")
    if rows == nil or rows[1] == nil then
        return nil
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
    preview_fields = {}
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
                rendered_val = ui.display_field_value(db_path, field, value)
                field_lines = field_lines .. "<div><strong>" .. ui.html_escape(field.label) .. ":</strong> " ..
                    rendered_val .. "</div>"
                table.insert(preview_fields, {
                    name = field.name,
                    label = field.label,
                    value = value,
                    display_html = rendered_val,
                })
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
    return {
        title = title,
        fields = web_ctx.as_json_array(preview_fields),
        html = preview_html,
    }
end

function schemas_with_counts(db_path)
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
    return entity_types, edges
end

function sql_reference_columns(db_path, sql_text)
    from_table = view.guess_from_table(sql_text)
    ref_columns = view.reference_columns(db_path, view.guess_tables(sql_text))
    if from_table != nil and schema.is_registered(db_path, from_table) then
        ref_columns["id"] = from_table
    end
    return ref_columns
end

function entity_routes.handle(req)
    path_info = req.path_info
    db_path = req.db_path
    params = req.params

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
        entity_types, edges = schemas_with_counts(db_path)
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
            ref_columns = sql_reference_columns(db_path, sql_text)
        end
        body = ui.render_sql(db_path, sql_text, column_names, rows, sql_err, ref_columns, req.nonce, params.embed == "1", req.theme, truncated)
        if params.embed == "1" then
            return web_ctx.respond(req, "200 OK", "text/html", body)
        end
        return web_ctx.render_page(req, "SQL", "system", body,
            {page_type = "sql", title = "SQL", query_ran = (params.q != nil)})
    end

    return false
end

function handle_api_v1_entities(req, tail)
    db_path = req.db_path
    method = req.method
    params = req.params
    author = req.author

    v1_type_raw, v1_rest = string.match(tail, "^([^/]+)(.*)$")
    if v1_type_raw == nil then
        return false
    end
    v1_type = web_ctx.percent_decode(v1_type_raw)

    if not schema.valid_name_syntax(v1_type) then
        if method != "GET" and method != "HEAD" then
            web_ctx.read_body()
        end
        return web_ctx.respond_json(req, "400 Bad Request", {error = "Invalid type"})
    end
    if not schema.is_registered(db_path, v1_type) then
        if method != "GET" and method != "HEAD" then
            web_ctx.read_body()
        end
        return web_ctx.respond_json(req, "404 Not Found", {error = "Unknown type: " .. v1_type})
    end

    v1_source = web_ctx.request_source(req)

    if v1_rest == "" then
        if method == "GET" then
            max_ev = entity.max_event_id(db_path)
            v1_limit = tonumber(params.limit)
            if v1_limit == nil then
                v1_limit = web_ctx.BROWSE_PAGE_SIZE
            end
            v1_offset = tonumber(params.offset)
            if v1_offset == nil then
                v1_offset = 0
            end
            if params.since_event != nil and params.since_event != "" then
                since_num = tonumber(params.since_event)
                if since_num == nil or since_num < 0 then
                    return web_ctx.respond_json(req, "400 Bad Request", {error = "Invalid 'since_event' parameter"})
                end
                v1_total = entity.count_since_event(db_path, v1_type, since_num)
                v1_rows = entity.list_since_event(db_path, v1_type, since_num, v1_limit, v1_offset)
                return web_ctx.respond_json(req, "200 OK", {
                    rows = web_ctx.as_json_array(v1_rows),
                    total = v1_total,
                    max_event_id = max_ev,
                })
            end
            layout = schema.layout(db_path, v1_type)
            v1_filter_field = nil
            if params.filter_field != nil and params.filter_field != "" and params.filter_value != nil and layout != nil then
                for _, field in ipairs(layout.fields) do
                    if field.name == params.filter_field then
                        v1_filter_field = params.filter_field
                    end
                end
            end
            v1_total = nil
            v1_rows = nil
            if v1_filter_field != nil then
                v1_total = entity.count_by_field(db_path, v1_type, v1_filter_field, params.filter_value)
                v1_rows = entity.list_by_field(db_path, v1_type, v1_filter_field, params.filter_value, v1_limit, v1_offset)
            else
                v1_total = entity.count(db_path, v1_type)
                v1_rows = entity.list(db_path, v1_type, v1_limit, v1_offset)
            end
            return web_ctx.respond_json(req, "200 OK", {
                rows = web_ctx.as_json_array(v1_rows),
                total = v1_total,
                max_event_id = max_ev,
            })
        end

        if method == "POST" then
            decoded, ok_body = web_ctx.read_write_json(req, false)
            if not ok_body then
                return true
            end
            if not web_ctx.require_write_capability(req, v1_type) then
                return web_ctx.respond_json(req, "403 Forbidden", {error = "Admin capability required to write this entity type"})
            end

            if decoded[1] != nil then
                created_ids, batch_issues = entity.create_batch(db_path, v1_type, decoded, author, v1_source)
                response = {issues = web_ctx.as_json_array(batch_issues)}
                if created_ids != nil then
                    response.created_ids = web_ctx.as_json_array(created_ids)
                    response.success = true
                else
                    response.success = false
                end
                return web_ctx.respond_json(req, "200 OK", response)
            end

            created_id, issues = entity.create(db_path, v1_type, decoded, author, v1_source)
            response = {issues = web_ctx.as_json_array(issues)}
            if created_id != nil then
                response.created_id = created_id
                response.success = true
            else
                response.success = false
            end
            return web_ctx.respond_json(req, "200 OK", response)
        end

        web_ctx.read_body()
        return web_ctx.method_not_allowed(req)
    end

    if v1_rest == "/validate" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        rows_values, ok_body = web_ctx.read_write_json(req, false)
        if not ok_body then
            return true
        end
        if rows_values[1] == nil and next(rows_values) != nil then
            rows_values = {rows_values}
        end
        batch_issues = entity.validate_batch(db_path, v1_type, rows_values)
        return web_ctx.respond_json(req, "200 OK", {
            valid = (#batch_issues == 0),
            issues = web_ctx.as_json_array(batch_issues),
        })
    end

    if v1_rest == "/autocomplete" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        query_str = web_ctx.default_value(params.query, "")
        rows = autocomplete_rows(db_path, v1_type, query_str)
        return web_ctx.respond_json(req, "200 OK", web_ctx.as_json_array(rows))
    end

    v1_id_str, v1_action = string.match(v1_rest, "^/(%d+)/([a-z_]+)$")
    if v1_id_str == nil then
        v1_id_str = string.match(v1_rest, "^/(%d+)$")
    end
    if v1_id_str == nil then
        return false
    end
    v1_entity_id = tonumber(v1_id_str)

    if v1_action == nil then
        if method == "GET" then
            row = entity.get(db_path, v1_type, v1_entity_id)
            if row == nil then
                return web_ctx.respond_json(req, "404 Not Found", {error = "Not found"})
            end
            return web_ctx.respond_json(req, "200 OK", {row = row})
        end

        if method == "PATCH" then
            values, ok_body = web_ctx.read_write_json(req, false)
            if not ok_body then
                return true
            end
            if not web_ctx.require_write_capability(req, v1_type) then
                return web_ctx.respond_json(req, "403 Forbidden", {error = "Admin capability required to write this entity type"})
            end
            updated_id, issues = entity.update(db_path, v1_type, v1_entity_id, values, author, v1_source, params.reason)
            response = {issues = web_ctx.as_json_array(issues)}
            if updated_id != nil then
                response.updated_id = updated_id
                response.success = true
            else
                response.success = false
            end
            return web_ctx.respond_json(req, "200 OK", response)
        end

        web_ctx.read_body()
        return web_ctx.method_not_allowed(req)
    end

    if v1_action == "archive" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        _, ok_body = web_ctx.read_write_json(req, true)
        if not ok_body then
            return true
        end
        if not web_ctx.require_write_capability(req, v1_type) then
            return web_ctx.respond_json(req, "403 Forbidden", {error = "Admin capability required to write this entity type"})
        end
        archived_id, issues = entity.archive(db_path, v1_type, v1_entity_id, author, v1_source, params.reason)
        response = {issues = web_ctx.as_json_array(issues)}
        if archived_id != nil then
            response.archived_id = archived_id
            response.success = true
        else
            response.success = false
        end
        return web_ctx.respond_json(req, "200 OK", response)
    end

    if v1_action == "unarchive" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        _, ok_body = web_ctx.read_write_json(req, true)
        if not ok_body then
            return true
        end
        if not web_ctx.require_write_capability(req, v1_type) then
            return web_ctx.respond_json(req, "403 Forbidden", {error = "Admin capability required to write this entity type"})
        end
        unarchived_id, issues = entity.unarchive(db_path, v1_type, v1_entity_id, author, v1_source, params.reason)
        response = {issues = web_ctx.as_json_array(issues)}
        if unarchived_id != nil then
            response.unarchived_id = unarchived_id
            response.success = true
        else
            response.success = false
        end
        return web_ctx.respond_json(req, "200 OK", response)
    end

    if v1_action == "history" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        if entity.get(db_path, v1_type, v1_entity_id) == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "Not found"})
        end
        events = ledger.history(db_path, v1_entity_id)
        return web_ctx.respond_json(req, "200 OK", {events = web_ctx.as_json_array(events)})
    end

    if v1_action == "related" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        if entity.get(db_path, v1_type, v1_entity_id) == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "Not found"})
        end
        related = web_ctx.related_records(db_path, v1_type, v1_entity_id)
        return web_ctx.respond_json(req, "200 OK", {related = web_ctx.as_json_array(related)})
    end

    if v1_action == "preview" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        prev = build_preview(db_path, v1_type, v1_entity_id)
        if prev == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "Not found", html = "Not found."})
        end
        return web_ctx.respond_json(req, "200 OK", prev)
    end

    if v1_action == "label" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        zpl, err = label.render(db_path, v1_type, v1_entity_id)
        if zpl == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = tostring(err)})
        end
        return web_ctx.respond_json(req, "200 OK", {zpl = zpl})
    end

    return false
end

function entity_routes.handle_api_v1(req)
    path_info = req.path_info
    method = req.method
    db_path = req.db_path
    params = req.params

    if path_info == "/api/v1/schemas" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        entity_types, edges = schemas_with_counts(db_path)
        return web_ctx.respond_json(req, "200 OK", {
            schemas = web_ctx.as_json_array(entity_types),
            relationships = web_ctx.as_json_array(edges),
        })
    end

    if string.sub(path_info, 1, 16) == "/api/v1/schemas/" then
        type_name = web_ctx.percent_decode(string.sub(path_info, 17))
        if string.find(type_name, "/", 1, true) != nil then
            return false
        end
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        if not schema.valid_name_syntax(type_name) then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "Invalid type"})
        end
        layout, _ = schema.layout(db_path, type_name)
        if layout == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "Unknown type: " .. type_name})
        end
        return web_ctx.respond_json(req, "200 OK", {
            layout = layout,
            admin_write_only = schema.admin_write_only(db_path, type_name),
            reason_flags = schema.reason_flags(db_path, type_name),
            has_label_template = label.has_template(db_path, type_name),
        })
    end

    if path_info == "/api/v1/entities" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        query_str = web_ctx.default_value(params.query, "")
        results = entity.search_across_types(db_path, query_str, 5, 20)
        return web_ctx.respond_json(req, "200 OK", web_ctx.as_json_array(results))
    end

    if string.sub(path_info, 1, 17) == "/api/v1/entities/" then
        return handle_api_v1_entities(req, string.sub(path_info, 18))
    end

    if path_info == "/api/v1/views" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        all_entries = view.all(db_path, req.root)
        items = {}
        for _, entry in ipairs(all_entries) do
            if entry.def != nil then
                def = entry.def
                table.insert(items, {
                    name = def.name,
                    label = def.label,
                    description = def.description,
                    param = def.param,
                    columns = def.columns,
                    approved = view.is_approved(db_path, def),
                })
            elseif entry.err != nil then
                table.insert(items, {
                    name = entry.name,
                    approved = false,
                    error = entry.err,
                })
            end
        end
        return web_ctx.respond_json(req, "200 OK", {views = web_ctx.as_json_array(items)})
    end

    if string.sub(path_info, 1, 14) == "/api/v1/views/" then
        view_name = web_ctx.percent_decode(string.sub(path_info, 15))
        if string.find(view_name, "/", 1, true) != nil then
            return false
        end
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        if not schema.valid_resource_name(view_name) then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "Invalid view name"})
        end
        view_def, err = view.load(db_path, view_name, req.root)
        if view_def == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = tostring(err)})
        end
        if view.is_approved(db_path, view_def) == false then
            return web_ctx.respond_json(req, "403 Forbidden", {error = "view '" .. view_name .. "' is not approved"})
        end
        param_value = nil
        if view_def.param != nil then
            param_value = params[view_def.param.name]
        end
        rows, run_err = view.run(db_path, view_def, param_value)
        if rows == nil then
            return web_ctx.respond_json(req, "500 Internal Server Error", {error = tostring(run_err)})
        end
        return web_ctx.respond_json(req, "200 OK", {
            view = {
                name = view_def.name,
                label = view_def.label,
                description = view_def.description,
                columns = view_def.columns,
                param = view_def.param,
            },
            param_value = param_value,
            rows = web_ctx.as_json_array(rows),
        })
    end

    if path_info == "/api/v1/sql" then
        if method != "GET" and method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        if web_ctx.has_capability(req.capabilities, "s") == false and web_ctx.has_capability(req.capabilities, "a") == false then
            if method == "POST" then
                web_ctx.read_body()
            end
            return web_ctx.respond_json(req, "403 Forbidden", {error = "Setup or Admin capability required"})
        end
        sql_text = nil
        if method == "POST" then
            body_data, ok_body = web_ctx.read_write_json(req, false)
            if not ok_body then
                return true
            end
            sql_text = body_data.q
        else
            sql_text = params.q
        end
        if sql_text == nil or sql_text == "" then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "Missing 'q' SQL query"})
        end
        column_names, rows, sql_err, truncated = view.run_adhoc(db_path, sql_text)
        if sql_err != nil then
            return web_ctx.respond_json(req, "400 Bad Request", {sql = sql_text, error = tostring(sql_err)})
        end
        ref_columns = sql_reference_columns(db_path, sql_text)
        return web_ctx.respond_json(req, "200 OK", {
            sql = sql_text,
            columns = web_ctx.as_json_array(column_names),
            rows = web_ctx.as_json_array(rows),
            ref_columns = ref_columns,
            truncated = (truncated == true),
        })
    end

    return false
end

return entity_routes
