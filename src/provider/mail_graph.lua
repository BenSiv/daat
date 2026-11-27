-- Microsoft Graph sendMail provider (OAuth 2.0 client_credentials + base64 MIME; see doc/auth.md).
-- Secrets and bearer tokens pass via 0600 curl -K temp files, never argv.

const json = require("dkjson")
const external_tool = require("external_tool")
const config = require("config")

const mail_graph = {}

const GRAPH_TIMEOUT_SECONDS = 30
const TOKEN_URL_TEMPLATE = "https://login.microsoftonline.com/%s/oauth2/v2.0/token"
const SEND_URL_TEMPLATE = "https://graph.microsoft.com/v1.0/users/%s/sendMail"
const GRAPH_SCOPE = "https://graph.microsoft.com/.default"

function curl_config_quote(s)
    return "\"" .. string.gsub(string.gsub(s, "\\", "\\\\"), "\"", "\\\"") .. "\""
end

-- Restricts tenant/client IDs before interpolating into the token URL.
function valid_id(s)
    return type(s) == "string" and string.match(s, "^[%w%.%-]+$") != nil
end

function split_status(output)
    status = string.match(output, "http_status=(%d+)%s*$")
    body = string.gsub(output, "\n?http_status=%d+%s*$", "")
    return status, body
end

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
    conf = {graph_tenant_id = config.setting("graph_tenant_id"), graph_client_id = config.setting("graph_client_id")}
    if not valid_id(conf.graph_tenant_id) then
        return nil, "mail.graph_tenant_id is not set (or invalid) in config.lua"
    end
    if not valid_id(conf.graph_client_id) then
        return nil, "mail.graph_client_id is not set (or invalid) in config.lua"
    end
    secret = os.getenv("DAAT_GRAPH_CLIENT_SECRET")
    if secret == nil or secret == "" then
        return nil, "DAAT_GRAPH_CLIENT_SECRET is not set"
    end

    token, token_err = mail_graph.token(conf, secret)
    if token == nil then
        return nil, token_err
    end

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
            if status == "202" then
                return true
            end
            return nil, "Graph sendMail failed (HTTP " .. tostring(status) .. "): " .. error_detail(body)
        end)
    end)
end

return mail_graph
