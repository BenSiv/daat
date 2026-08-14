-- Real login/session auth, replacing cgi.lua's Phase 0
-- AUTH_USER/AUTH_CAPABILITIES/AUTH_NONCE env-var stub.
--
-- Password storage: bcrypt (require("bcrypt"), luam/lib/bcrypt/bcrypt.c).
-- Session cookies: stateless, not server-side session rows -- the
-- cookie itself is "<login>.<expiry_unix>.<hmac_hex>", verified with
-- require("hmac").sha256 keyed by a per-store secret generated once at
-- init (config.session_secret_path) and never transmitted. Capabilities
-- are deliberately NOT embedded in the cookie: they're looked up fresh
-- from the user table on every request, so a capability change or
-- archive takes effect on the user's very next request rather than
-- only after their session cookie expires.
-- CSRF: a separate, unsigned random token, double-submitted (cookie +
-- request field/header must match) -- doesn't need HMAC signing since
-- it's only ever compared to itself, not decoded or trusted alone.

db = require("db")
paths = require("paths")
bcrypt = require("bcrypt")
hmac = require("hmac")

auth = {}

SESSION_TTL_SECONDS = 60 * 60 * 24 * 7 -- 7 days

auth.SCHEMA = """
-- VARCHAR(255), not TEXT -- MariaDB/InnoDB refuses a bare TEXT column
-- as a key without an explicit length; see ledger.lua's own SCHEMA
-- comment for the full reasoning.
CREATE TABLE IF NOT EXISTS user (
    login VARCHAR(255) PRIMARY KEY,
    password_hash TEXT NOT NULL,
    -- VARCHAR(32), not TEXT -- see extension.lua's extension_job.status
    -- for why: real MySQL 8.0 rejects a literal DEFAULT on TEXT columns.
    cap VARCHAR(32) NOT NULL DEFAULT '',
    created_at TEXT DEFAULT (%s),
    archived_at TEXT
);

-- External-integration auth, independent of any human user -- a key's
-- capabilities are its own, not derived from whoever created it (see
-- doc/architecture.md's "Auth" section). `label` (not a synthetic id)
-- is the primary key, same convention as user.login -- an
-- operator-chosen, human-meaningful, unique name.
CREATE TABLE IF NOT EXISTS api_key (
    label VARCHAR(255) PRIMARY KEY,
    key_hash TEXT NOT NULL,
    cap VARCHAR(32) NOT NULL DEFAULT '',
    created_at TEXT DEFAULT (%s),
    archived_at TEXT
);
"""

function auth.init_schema(db_path)
    return db.exec(db_path, string.format(auth.SCHEMA, db.now_expr(db_path), db.now_expr(db_path)))
end

-- A per-store HMAC secret, generated once from /dev/urandom and never
-- rotated automatically (rotating it invalidates every outstanding
-- session cookie, so that's an explicit operator action, not implicit
-- request-time behavior).
function auth.ensure_session_secret(root)
    config = require("config")
    path = config.session_secret_path(root)
    if paths.file_exists(path) then
        return true
    end

    urandom = io.open("/dev/urandom", "rb")
    if urandom == nil then
        return nil, "cannot open /dev/urandom"
    end
    raw = io.read(urandom, 32)
    io.close(urandom)
    if raw == nil or string.len(raw) != 32 then
        return nil, "short read from /dev/urandom"
    end

    secret = hex_encode(raw)
    file = io.open(path, "w")
    if file == nil then
        return nil, "cannot create session secret file: " .. path
    end
    io.write(file, secret)
    io.close(file)
    return true
end

function auth.session_secret(root)
    config = require("config")
    path = config.session_secret_path(root)
    file = io.open(path, "r")
    if file == nil then
        return nil, "no session secret at " .. path .. " -- run 'daat init' first"
    end
    secret = io.read(file, "*all")
    io.close(file)
    return secret
end

function hex_encode(bytes)
    hex = {}
    for i = 1, string.len(bytes) do
        table.insert(hex, string.format("%02x", string.byte(bytes, i)))
    end
    return table.concat(hex)
end

function random_hex_token(num_bytes)
    urandom = io.open("/dev/urandom", "rb")
    if urandom == nil then
        return nil, "cannot open /dev/urandom"
    end
    raw = io.read(urandom, num_bytes)
    io.close(urandom)
    if raw == nil or string.len(raw) != num_bytes then
        return nil, "short read from /dev/urandom"
    end
    return hex_encode(raw)
end

-- Not a full constant-time comparison across arbitrary lengths (Lua's
-- string library gives no cheaper primitive), but both inputs here are
-- always fixed-length hex digests/tokens, so length itself leaks
-- nothing an attacker doesn't already know.
function constant_time_equal(a, b)
    if string.len(a) != string.len(b) then
        return false
    end
    diff = 0
    for i = 1, string.len(a) do
        if string.byte(a, i) != string.byte(b, i) then
            diff = diff + 1
        end
    end
    return diff == 0
end

--------------------------------------------------------------------------
-- User management
--------------------------------------------------------------------------

function auth.create_user(db_path, login, password, cap)
    if login == nil or login == "" then
        return nil, "login is required"
    end
    -- Session cookies encode "<login>.<expiry>.<sig>" with "." as the
    -- field separator, so a login containing "." would make its own
    -- cookie unparseable.
    if string.find(login, ".", 1, true) != nil then
        return nil, "login cannot contain '.'"
    end
    if password == nil or password == "" then
        return nil, "password is required"
    end
    if cap == nil then
        cap = ""
    end

    existing = auth.get_user(db_path, login)
    if existing != nil then
        return nil, "user already exists: " .. login
    end

    hash = bcrypt.hash(password, 12)
    db.exec(db_path, string.format(
        "INSERT INTO user (login, password_hash, cap) VALUES (%s, %s, %s);",
        db.quote(login), db.quote(hash), db.quote(cap)
    ))
    return login
end

function auth.get_user(db_path, login)
    rows = db.query(db_path, string.format(
        "SELECT * FROM user WHERE login = %s;", db.quote(login)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function auth.list_users(db_path, include_archived)
    q = "SELECT login, cap, created_at, archived_at FROM user"
    if include_archived != true then
        q = q .. " WHERE archived_at IS NULL"
    end
    q = q .. " ORDER BY login ASC;"
    rows = db.query(db_path, q)
    if rows == nil then
        return {}
    end
    return rows
end

function auth.set_password(db_path, login, password)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    hash = bcrypt.hash(password, 12)
    db.exec(db_path, string.format(
        "UPDATE user SET password_hash = %s WHERE login = %s;", db.quote(hash), db.quote(login)
    ))
    return true
end

function auth.set_capabilities(db_path, login, cap)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    db.exec(db_path, string.format(
        "UPDATE user SET cap = %s WHERE login = %s;", db.quote(cap), db.quote(login)
    ))
    return true
end

-- Archive/unarchive, not delete -- same nullable-timestamp convention
-- as entity.lua's archived_at, so a login can never be silently wiped;
-- an archived user just can no longer authenticate (see auth.login).
function auth.archive_user(db_path, login)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    db.exec(db_path, string.format(
        "UPDATE user SET archived_at = %s WHERE login = %s;", db.now_expr(db_path), db.quote(login)
    ))
    return true
end

function auth.unarchive_user(db_path, login)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    db.exec(db_path, string.format(
        "UPDATE user SET archived_at = NULL WHERE login = %s;", db.quote(login)
    ))
    return true
end

--------------------------------------------------------------------------
-- API keys
--------------------------------------------------------------------------

-- auth.create_api_key(db_path, label, cap) -> raw_key_string | nil, err
-- Returns the raw key exactly once -- only its bcrypt hash is ever
-- stored, the same guarantee password_hash gives for user passwords.
function auth.create_api_key(db_path, label, cap)
    if label == nil or label == "" then
        return nil, "label is required"
    end
    if cap == nil then
        cap = ""
    end

    existing = auth.get_api_key(db_path, label)
    if existing != nil then
        return nil, "api key already exists: " .. label
    end

    raw_key, err = random_hex_token(32)
    if raw_key == nil then
        return nil, err
    end
    hash = bcrypt.hash(raw_key, 12)
    db.exec(db_path, string.format(
        "INSERT INTO api_key (label, key_hash, cap) VALUES (%s, %s, %s);",
        db.quote(label), db.quote(hash), db.quote(cap)
    ))
    return raw_key
end

function auth.get_api_key(db_path, label)
    rows = db.query(db_path, string.format(
        "SELECT * FROM api_key WHERE label = %s;", db.quote(label)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function auth.list_api_keys(db_path, include_archived)
    q = "SELECT label, cap, created_at, archived_at FROM api_key"
    if include_archived != true then
        q = q .. " WHERE archived_at IS NULL"
    end
    q = q .. " ORDER BY label ASC;"
    rows = db.query(db_path, q)
    if rows == nil then
        return {}
    end
    return rows
end

function auth.set_api_key_capabilities(db_path, label, cap)
    key = auth.get_api_key(db_path, label)
    if key == nil then
        return nil, "no such api key: " .. label
    end
    db.exec(db_path, string.format(
        "UPDATE api_key SET cap = %s WHERE label = %s;", db.quote(cap), db.quote(label)
    ))
    return true
end

-- Archive/unarchive, not delete -- same convention as archive_user; an
-- archived key just can no longer authenticate (see auth.verify_api_key).
function auth.archive_api_key(db_path, label)
    key = auth.get_api_key(db_path, label)
    if key == nil then
        return nil, "no such api key: " .. label
    end
    db.exec(db_path, string.format(
        "UPDATE api_key SET archived_at = %s WHERE label = %s;", db.now_expr(db_path), db.quote(label)
    ))
    return true
end

function auth.unarchive_api_key(db_path, label)
    key = auth.get_api_key(db_path, label)
    if key == nil then
        return nil, "no such api key: " .. label
    end
    db.exec(db_path, string.format(
        "UPDATE api_key SET archived_at = NULL WHERE label = %s;", db.quote(label)
    ))
    return true
end

-- auth.verify_api_key(db_path, raw_key) -> api_key_row | nil
-- The key is hashed, so (unlike auth.login, which looks up a known
-- login) there's no indexed lookup by value -- every active row's hash
-- is checked in turn. Fine at this platform's real scale (a small
-- number of trusted integrations, not a public API).
function auth.verify_api_key(db_path, raw_key)
    if raw_key == nil or raw_key == "" then
        return nil
    end
    rows = db.query(db_path, "SELECT * FROM api_key WHERE archived_at IS NULL;")
    if rows == nil then
        return nil
    end
    for _, row in ipairs(rows) do
        if bcrypt.verify(raw_key, row.key_hash) then
            return row
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- Login + session cookies
--------------------------------------------------------------------------

-- auth.login(db_path, login, password) -> cap_string | nil, err_string
function auth.login(db_path, login, password)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "invalid login or password"
    end
    if user.archived_at != nil and user.archived_at != "" then
        return nil, "invalid login or password"
    end
    if not bcrypt.verify(password, user.password_hash) then
        return nil, "invalid login or password"
    end
    return user.cap
end

function cookie_signature(secret, login, expiry)
    return hmac.sha256(secret, login .. "." .. tostring(expiry))
end

-- auth.issue_session_cookie(root, login) -> cookie_value_string | nil, err
function auth.issue_session_cookie(root, login)
    secret, err = auth.session_secret(root)
    if secret == nil then
        return nil, err
    end
    expiry = os.time() + SESSION_TTL_SECONDS
    sig = cookie_signature(secret, login, expiry)
    return login .. "." .. tostring(expiry) .. "." .. sig
end

-- auth.verify_session_cookie(root, cookie_value) -> login_string | nil, err
function auth.verify_session_cookie(root, cookie_value)
    if cookie_value == nil or cookie_value == "" then
        return nil, "no session cookie"
    end
    secret, err = auth.session_secret(root)
    if secret == nil then
        return nil, err
    end

    login, expiry_str, sig = string.match(cookie_value, "^(.-)%.(%d+)%.(%x+)$")
    if login == nil then
        return nil, "malformed session cookie"
    end
    expiry = tonumber(expiry_str)
    if expiry == nil or os.time() > expiry then
        return nil, "expired session"
    end

    expected_sig = cookie_signature(secret, login, expiry)
    if not constant_time_equal(sig, expected_sig) then
        return nil, "invalid session signature"
    end
    return login
end

--------------------------------------------------------------------------
-- CSRF (double-submit cookie)
--------------------------------------------------------------------------

function auth.generate_csrf_token()
    token, err = random_hex_token(24)
    if token == nil then
        return nil, err
    end
    return token
end

-- A fresh per-request CSP nonce (replacing the old AUTH_NONCE env-var
-- stub, which used to relay Fossil's own per-request CSP nonce -- there
-- is no Fossil wrapper providing one anymore). Same shape as a CSRF
-- token but a distinct name since the two are semantically unrelated
-- (one gates inline <script> execution via CSP, the other guards
-- against cross-site form submission).
function auth.generate_nonce()
    nonce, err = random_hex_token(16)
    if nonce == nil then
        return nil, err
    end
    return nonce
end

function auth.verify_csrf(cookie_token, submitted_token)
    if cookie_token == nil or submitted_token == nil then
        return false
    end
    if cookie_token == "" or submitted_token == "" then
        return false
    end
    return constant_time_equal(cookie_token, submitted_token)
end

--------------------------------------------------------------------------
-- CLI: `daat user <add|passwd|capabilities|list|archive|unarchive> ...`
--------------------------------------------------------------------------

function auth.do_user(cmd_args, db_path)
    action = cmd_args[1]

    if action == "add" then
        login = cmd_args[2]
        password = cmd_args[3]
        cap = cmd_args[4]
        if login == nil or password == nil then
            print("Usage: daat user add <login> <password> [cap]")
            return
        end
        ok, err = auth.create_user(db_path, login, password, cap)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Created user " .. login)
        return
    end

    if action == "passwd" then
        login = cmd_args[2]
        password = cmd_args[3]
        if login == nil or password == nil then
            print("Usage: daat user passwd <login> <new_password>")
            return
        end
        ok, err = auth.set_password(db_path, login, password)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Password updated for " .. login)
        return
    end

    if action == "capabilities" then
        login = cmd_args[2]
        cap = cmd_args[3]
        if login == nil or cap == nil then
            print("Usage: daat user capabilities <login> <cap_string>")
            return
        end
        ok, err = auth.set_capabilities(db_path, login, cap)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Capabilities updated for " .. login .. ": " .. cap)
        return
    end

    if action == "list" then
        include_archived = false
        for _, a in ipairs(cmd_args) do
            if a == "--include-archived" then
                include_archived = true
            end
        end
        users = auth.list_users(db_path, include_archived)
        for _, u in ipairs(users) do
            status = "active"
            if u.archived_at != nil and u.archived_at != "" then
                status = "archived"
            end
            print(string.format("%s  cap=%s  %s", u.login, u.cap, status))
        end
        return
    end

    if action == "archive" then
        login = cmd_args[2]
        if login == nil then
            print("Usage: daat user archive <login>")
            return
        end
        ok, err = auth.archive_user(db_path, login)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Archived user " .. login)
        return
    end

    if action == "unarchive" then
        login = cmd_args[2]
        if login == nil then
            print("Usage: daat user unarchive <login>")
            return
        end
        ok, err = auth.unarchive_user(db_path, login)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Unarchived user " .. login)
        return
    end

    print("Usage: daat user <add|passwd|capabilities|list|archive|unarchive> ...")
end

--------------------------------------------------------------------------
-- CLI: `daat api-key <create|list|capabilities|archive|unarchive> ...`
--------------------------------------------------------------------------

function auth.do_api_key(cmd_args, db_path)
    action = cmd_args[1]

    if action == "create" then
        label = cmd_args[2]
        cap = cmd_args[3]
        if label == nil then
            print("Usage: daat api-key create <label> [cap]")
            return
        end
        raw_key, err = auth.create_api_key(db_path, label, cap)
        if raw_key == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Created api key " .. label .. " -- save this now, it cannot be shown again:")
        print(raw_key)
        return
    end

    if action == "capabilities" then
        label = cmd_args[2]
        cap = cmd_args[3]
        if label == nil or cap == nil then
            print("Usage: daat api-key capabilities <label> <cap_string>")
            return
        end
        ok, err = auth.set_api_key_capabilities(db_path, label, cap)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Capabilities updated for " .. label .. ": " .. cap)
        return
    end

    if action == "list" then
        include_archived = false
        for _, a in ipairs(cmd_args) do
            if a == "--include-archived" then
                include_archived = true
            end
        end
        keys = auth.list_api_keys(db_path, include_archived)
        for _, k in ipairs(keys) do
            status = "active"
            if k.archived_at != nil and k.archived_at != "" then
                status = "archived"
            end
            print(string.format("%s  cap=%s  %s", k.label, k.cap, status))
        end
        return
    end

    if action == "archive" then
        label = cmd_args[2]
        if label == nil then
            print("Usage: daat api-key archive <label>")
            return
        end
        ok, err = auth.archive_api_key(db_path, label)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Archived api key " .. label)
        return
    end

    if action == "unarchive" then
        label = cmd_args[2]
        if label == nil then
            print("Usage: daat api-key unarchive <label>")
            return
        end
        ok, err = auth.unarchive_api_key(db_path, label)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Unarchived api key " .. label)
        return
    end

    print("Usage: daat api-key <create|list|capabilities|archive|unarchive> ...")
end

return auth
