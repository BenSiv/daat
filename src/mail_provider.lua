-- Outbound mail facade: validates bare addr-spec addresses and builds CR/LF-safe RFC 5322 MIME.
-- Dynamically loads provider.mail_<name>; see doc/decisions/002-provider-facade-tier.md and doc/auth.md.

const config = require("config")

const mail_provider = {}

function mail_provider.name()
    return config.load().mail_provider
end

function mail_provider.load()
    name = mail_provider.name()
    if name == nil then
        return nil, "no mail.provider configured in config.lua"
    end
    ok, mod = pcall(require, "provider.mail_" .. name)
    if ok == false or mod == nil then
        return nil, "could not load mail provider '" .. name .. "': " .. tostring(mod)
    end
    return mod
end

-- Bare addr-spec only (no display name, whitespace, or control chars).
function mail_provider.valid_address(address)
    if type(address) != "string" or string.len(address) > 254 then
        return false
    end
    return string.match(address, "^[%w%.%+%-_']+@[%w%-]+%.[%w%.%-]+$") != nil
end

function header_value(s)
    return string.gsub(tostring(s), "[\r\n]", " ")
end

function mail_provider.build_raw(message, from_address)
    from_name = string.gsub(header_value(message.from_name), "[\"\\]", "")
    body = string.gsub(message.body, "\r?\n", "\r\n")
    return table.concat({
        "From: \"" .. from_name .. "\" <" .. from_address .. ">",
        "To: <" .. message.to .. ">",
        "Subject: " .. header_value(message.subject),
        "Date: " .. os.date("!%a, %d %b %Y %H:%M:%S +0000"),
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: 8bit",
        "",
        body,
    }, "\r\n")
end

function mail_provider.send(message)
    provider, err = mail_provider.load()
    if provider == nil then
        return nil, err
    end
    from_address = config.load().mail_from
    if not mail_provider.valid_address(from_address) then
        return nil, "invalid mail.from in config.lua: " .. tostring(from_address)
    end
    if not mail_provider.valid_address(message.to) then
        return nil, "invalid recipient address"
    end
    message.from_address = from_address
    message.raw = mail_provider.build_raw(message, from_address)
    return provider.send(message)
end

return mail_provider
