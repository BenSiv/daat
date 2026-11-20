-- Versioned external REST API (/api/v1/<type>[/<id>[/<action>]]).

const schema = require("schema")
const entity = require("entity")
const json = require("dkjson")
const web_ctx = require("web.context")

const api_v1_routes = {}

function api_v1_routes.handle(req)
    path_info = req.path_info
    v1_type, v1_id, v1_action = string.match(path_info, "^/api/v1/([a-z_][a-z0-9_]*)/(%d+)/([a-z_]+)$")
    if v1_type == nil then
        v1_type, v1_id = string.match(path_info, "^/api/v1/([a-z_][a-z0-9_]*)/(%d+)$")
    end
    if v1_type == nil then
        v1_type = string.match(path_info, "^/api/v1/([a-z_][a-z0-9_]*)$")
    end
    if v1_type == nil then
        return false
    end

    db_path = req.db_path
    method = req.method
    params = req.params
    author = req.author

    if not schema.valid_name_syntax(v1_type) then
        return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
    end
    if not schema.is_registered(db_path, v1_type) then
        return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "Unknown type: " .. v1_type}))
    end

    v1_entity_id = tonumber(v1_id)
    v1_source = web_ctx.source_from_params(params)
    if req.via_api_key then
        v1_source = {api_key = author}
    end

    if v1_id == nil and method == "GET" then
        layout = schema.layout(db_path, v1_type)
        v1_filter_field = nil
        if params.filter_field != nil and params.filter_field != "" and params.filter_value != nil and layout != nil then
            for _, field in ipairs(layout.fields) do
                if field.name == params.filter_field then
                    v1_filter_field = params.filter_field
                end
            end
        end
        v1_limit = tonumber(params.limit)
        if v1_limit == nil then
            v1_limit = web_ctx.BROWSE_PAGE_SIZE
        end
        v1_offset = tonumber(params.offset)
        if v1_offset == nil then
            v1_offset = 0
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
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({rows = v1_rows, total = v1_total}))
    end

    if v1_id == nil and method == "POST" then
        if not req.via_api_key and not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        if not web_ctx.require_write_capability(req, v1_type) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end
        decoded, _, err = json.decode(io.read("*all"))
        if decoded == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end

        if decoded[1] != nil then
            created_ids, batch_issues = entity.create_batch(db_path, v1_type, decoded, author, v1_source)
            response = {issues = batch_issues}
            if created_ids != nil then
                response.created_ids = created_ids
                response.success = true
            else
                response.success = false
            end
            return web_ctx.respond(req, "200 OK", "application/json", json.encode(response))
        end

        created_id, issues = entity.create(db_path, v1_type, decoded, author, v1_source)
        response = {issues = issues}
        if created_id != nil then
            response.created_id = created_id
            response.success = true
        else
            response.success = false
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(response))
    end

    if v1_entity_id != nil and v1_action == nil and method == "GET" then
        row = entity.get(db_path, v1_type, v1_entity_id)
        if row == nil then
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "Not found"}))
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({row = row}))
    end

    if v1_entity_id != nil and v1_action == nil and method == "PATCH" then
        if not req.via_api_key and not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        if not web_ctx.require_write_capability(req, v1_type) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end
        values, _, err = json.decode(io.read("*all"))
        if values == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        updated_id, issues = entity.update(db_path, v1_type, v1_entity_id, values, author, v1_source, params.reason)
        response = {issues = issues}
        if updated_id != nil then
            response.updated_id = updated_id
            response.success = true
        else
            response.success = false
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(response))
    end

    if v1_entity_id != nil and v1_action == "archive" and method == "POST" then
        io.read("*all")
        if not req.via_api_key and not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        if not web_ctx.require_write_capability(req, v1_type) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end
        archived_id, issues = entity.archive(db_path, v1_type, v1_entity_id, author, v1_source, params.reason)
        response = {issues = issues}
        if archived_id != nil then
            response.archived_id = archived_id
            response.success = true
        else
            response.success = false
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(response))
    end

    if v1_entity_id != nil and v1_action == "unarchive" and method == "POST" then
        io.read("*all")
        if not req.via_api_key and not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        if not web_ctx.require_write_capability(req, v1_type) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end
        unarchived_id, issues = entity.unarchive(db_path, v1_type, v1_entity_id, author, v1_source)
        response = {issues = issues}
        if unarchived_id != nil then
            response.unarchived_id = unarchived_id
            response.success = true
        else
            response.success = false
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(response))
    end

    return web_ctx.respond(req, "405 Method Not Allowed", "application/json", json.encode({error = "Method not allowed"}))
end

return api_v1_routes
