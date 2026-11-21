-- Chat history browser (/chat) and /api/v1/chat/* JSON endpoints.

const config = require("config")
const agent = require("agent")
const document = require("document")
const json = require("dkjson")
const multipart = require("multipart")
const ui = require("ui")
const web_ctx = require("web.context")

const chat_routes = {}

function chat_session_state(db_path, session_id, viewer_login)
    owner = agent.session_login(db_path, session_id)
    read_only = viewer_login != nil and owner != nil and owner != viewer_login
    running = agent.turn_status(db_path, session_id) == "running"
    messages = agent.all_messages(db_path, session_id, false)
    for _, msg in ipairs(messages) do
        if ui.CHAT_MARKDOWN_ROLES[msg.role] == true then
            msg.content_html = document.render_markdown(msg.content)
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
        messages = web_ctx.as_json_array(messages),
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

    return false
end

function chat_routes.handle_api_v1(req)
    path_info = req.path_info
    method = req.method
    db_path = req.db_path
    author = req.author

    if path_info == "/api/v1/chat/sessions" then
        if method == "GET" then
            sessions = agent.list_sessions(db_path, author)
            return web_ctx.respond_json(req, "200 OK", {sessions = web_ctx.as_json_array(sessions)})
        end
        if method == "POST" then
            body_data, ok_body = web_ctx.read_write_json(req, true)
            if not ok_body then
                return true
            end
            new_session_id, create_err = agent.create_session(db_path, author, body_data.title)
            if new_session_id == nil then
                return web_ctx.respond_json(req, "500 Internal Server Error", {error = tostring(create_err)})
            end
            return web_ctx.respond_json(req, "200 OK", chat_session_state(db_path, new_session_id, author))
        end
        web_ctx.read_body()
        return web_ctx.method_not_allowed(req)
    end

    if path_info == "/api/v1/chat/attachments/extract" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        raw_body = web_ctx.read_body()
        if config.load().chat_attachments_enabled != true then
            return web_ctx.respond_json(req, "404 Not Found", {error = "not found"})
        end
        if not web_ctx.require_write_auth(req) then
            return true
        end
        if raw_body != nil and string.len(raw_body) > 15 * 1024 * 1024 then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "File too large (max 15MB)."})
        end
        form = multipart.parse(os.getenv("CONTENT_TYPE"), raw_body)
        uploaded = form.file
        if type(uploaded) != "table" or uploaded.data == nil or uploaded.data == "" then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "No file given."})
        end
        text, err = document.extract_attachment_text(uploaded.filename, uploaded.data)
        if text == nil then
            return web_ctx.respond_json(req, "400 Bad Request", {error = err})
        end
        return web_ctx.respond_json(req, "200 OK", {text = text, filename = uploaded.filename})
    end

    msg_id_str = string.match(path_info, "^/api/v1/chat/messages/(%d+)/feedback$")
    if msg_id_str != nil then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        body_data, ok_body = web_ctx.read_write_json(req, false)
        if not ok_body then
            return true
        end
        message_id = tonumber(msg_id_str)
        session_id = agent.message_session_id(db_path, message_id)
        if session_id == nil or agent.get_session(db_path, session_id, author) == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "no such message"})
        end
        ok = agent.record_reply_feedback(db_path, message_id, body_data.feedback)
        return web_ctx.respond_json(req, "200 OK", {ok = ok})
    end

    sid_raw, action = string.match(path_info, "^/api/v1/chat/sessions/([^/]+)/([a-z]+)$")
    if sid_raw == nil then
        sid_raw = string.match(path_info, "^/api/v1/chat/sessions/([^/]+)$")
    end
    if sid_raw == nil then
        return false
    end
    sid = web_ctx.percent_decode(sid_raw)

    if action == nil then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        session, _ = agent.get_session_for_reader(db_path, sid, author, req.show_admin_nav)
        if session == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "no such chat session"})
        end
        return web_ctx.respond_json(req, "200 OK", chat_session_state(db_path, sid, author))
    end

    if action == "messages" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        body_data, ok_body = web_ctx.read_write_json(req, false)
        if not ok_body then
            return true
        end
        if agent.get_session(db_path, sid, author) == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "no such chat session"})
        end
        if agent.turn_status(db_path, sid) == "running" then
            return web_ctx.respond_json(req, "409 Conflict", {error = "the assistant is still answering the previous message"})
        end
        run_chat_turn(db_path, req.root, sid, author, body_data.message)
        return web_ctx.respond_json(req, "200 OK", chat_session_state(db_path, sid, author))
    end

    if action == "stop" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        _, ok_body = web_ctx.read_write_json(req, true)
        if not ok_body then
            return true
        end
        if agent.request_cancel(db_path, sid, author) == false then
            return web_ctx.respond_json(req, "404 Not Found", {error = "no such chat session"})
        end
        return web_ctx.respond_json(req, "200 OK", {ok = true})
    end

    if action == "approve" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        body_data, ok_body = web_ctx.read_write_json(req, false)
        if not ok_body then
            return true
        end
        if agent.get_session(db_path, sid, author) == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "no such chat session"})
        end
        model = agent.default_model()
        inline = config.load().agent_turn_mode == "inline"
        result = agent.approve_pending(db_path, tonumber(body_data.pending_id), author, nil, model, inline)
        if inline == false and result != nil then
            agent.start_detached_turn(db_path, req.root, result.session_id)
        end
        return web_ctx.respond_json(req, "200 OK", chat_session_state(db_path, sid, author))
    end

    if action == "deny" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        body_data, ok_body = web_ctx.read_write_json(req, false)
        if not ok_body then
            return true
        end
        if agent.get_session(db_path, sid, author) == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "no such chat session"})
        end
        model = agent.default_model()
        inline = config.load().agent_turn_mode == "inline"
        result = agent.deny_pending(db_path, tonumber(body_data.pending_id), author, nil, model, inline, body_data.reason)
        if inline == false and result != nil then
            agent.start_detached_turn(db_path, req.root, result.session_id)
        end
        return web_ctx.respond_json(req, "200 OK", chat_session_state(db_path, sid, author))
    end

    return false
end

return chat_routes
