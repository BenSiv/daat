-- SMTP mail provider via curl (--ssl-reqd enforced; credentials in 0600 curl -K file; see doc/auth.md).

const external_tool = require("external_tool")
const config = require("config")

const mail_smtp = {}

const SMTP_TIMEOUT_SECONDS = 30

function curl_config_quote(s)
    return "\"" .. string.gsub(string.gsub(s, "\\", "\\\\"), "\"", "\\\"") .. "\""
end

function mail_smtp.send(message)
    conf = {}
    for _, key in ipairs({"smtp_url", "smtp_user"}) do
        if type(config.setting(key)) == "string" then
            conf[key] = config.setting(key)
        end
    end
    if conf.smtp_url == nil then
        return nil, "mail.smtp_url is not set in config.lua"
    end

    curl_config = ""
    if conf.smtp_user != nil then
        password = os.getenv("DAAT_SMTP_PASSWORD")
        if password == nil or password == "" then
            return nil, "DAAT_SMTP_PASSWORD is not set"
        end
        curl_config = "user = " .. curl_config_quote(conf.smtp_user .. ":" .. password) .. "\n"
    end

    return external_tool.with_temp_file(message.raw, "wb", function(message_path)
        return external_tool.with_temp_file(curl_config, "w", function(config_path)
            cmd = "curl -sS --max-time " .. tostring(SMTP_TIMEOUT_SECONDS) .. " --ssl-reqd" ..
                " --url " .. external_tool.shell_quote(conf.smtp_url) ..
                " --mail-from " .. external_tool.shell_quote(message.from_address) ..
                " --mail-rcpt " .. external_tool.shell_quote(message.to) ..
                " --upload-file " .. external_tool.shell_quote(message_path) ..
                " -K " .. external_tool.shell_quote(config_path) ..
                " 2>&1; printf '\\ncurl_exit=%s' \"$?\""
            output, _ = external_tool.capture(cmd)
            if output == nil then
                return nil, "no response from curl (is it installed?)"
            end
            exit_code = string.match(output, "curl_exit=(%d+)%s*$")
            if exit_code == "0" then
                return true
            end
            detail = string.gsub(string.gsub(output, "\n?curl_exit=%d+%s*$", ""), "^%s+", "")
            return nil, "SMTP send failed (curl exit " .. tostring(exit_code) .. "): " .. detail
        end)
    end)
end

return mail_smtp
