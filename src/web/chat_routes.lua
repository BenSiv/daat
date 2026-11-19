-- Chat history browser (/chat) and floating widget JSON API
-- (/api/chat-widget-*).

const config = require("config")
const agent = require("agent")
const document = require("document")
const json = require("dkjson")
const multipart = require("multipart")
const ui = require("ui")
const web_ctx = require("web.context")

const chat_routes = {}

function chat_widget_state(db_path, session_id, viewer_login)
    owner = agent.session_login(db_path, session_id)
    read_only = viewer_login != nil and owner != nil and owner != viewer_login
    running = agent.turn_status(db_path, session_id) == "running"
    messages = agent.all_messages(db_path, session_id, false)
    for _, msg in ipairs(messages) do
        if ui.CHAT_MARKDOWN_ROLES[msg.role] == true then
            msg.content = document.render_markdown(msg.content)
        end
    end
    pending_out = nil
    last_query_sql = nil
    if read_only == false then
        pending = agent.latest_pending(db_path, session_id)
        if pending != nil then
            args, _, _ = json.decode(pending.args_json)
            if args == nil then
                args = {}
            end
            pending_out = {id = pending.id, tool = pending.tool, method = pending.method, args = args}
        end
        last_query_sql = agent.last_console_query_sql(db_path, session_id)
    end
    return {
        session_id = session_id,
        owner = owner,
        read_only = read_only,
        messages = messages,
        pending = pending_out,
        last_query_sql = last_query_sql,
        running = running,
    }
end

function run_chat_turn(db_path, root, session_id, author, user_message)
    if config.load().agent_turn_mode == "inline" then
        agent.run_turn(db_path, session_id, author, nil, agent.default_model(), user_message)
        return
    end
    if user_message != nil and user_message != "" then
        agent.add_message(db_path, session_id, "user", user_message, true)
        agent.maybe_set_title_from_message(db_path, session_id, author, user_message)
    end
    agent.start_detached_turn(db_path, root, session_id)
end

function chat_routes.handle(req)
    path_info = req.path_info
    method = req.method
    db_path = req.db_path
    author = req.author

    if path_info == "/chat" then
        session_id = req.params.session_id
        sessions = agent.list_sessions(db_path, author)
        current_session_id = nil
        viewed_foreign_session = nil
        open_read_only = false
        if session_id != nil and session_id != "" then
            session, access = agent.get_session_for_reader(db_path, session_id, author, req.show_admin_nav)
            if session == nil then
                unavailable_body = ui.render_chat_unavailable()
                return web_ctx.render_page(req, "Chat", "chat", unavailable_body, nil, "404 Not Found")
            end
            current_session_id = session_id
            if access == "admin" then
                viewed_foreign_session = session
                open_read_only = true
            end
        end
        body = ui.render_chat(sessions, current_session_id, req.nonce, viewed_foreign_session)
        page_context = {
            page_type = "chat",
            open_chat_session_id = current_session_id,
            open_chat_read_only = open_read_only,
        }
        return web_ctx.render_page(req, "Chat", "chat", body, page_context)
    end

    if path_info == "/api/chat-widget-start" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        body_data, _, err = json.decode(io.read("*all"))
        if body_data == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        new_session_id, create_err = agent.create_session(db_path, author, body_data.title)
        if new_session_id == nil then
            return web_ctx.respond(req, "500 Internal Server Error", "application/json", json.encode({error = tostring(create_err)}))
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(chat_widget_state(db_path, new_session_id)))
    end

    if path_info == "/api/chat-widget-send" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        body_data, _, err = json.decode(io.read("*all"))
        if body_data == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        if agent.get_session(db_path, body_data.session_id, author) == nil then
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "no such chat session"}))
        end
        if agent.turn_status(db_path, body_data.session_id) == "running" then
            return web_ctx.respond(req, "409 Conflict", "application/json", json.encode({error = "the assistant is still answering the previous message"}))
        end
        run_chat_turn(db_path, req.root, body_data.session_id, author, body_data.message)
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(chat_widget_state(db_path, body_data.session_id)))
    end

    if path_info == "/api/chat-widget-stop" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        body_data, _, err = json.decode(io.read("*all"))
        if body_data == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        if agent.request_cancel(db_path, body_data.session_id, author) == false then
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "no such chat session"}))
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({ok = true}))
    end

    if path_info == "/api/chat-widget-attach" and method == "POST" then
        if config.load().chat_attachments_enabled != true then
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "not found"}))
        end
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        raw_body = io.read("*all")
        if raw_body != nil and string.len(raw_body) > 15 * 1024 * 1024 then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "File too large (max 15MB)."}))
        end
        form = multipart.parse(os.getenv("CONTENT_TYPE"), raw_body)
        uploaded = form.file
        if type(uploaded) != "table" or uploaded.data == nil or uploaded.data == "" then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "No file given."}))
        end
        text, err = document.extract_attachment_text(uploaded.filename, uploaded.data)
        if text == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = err}))
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({text = text, filename = uploaded.filename}))
    end

    if path_info == "/api/chat-widget-approve" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        body_data, _, err = json.decode(io.read("*all"))
        if body_data == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        if agent.get_session(db_path, body_data.session_id, author) == nil then
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "no such chat session"}))
        end
        model = agent.default_model()
        inline = config.load().agent_turn_mode == "inline"
        result = agent.approve_pending(db_path, tonumber(body_data.pending_id), author, nil, model, inline)
        if inline == false and result != nil then
            agent.start_detached_turn(db_path, req.root, result.session_id)
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(chat_widget_state(db_path, body_data.session_id, author)))
    end

    if path_info == "/api/chat-widget-feedback" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        body_data, _, err = json.decode(io.read("*all"))
        if body_data == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        message_id = tonumber(body_data.message_id)
        session_id = agent.message_session_id(db_path, message_id)
        if session_id == nil or agent.get_session(db_path, session_id, author) == nil then
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "no such message"}))
        end
        ok = agent.record_reply_feedback(db_path, message_id, body_data.feedback)
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({ok = ok}))
    end

    if path_info == "/api/chat-widget-deny" and method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        body_data, _, err = json.decode(io.read("*all"))
        if body_data == nil then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        if agent.get_session(db_path, body_data.session_id, author) == nil then
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "no such chat session"}))
        end
        model = agent.default_model()
        inline = config.load().agent_turn_mode == "inline"
        result = agent.deny_pending(db_path, tonumber(body_data.pending_id), author, nil, model, inline, body_data.reason)
        if inline == false and result != nil then
            agent.start_detached_turn(db_path, req.root, result.session_id)
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(chat_widget_state(db_path, body_data.session_id, author)))
    end

    if path_info == "/api/chat-widget-history" then
        session, _ = agent.get_session_for_reader(db_path, req.params.session_id, author, req.show_admin_nav)
        if session == nil then
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "no such chat session"}))
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode(chat_widget_state(db_path, req.params.session_id, author)))
    end

    return false
end

return chat_routes
