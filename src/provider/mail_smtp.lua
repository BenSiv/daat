-- SMTP backend for mail_provider.lua's own facade, via a curl shell-out
-- (curl speaks SMTP natively -- no new binary in the image, same
-- external_tool.lua pattern every other outbound call here uses).
--
-- platform.lua: smtp_url (e.g. "smtp://smtp.gmail.com:587" or
-- "smtps://host:465") and optional smtp_user; the password is
-- PLATFORM_SMTP_PASSWORD in the environment (PassEnv'd the same way
-- PLATFORM_MARIADB_PASSWORD is). No smtp_user means no AUTH at all --
-- an IP-allowlisted relay. TLS is always required (--ssl-reqd:
-- STARTTLS on smtp://, implicit on smtps://), never silently
-- downgraded to plaintext.
--
-- The credentials go in a curl -K config file (os.tmpname -> 0600),
-- never on the command line, where any local `ps` could read them.

external_tool = require("external_tool")
config = require("config")

mail_smtp = {}

SMTP_TIMEOUT_SECONDS = 30

-- curl -K config syntax: a double-quoted value, backslash-escaped.
function curl_config_quote(s)
    return "\"" .. string.gsub(string.gsub(s, "\\", "\\\\"), "\"", "\\\"") .. "\""
end

function mail_smtp.send(message)
    conf = config.platform_config()
    if conf.smtp_url == nil then
        return nil, "smtp_url is not set in platform.lua"
    end

    curl_config = ""
    if conf.smtp_user != nil then
        password = os.getenv("PLATFORM_SMTP_PASSWORD")
        if password == nil or password == "" then
            return nil, "PLATFORM_SMTP_PASSWORD is not set"
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
