-- Dispatches /api/v1/* requests across domain route modules; unmatched paths return JSON 404.

const auth_routes = require("web.auth_routes")
const entity_routes = require("web.entity_routes")
const knowledge_routes = require("web.knowledge_routes")
const chat_routes = require("web.chat_routes")
const admin_routes = require("web.admin_routes")
const web_ctx = require("web.context")

const api_v1_routes = {}

const API_V1_MODULES = {
    auth_routes,
    entity_routes,
    knowledge_routes,
    chat_routes,
    admin_routes,
}

function api_v1_routes.handle(req)
    path_info = req.path_info
    if path_info != "/api/v1" and string.sub(path_info, 1, 8) != "/api/v1/" then
        return false
    end

    for _, mod in ipairs(API_V1_MODULES) do
        if mod.handle_api_v1(req) == true then
            return true
        end
    end

    if req.method != "GET" and req.method != "HEAD" then
        web_ctx.read_body()
    end
    return web_ctx.respond_json(req, "404 Not Found", {error = "Unknown API endpoint: " .. path_info})
end

return api_v1_routes
