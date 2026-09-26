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

db = require("database")
paths = require("paths")
bcrypt = require("bcrypt")
hmac = require("hmac")
mail_provider = require("mail_provider")

auth = {}

-- hex_encode used before its own definition below -- pre-declared,
-- see ../../luam/doc/forward_references.md
hex_encode = nil

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

-- One row per emailed forgot-password link. Only a keyed hash of the
-- token is stored (auth.reset_token_hash), so a leaked database row
-- can't be replayed as a working link. issued_at/expires_at/used_at are
-- unix seconds (INTEGER), not the TEXT now() timestamps used elsewhere,
-- because they're compared against os.time() directly -- the same
-- reason the session cookie's own expiry is a unix integer.
CREATE TABLE IF NOT EXISTS password_reset (
    token_hash VARCHAR(64) PRIMARY KEY,
    login VARCHAR(255) NOT NULL,
    issued_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at INTEGER
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

function has_column(db_path, table_name, column_name)
    for _, name in ipairs(db.get_columns(db_path, table_name)) do
        if name == column_name then
            return true
        end
    end
    return false
end

-- Every request runs init_schema, so concurrent first requests after an
-- upgrade can all see a column missing and race to add it -- found
-- rehearsing against real MySQL 8, where the losers' ALTER raises
-- "Duplicate column name" (the same race document.lua's
-- ensure_document_link_indexes tolerates for indexes). A failed ALTER is
-- only an error if the column still doesn't exist afterwards.
function add_column_if_missing(db_path, table_name, column_name, column_sql)
    if has_column(db_path, table_name, column_name) then
        return
    end
    ok, err = pcall(db.exec, db_path, "ALTER TABLE " .. table_name .. " ADD COLUMN " .. column_name .. " " .. column_sql .. ";")
    if ok == false and not has_column(db_path, table_name, column_name) then
        error(err)
    end
end

-- Columns added after these tables already existed in real deployments,
-- so migrations rather than SCHEMA edits (CREATE TABLE IF NOT EXISTS
-- never adds a column to an existing table).
--
-- user.email: nullable -- an account with no email simply can't use the
-- forgot-password flow.
--
-- user.email_verified_at: when the account's current email was last
-- proven reachable -- set by completing a link emailed to that exact
-- address, cleared whenever the address changes. Unix seconds, like
-- password_reset's own times. Forgot-password only mails a verified
-- address (find_reset_account), so a mistyped address never receives
-- reset links.
--
-- password_reset.purpose: "reset" (forgot-password) or "setup" (sent
-- when an account is created or its email is set -- choosing a password
-- through it is how the address gets verified). password_reset.email:
-- the address the link went to, so completing it verifies only that
-- address, not one set since.
function ensure_auth_columns(db_path)
    add_column_if_missing(db_path, "user", "email", "VARCHAR(255) DEFAULT NULL")
    add_column_if_missing(db_path, "user", "email_verified_at", "INTEGER DEFAULT NULL")
    add_column_if_missing(db_path, "password_reset", "purpose", "VARCHAR(16) NOT NULL DEFAULT 'reset'")
    add_column_if_missing(db_path, "password_reset", "email", "VARCHAR(255) DEFAULT NULL")
end

function auth.init_schema(db_path)
    ok, err = db.exec(db_path, string.format(auth.SCHEMA, db.now_expr(db_path), db.now_expr(db_path)))
    ensure_auth_columns(db_path)
    return ok, err
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
    q = "SELECT login, cap, email, email_verified_at, created_at, archived_at FROM user"
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

-- Stored lowercased, and unique across accounts (checked here, not
-- via a DB constraint -- see ensure_auth_columns for why this is
-- a migration), so the forgot-password form can accept an email and
-- resolve it to exactly one account. "" clears it. A changed address
-- starts unverified (email_verified_at NULL); setting the same address
-- again leaves its verification alone.
function auth.set_email(db_path, login, email)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. tostring(login)
    end
    if email == nil or email == "" then
        db.exec(db_path, string.format("UPDATE user SET email = NULL, email_verified_at = NULL WHERE login = %s;", db.quote(login)))
        return true
    end
    email = string.lower(email)
    if not mail_provider.valid_address(email) then
        return nil, "invalid email address: " .. email
    end
    other = auth.get_user_by_email(db_path, email)
    if other != nil and other.login != login then
        return nil, "email already used by another account"
    end
    if user.email == email then
        return true
    end
    db.exec(db_path, string.format(
        "UPDATE user SET email = %s, email_verified_at = NULL WHERE login = %s;", db.quote(email), db.quote(login)
    ))
    return true
end

function auth.email_verified(user)
    return user != nil and user.email != nil and user.email != ""
        and user.email_verified_at != nil and user.email_verified_at != ""
end

function auth.get_user_by_email(db_path, email)
    rows = db.query(db_path, string.format(
        "SELECT * FROM user WHERE email = %s;", db.quote(string.lower(email))
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
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
-- Forgot-password reset links
--------------------------------------------------------------------------

RESET_TTL_SECONDS = 60 * 60 -- 1 hour
-- At most one new link per account per window, so the (unauthenticated)
-- request form can't be used to flood someone's inbox.
RESET_THROTTLE_SECONDS = 5 * 60

-- Keyed with the store's session secret rather than a bare digest, and
-- deterministic (unlike bcrypt), so a token can be looked up directly by
-- its hash -- the token itself is 32 random bytes, so there's nothing
-- for a slow hash to protect against brute-forcing.
function reset_token_hash(secret, token)
    return hmac.sha256(secret, "password-reset." .. token)
end

-- An identifier containing "@" is treated as an email, anything else as
-- a login. Only an active, non-Admin account with an email on file
-- qualifies. Admin ("a") accounts are excluded on purpose: emailed
-- recovery makes an account only as safe as its mailbox, and a
-- compromised admin mailbox shouldn't hand over the whole platform --
-- another admin resets them instead (/admin-users-password).
function default_cap(cap)
    if cap == nil then
        return ""
    end
    return cap
end

function find_reset_account(db_path, identifier)
    if identifier == nil then
        return nil
    end
    identifier = string.match(identifier, "^%s*(.-)%s*$")
    if identifier == "" then
        return nil
    end
    user = nil
    if string.find(identifier, "@", 1, true) != nil then
        user = auth.get_user_by_email(db_path, identifier)
    else
        user = auth.get_user(db_path, identifier)
    end
    if user == nil or (user.archived_at != nil and user.archived_at != "") then
        return nil
    end
    if not auth.email_verified(user) then
        return nil
    end
    if string.find(default_cap(user.cap), "a", 1, true) != nil then
        return nil
    end
    return user
end

-- A setup link has longer to live than a reset one: it's the first
-- email a new account gets, often read days after the admin sent it.
SETUP_TTL_SECONDS = 7 * 24 * 60 * 60

-- Issues one emailed link (purpose "reset" or "setup") to user.email and
-- sends it. -> true | nil, err. The link is the same /reset-password
-- page either way; only its lifetime and the email's wording differ.
function send_account_link(root, db_path, user, purpose, site_name)
    config = require("config")
    secret, err = auth.session_secret(root)
    if secret == nil then
        return nil, err
    end
    token, token_err = random_hex_token(32)
    if token == nil then
        return nil, token_err
    end
    now = os.time()
    ttl = RESET_TTL_SECONDS
    if purpose == "setup" then
        ttl = SETUP_TTL_SECONDS
    end
    token_hash = reset_token_hash(secret, token)
    db.exec(db_path, string.format(
        "INSERT INTO password_reset (token_hash, login, issued_at, expires_at, purpose, email) VALUES (%s, %s, %d, %d, %s, %s);",
        db.quote(token_hash), db.quote(user.login), now, now + ttl, db.quote(purpose), db.quote(user.email)
    ))

    base_url = string.gsub(config.platform_config().public_url, "/+$", "")
    -- In the #fragment, not the query string: browsers never send a
    -- fragment to the server, so the token can't land in the web
    -- server's or a load balancer's access log. /reset-password's own
    -- script moves it into the form, which POSTs it.
    link = base_url .. "/reset-password#token=" .. token
    subject = "Reset your " .. site_name .. " password"
    lines = {
        "Someone (hopefully you) asked to reset the password for the " .. site_name .. " account \"" .. user.login .. "\".",
        "",
        "To choose a new password, open this link within the next hour:",
        "",
        link,
        "",
        "The link works once. If you didn't ask for this, ignore this email -- your password stays the same.",
        "",
    }
    if purpose == "setup" then
        subject = "Set up your " .. site_name .. " account"
        lines = {
            "An administrator set this address as the email for the " .. site_name .. " account \"" .. user.login .. "\".",
            "",
            "To confirm it and choose your password, open this link within the next 7 days:",
            "",
            link,
            "",
            "The link works once. Password reset emails will only be sent here once you've used it.",
            "If you weren't expecting this, ignore it.",
            "",
        }
    end
    sent, send_err = mail_provider.send({
        to = user.email,
        from_name = site_name,
        subject = subject,
        body = table.concat(lines, "\n"),
    })
    if sent == nil then
        -- Void the unsent link rather than delete it (nothing is ever
        -- deleted -- see doc/architecture.md), and so it doesn't count
        -- against the throttle: the user can retry straight away.
        db.exec(db_path, string.format(
            "UPDATE password_reset SET used_at = %d WHERE token_hash = %s;", now, db.quote(token_hash)
        ))
        return nil, send_err
    end
    return true
end

-- auth.send_setup_link(root, db_path, login, site_name) -> true | nil, err
-- Admin-triggered (account creation, setting an email), so no throttle.
-- Works for Admin accounts too: it's how any account's address is
-- verified -- Admins just never get the forgot-password kind.
function auth.send_setup_link(root, db_path, login, site_name)
    user = auth.get_user(db_path, login)
    if user == nil or (user.archived_at != nil and user.archived_at != "") then
        return nil, "no such active user: " .. tostring(login)
    end
    if user.email == nil or user.email == "" then
        return nil, login .. " has no email on file"
    end
    return send_account_link(root, db_path, user, "setup", site_name)
end

-- auth.invite_user(root, db_path, login, email, cap, site_name)
--   -> true | nil, err
-- Creates an account that has no usable password yet and emails it a
-- setup link: choosing a password through the link is also what
-- verifies the address, and the admin never knows the password. The
-- email is required and checked before anything is created. If only
-- the send fails, the account exists and the error says so --
-- setting the email again resends the link.
function auth.invite_user(root, db_path, login, email, cap, site_name)
    if email == nil or email == "" then
        return nil, "email is required"
    end
    email = string.lower(email)
    if not mail_provider.valid_address(email) then
        return nil, "invalid email address: " .. email
    end
    if auth.get_user_by_email(db_path, email) != nil then
        return nil, "email already used by another account"
    end
    placeholder, err = random_hex_token(32)
    if placeholder == nil then
        return nil, err
    end
    ok, err = auth.create_user(db_path, login, placeholder, cap)
    if ok == nil then
        return nil, err
    end
    auth.set_email(db_path, login, email)
    sent, send_err = auth.send_setup_link(root, db_path, login, site_name)
    if sent == nil then
        return nil, "created " .. login .. ", but the setup email could not be sent (" .. tostring(send_err) .. ") -- set their email again to resend it"
    end
    return true
end

-- auth.request_password_reset(root, db_path, identifier, site_name)
--   -> true (a link was emailed) | false (nothing to do: no matching
--      account, no email on file, or throttled) | nil, err (send failed)
-- The caller must show the same response for true and false alike, so
-- the form never reveals whether an account exists.
function auth.request_password_reset(root, db_path, identifier, site_name)
    config = require("config")
    user = find_reset_account(db_path, identifier)
    if user == nil then
        return false
    end

    now = os.time()
    recent = db.query(db_path, string.format(
        "SELECT COUNT(*) AS n FROM password_reset WHERE login = %s AND purpose = 'reset' AND used_at IS NULL AND issued_at > %d;",
        db.quote(user.login), now - RESET_THROTTLE_SECONDS
    ))
    if recent != nil and recent[1] != nil and tonumber(recent[1].n) > 0 then
        return false
    end

    sent, send_err = send_account_link(root, db_path, user, "reset", site_name)
    if sent == nil then
        return nil, send_err
    end
    return true
end

-- auth.check_password_reset(root, db_path, token) -> login, link | nil
-- Valid means: issued by this store, not yet used, not expired, and the
-- account is still active -- and, for a forgot-password link, not an
-- Admin. link is the password_reset row (purpose, email).
function auth.check_password_reset(root, db_path, token)
    if token == nil or string.match(token, "^%x+$") == nil or string.len(token) != 64 then
        return nil
    end
    secret, err = auth.session_secret(root)
    if secret == nil then
        return nil
    end
    rows = db.query(db_path, string.format(
        "SELECT login, purpose, email FROM password_reset WHERE token_hash = %s AND used_at IS NULL AND expires_at > %d;",
        db.quote(reset_token_hash(secret, token)), os.time()
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    user = auth.get_user(db_path, rows[1].login)
    if user == nil or (user.archived_at != nil and user.archived_at != "") then
        return nil
    end
    -- Re-checked here, not only when the link was issued: an account
    -- promoted to Admin after its link went out mustn't be able to use it.
    if rows[1].purpose != "setup" and string.find(default_cap(user.cap), "a", 1, true) != nil then
        return nil
    end
    return user.login, rows[1]
end

-- auth.complete_password_reset(root, db_path, token, new_password)
--   -> login | nil, err
-- Using one link voids every other outstanding link for that account
-- too, so an older email lying around can't be used afterwards.
-- Existing sessions are NOT ended: session cookies are stateless (see
-- this file's header), the same limitation an admin reset has today.
function auth.complete_password_reset(root, db_path, token, new_password)
    login, link = auth.check_password_reset(root, db_path, token)
    if login == nil then
        return nil, "This reset link is invalid or has expired."
    end
    if new_password == nil or new_password == "" then
        return nil, "Password is required."
    end
    ok, err = auth.set_password(db_path, login, new_password)
    if ok == nil then
        return nil, err
    end
    db.exec(db_path, string.format(
        "UPDATE password_reset SET used_at = %d WHERE login = %s AND used_at IS NULL;", os.time(), db.quote(login)
    ))
    -- Opening a link that was mailed to the address still on file proves
    -- the address works. A link sent before the email was changed proves
    -- nothing about the new one.
    if link.email != nil and link.email != "" then
        db.exec(db_path, string.format(
            "UPDATE user SET email_verified_at = %d WHERE login = %s AND email = %s;",
            os.time(), db.quote(login), db.quote(link.email)
        ))
    end
    return login
end

--------------------------------------------------------------------------
-- CLI: `daat user <add|invite|passwd|email|capabilities|list|archive|unarchive> ...`
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

    -- Run from the store root, like every other CLI command ("." below).
    if action == "invite" then
        config = require("config")
        login = cmd_args[2]
        email = cmd_args[3]
        cap = cmd_args[4]
        if login == nil or email == nil then
            print("Usage: daat user invite <login> <email> [cap]")
            return
        end
        if not config.password_reset_enabled() then
            print("Error: mail isn't configured (mail_provider, mail_from, public_url) -- use 'daat user add' instead")
            return
        end
        ok, err = auth.invite_user(".", db_path, login, email, cap, config.load_theme(".").site_name)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Invited " .. login .. " -- setup link sent to " .. string.lower(email))
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

    if action == "email" then
        login = cmd_args[2]
        email = cmd_args[3]
        if login == nil or email == nil then
            print("Usage: daat user email <login> <email>   (\"\" clears it)")
            return
        end
        ok, err = auth.set_email(db_path, login, email)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Email updated for " .. login)
        config = require("config")
        user = auth.get_user(db_path, login)
        if config.password_reset_enabled() and user.email != nil and not auth.email_verified(user) then
            sent, send_err = auth.send_setup_link(".", db_path, login, config.load_theme(".").site_name)
            if sent == nil then
                print("Error: setup link not sent: " .. tostring(send_err))
                return
            end
            print("Setup link sent to " .. user.email .. " -- the address is verified once it's used")
        end
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
            email = u.email
            if email == nil or email == "" then
                email = "-"
            elseif not auth.email_verified(u) then
                email = email .. " (unverified)"
            end
            print(string.format("%s  cap=%s  email=%s  %s", u.login, u.cap, email, status))
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

    print("Usage: daat user <add|passwd|email|capabilities|list|archive|unarchive> ...")
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
