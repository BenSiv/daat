-- The seam outbound mail plugs into -- same facade shape as
-- search_provider.lua (see that file's header, and
-- doc/architecture.md's "Providers" section). Loaded dynamically by
-- name (config.platform_config().mail_provider -- no default: nil
-- means this deployment sends no mail at all), so swapping backends or
-- substituting the deterministic test provider is a config change.
--
-- send({to=, from_name=, subject=, body=}) -> (true, err). The facade
-- owns validation and builds the one canonical RFC 5322 message text
-- every backend is handed (message.raw), so header-injection checks
-- live in exactly one place rather than per backend. Implementations
-- live under src/provider/ (mail_smtp.lua, mail_test.lua).

config = require("config")

mail_provider = {}

function mail_provider.name()
    return config.platform_config().mail_provider
end

function mail_provider.load()
    name = mail_provider.name()
    if name == nil then
        return nil, "no mail_provider configured in platform.lua"
    end
    ok, mod = pcall(require, "provider.mail_" .. name)
    if ok == false or mod == nil then
        return nil, "could not load mail provider '" .. name .. "': " .. tostring(mod)
    end
    return mod
end

-- A bare addr-spec only (no display name, no comments): exactly one
-- "@", no whitespace/control characters, nothing that could break out
-- of a header line or a curl --mail-rcpt argument. Deliberately
-- stricter than RFC 5322 allows -- a real user's address fits this,
-- and anything that doesn't is far more likely a mistake or an attack.
function mail_provider.valid_address(address)
    if type(address) != "string" or string.len(address) > 254 then
        return false
    end
    return string.match(address, "^[%w%.%+%-_']+@[%w%-]+%.[%w%.%-]+$") != nil
end

-- Header values we build ourselves (site name, subject) still get CR/LF
-- stripped -- they come from deployment config/code, not a user, but a
-- stray newline in theme.lua's site_name shouldn't be able to forge a
-- header either.
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
    from_address = config.platform_config().mail_from
    if not mail_provider.valid_address(from_address) then
        return nil, "invalid mail_from in platform.lua: " .. tostring(from_address)
    end
    if not mail_provider.valid_address(message.to) then
        return nil, "invalid recipient address"
    end
    message.from_address = from_address
    message.raw = mail_provider.build_raw(message, from_address)
    return provider.send(message)
end

return mail_provider
