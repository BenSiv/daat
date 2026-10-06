-- Microsoft Graph backend for mail_provider.lua's own facade: sends as
-- mail_from through Graph's sendMail, authenticated as an app
-- (OAuth 2.0 client credentials) rather than as a mailbox with a
-- password -- Exchange Online is retiring password (Basic) auth for
-- SMTP, and this needs no SMTP AUTH setting on the mailbox at all.
--
-- platform.lua: graph_tenant_id and graph_client_id (an Entra app
-- registration -- neither is secret); the client secret is
-- PLATFORM_GRAPH_CLIENT_SECRET in the environment, same split as
-- smtp_user/PLATFORM_SMTP_PASSWORD. The app needs the Graph Mail.Send
-- *application* permission, which on its own can send as any mailbox
-- in the tenant -- the tenant admin scopes it to mail_from with
-- Exchange Online RBAC for Applications (or an application access
-- policy). That scoping is the admin's side, not something this code
-- can check.
--
-- The message itself is the facade's own message.raw (RFC 5322),
-- handed to Graph base64-encoded with Content-Type: text/plain --
-- Graph's MIME send -- so headers are built and validated in exactly
-- one place, same as for mail_smtp.lua. The client secret and the
-- bearer token go in curl -K config files, never on the command line.

json = require("dkjson")
external_tool = require("external_tool")
config = require("config")

mail_graph = {}

GRAPH_TIMEOUT_SECONDS = 30
TOKEN_URL_TEMPLATE = "https://login.microsoftonline.com/%s/oauth2/v2.0/token"
SEND_URL_TEMPLATE = "https://graph.microsoft.com/v1.0/users/%s/sendMail"
GRAPH_SCOPE = "https://graph.microsoft.com/.default"

-- curl -K config syntax: a double-quoted value, backslash-escaped.
function curl_config_quote(s)
    return "\"" .. string.gsub(string.gsub(s, "\\", "\\\\"), "\"", "\\\"") .. "\""
end

-- A tenant is a GUID or a domain (celleste-bio.com), a client id a
-- GUID -- either way only letters, digits, "." and "-". Anything else
-- would end up inside the token URL.
function valid_id(s)
    return type(s) == "string" and string.match(s, "^[%w%.%-]+$") != nil
end

-- Splits curl's -w trailer ("\nhttp_status=NNN") off the response body.
function split_status(output)
    status = string.match(output, "http_status=(%d+)%s*$")
    body = string.gsub(output, "\n?http_status=%d+%s*$", "")
    return status, body
end

-- Graph/Entra error bodies: {"error": {"code", "message"}} from Graph,
-- {"error", "error_description"} from the token endpoint.
function error_detail(body)
    parsed = json.decode(body)
    if type(parsed) != "table" then
        return string.sub(body, 1, 300)
    end
    if type(parsed.error) == "table" then
        return tostring(parsed.error.code) .. ": " .. tostring(parsed.error.message)
    end
    if parsed.error_description != nil then
        return tostring(parsed.error) .. ": " .. tostring(parsed.error_description)
    end
    return string.sub(body, 1, 300)
end

-- -> (access_token, err)
function mail_graph.token(conf, secret)
    curl_config = table.concat({
        "url = " .. curl_config_quote(string.format(TOKEN_URL_TEMPLATE, conf.graph_tenant_id)),
        "data-urlencode = " .. curl_config_quote("grant_type=client_credentials"),
        "data-urlencode = " .. curl_config_quote("client_id=" .. conf.graph_client_id),
        "data-urlencode = " .. curl_config_quote("client_secret=" .. secret),
        "data-urlencode = " .. curl_config_quote("scope=" .. GRAPH_SCOPE),
    }, "\n") .. "\n"
    return external_tool.with_temp_file(curl_config, "w", function(config_path)
        cmd = "curl -sS --max-time " .. tostring(GRAPH_TIMEOUT_SECONDS) ..
            " -K " .. external_tool.shell_quote(config_path) ..
            " -w '\\nhttp_status=%{http_code}' 2>&1"
        output, _ = external_tool.capture(cmd)
        if output == nil then
            return nil, "no response from the Microsoft token endpoint (is curl installed?)"
        end
        status, body = split_status(output)
        parsed = json.decode(body)
        if status == "200" and type(parsed) == "table" and type(parsed.access_token) == "string" then
            return parsed.access_token
        end
        return nil, "Graph token request failed (HTTP " .. tostring(status) .. "): " .. error_detail(body)
    end)
end

function mail_graph.send(message)
    -- This backend's own platform.lua settings (config.setting).
    conf = {graph_tenant_id = config.setting("graph_tenant_id"), graph_client_id = config.setting("graph_client_id")}
    if not valid_id(conf.graph_tenant_id) then
        return nil, "graph_tenant_id is not set (or invalid) in platform.lua"
    end
    if not valid_id(conf.graph_client_id) then
        return nil, "graph_client_id is not set (or invalid) in platform.lua"
    end
    secret = os.getenv("PLATFORM_GRAPH_CLIENT_SECRET")
    if secret == nil or secret == "" then
        return nil, "PLATFORM_GRAPH_CLIENT_SECRET is not set"
    end

    token, token_err = mail_graph.token(conf, secret)
    if token == nil then
        return nil, token_err
    end

    -- message.from_address already passed mail_provider.valid_address,
    -- so it's safe as a URL path segment.
    curl_config = table.concat({
        "url = " .. curl_config_quote(string.format(SEND_URL_TEMPLATE, message.from_address)),
        "header = " .. curl_config_quote("Authorization: Bearer " .. token),
        "header = " .. curl_config_quote("Content-Type: text/plain"),
    }, "\n") .. "\n"
    return external_tool.with_temp_file(message.raw, "wb", function(message_path)
        return external_tool.with_temp_file(curl_config, "w", function(config_path)
            cmd = "base64 -w0 " .. external_tool.shell_quote(message_path) ..
                " | curl -sS --max-time " .. tostring(GRAPH_TIMEOUT_SECONDS) ..
                " -K " .. external_tool.shell_quote(config_path) ..
                " --data-binary @-" ..
                " -w '\\nhttp_status=%{http_code}' 2>&1"
            output, _ = external_tool.capture(cmd)
            if output == nil then
                return nil, "no response from Microsoft Graph (is curl installed?)"
            end
            status, body = split_status(output)
            -- sendMail answers 202 Accepted with an empty body.
            if status == "202" then
                return true
            end
            return nil, "Graph sendMail failed (HTTP " .. tostring(status) .. "): " .. error_detail(body)
        end)
    end)
end

return mail_graph
