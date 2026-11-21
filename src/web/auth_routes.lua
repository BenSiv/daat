-- Unauthenticated login/password-reset/email-verification routes and
-- authenticated /logout + /account routes.

const config = require("config")
const auth = require("auth")
const view = require("view")
const ui = require("ui")
const web_ctx = require("web.context")

const auth_routes = {}

function handle_login(req)
    has_tasks_view = view.load(req.db_path, "prioritized_tasks", req.root) != nil
    show_forgot_link = config.password_reset_enabled()

    if req.method == "POST" then
        body = web_ctx.read_body()
        form = web_ctx.parse_query(body)
        cap, _ = auth.login(req.db_path, form.login, form.password)
        if cap == nil then
            body_html = ui.render_login("Invalid login or password.", req.nonce, show_forgot_link, nil)
            return web_ctx.render_public_page(req, "Log in", body_html, has_tasks_view, "401 Unauthorized")
        end

        session_cookie, cookie_err = auth.issue_session_cookie(req.root, req.db_path, form.login)
        if session_cookie == nil then
            return web_ctx.error_html(req, "500 Internal Server Error", cookie_err)
        end
        csrf_token, csrf_err = auth.generate_csrf_token()
        if csrf_token == nil then
            return web_ctx.error_html(req, "500 Internal Server Error", csrf_err)
        end

        return web_ctx.respond(req, "302 Found", "text/plain", "", {
            "Location: /",
            web_ctx.set_cookie_header("session", session_cookie, auth.SESSION_TTL_SECONDS, true),
            web_ctx.set_cookie_header("csrf", csrf_token, auth.SESSION_TTL_SECONDS, false),
        })
    end

    notice = nil
    if req.params.reset == "1" then
        notice = "Password updated. Log in with your new password."
    elseif req.params.verified == "1" then
        notice = "Email confirmed."
    end
    body_html = ui.render_login(nil, req.nonce, show_forgot_link, notice)
    return web_ctx.render_public_page(req, "Log in", body_html, has_tasks_view)
end

function handle_forgot_password(req)
    if not config.password_reset_enabled() then
        return web_ctx.respond(req, "404 Not Found", "text/plain", "")
    end
    has_tasks_view = view.load(req.db_path, "prioritized_tasks", req.root) != nil

    sent = false
    if req.method == "POST" then
        form = web_ctx.parse_query(web_ctx.read_body())
        result, err = auth.request_password_reset(req.root, req.db_path, form.identifier, req.theme.site_name)
        if result == nil then
            io.write(io.stderr, "forgot-password: could not send reset email: " .. tostring(err) .. "\n")
        end
        sent = true
    end
    body_html = ui.render_forgot_password(nil, sent)
    return web_ctx.render_public_page(req, "Forgot password", body_html, has_tasks_view)
end

function handle_reset_password(req)
    if not config.password_reset_enabled() then
        return web_ctx.respond(req, "404 Not Found", "text/plain", "")
    end
    has_tasks_view = view.load(req.db_path, "prioritized_tasks", req.root) != nil
    headers = {"Referrer-Policy: no-referrer", "Cache-Control: no-store"}

    token = nil
    error_message = nil
    invalid = false
    if req.method == "POST" then
        form = web_ctx.parse_query(web_ctx.read_body())
        token = form.token
        if auth.check_password_reset(req.root, req.db_path, token) == nil then
            invalid = true
        elseif web_ctx.default_value(form.new_password, "") != web_ctx.default_value(form.confirm_password, "") then
            error_message = "The two passwords don't match."
        else
            login, err = auth.complete_password_reset(req.root, req.db_path, token, form.new_password)
            if login != nil then
                return web_ctx.respond(req, "302 Found", "text/plain", "", {"Location: /login?reset=1", "Referrer-Policy: no-referrer"})
            end
            error_message = err
        end
    end

    body_html = ui.render_reset_password(token, error_message, invalid, req.nonce)
    return web_ctx.render_public_page(req, "Reset password", body_html, has_tasks_view, "200 OK", headers)
end

function handle_verify_email(req)
    if not config.password_reset_enabled() then
        return web_ctx.respond(req, "404 Not Found", "text/plain", "")
    end
    has_tasks_view = view.load(req.db_path, "prioritized_tasks", req.root) != nil
    headers = {"Referrer-Policy: no-referrer", "Cache-Control: no-store"}

    token = nil
    error_message = nil
    invalid = false
    if req.method == "POST" then
        form = web_ctx.parse_query(web_ctx.read_body())
        token = form.token
        if auth.check_email_verification(req.root, req.db_path, token) == nil then
            invalid = true
        else
            login, err = auth.complete_email_verification(req.root, req.db_path, token, form.password)
            if login != nil then
                return web_ctx.respond(req, "302 Found", "text/plain", "", {"Location: /login?verified=1", "Referrer-Policy: no-referrer"})
            end
            error_message = err
        end
    end

    body_html = ui.render_verify_email(token, error_message, invalid, req.nonce)
    return web_ctx.render_public_page(req, "Confirm email", body_html, has_tasks_view, "200 OK", headers)
end

function auth_routes.handle_public(req)
    if req.path_info == "/login" then
        return handle_login(req)
    end
    if req.path_info == "/forgot-password" then
        return handle_forgot_password(req)
    end
    if req.path_info == "/reset-password" then
        return handle_reset_password(req)
    end
    if req.path_info == "/verify-email" then
        return handle_verify_email(req)
    end
    return false
end

function auth_routes.handle(req)
    if req.path_info == "/account" then
        account_user = auth.get_user(req.db_path, req.author)
        csrf_val = web_ctx.default_value(req.cookies.csrf, "")
        if req.method == "POST" then
            form = web_ctx.parse_query(web_ctx.read_body())
            if not web_ctx.require_csrf(req, form.csrf_token) then
                body = ui.render_account(req.author, account_user, csrf_val, "CSRF check failed.", true)
                return web_ctx.render_page(req, "Account", "", body, nil, "403 Forbidden")
            end
            if auth.login(req.db_path, req.author, web_ctx.default_value(form.current_password, "")) == nil then
                body = ui.render_account(req.author, account_user, csrf_val, "Current password is incorrect.", true)
                return web_ctx.render_page(req, "Account", "", body)
            end
            ok, err = auth.set_password(req.db_path, req.author, form.new_password)
            if ok == nil then
                body = ui.render_account(req.author, account_user, csrf_val, tostring(err), true)
                return web_ctx.render_page(req, "Account", "", body)
            end
            body = ui.render_account(req.author, account_user, csrf_val,
                "Password changed. Any other sessions for this account have been logged out.", false)
            return web_ctx.render_page(req, "Account", "", body, nil, "200 OK",
                web_ctx.fresh_session_cookie_headers(req.root, req.db_path, req.author))
        end
        body = ui.render_account(req.author, account_user, csrf_val, nil, false)
        return web_ctx.render_page(req, "Account", "", body)
    end
    return false
end

function auth_routes.handle_api_v1(req)
    path_info = req.path_info
    method = req.method

    if path_info == "/api/v1/account" then
        if method != "GET" then
            return web_ctx.method_not_allowed(req)
        end
        payload = {
            author = req.author,
            capabilities = req.capabilities,
            via_api_key = req.via_api_key,
            login = nil,
            email = nil,
            email_verified = false,
        }
        if req.via_api_key == false then
            account_user = auth.get_user(req.db_path, req.author)
            payload.login = req.author
            if account_user != nil then
                payload.email = account_user.email
                payload.email_verified = auth.email_verified(account_user)
            end
        end
        return web_ctx.respond_json(req, "200 OK", payload)
    end

    if path_info == "/api/v1/account/password" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        body_data, ok_body = web_ctx.read_write_json(req, false)
        if not ok_body then
            return true
        end
        if req.via_api_key == true then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "Password change requires a user session"})
        end
        if auth.login(req.db_path, req.author, web_ctx.default_value(body_data.current_password, "")) == nil then
            return web_ctx.respond_json(req, "403 Forbidden", {error = "Current password is incorrect."})
        end
        ok, err = auth.set_password(req.db_path, req.author, body_data.new_password)
        if ok == nil then
            return web_ctx.respond_json(req, "400 Bad Request", {error = tostring(err)})
        end
        cookie_headers = web_ctx.fresh_session_cookie_headers(req.root, req.db_path, req.author)
        return web_ctx.respond_json(req, "200 OK", {success = true}, cookie_headers)
    end

    return false
end

return auth_routes
