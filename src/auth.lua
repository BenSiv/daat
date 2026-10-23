-- Real login/session auth, replacing cgi.lua's Phase 0
-- AUTH_USER/AUTH_CAPABILITIES/AUTH_NONCE env-var stub.
--
-- Password storage: bcrypt (require("bcrypt"), luam/lib/bcrypt/bcrypt.c).
-- Session cookies: no server-side session rows -- the cookie itself is
-- "<login>.<expiry_unix>.<hmac_hex>", verified with
-- require("hmac").sha256 keyed by a per-store secret generated once at
-- init (config.session_secret_path) and never transmitted. The HMAC
-- also covers the account's session_version, which lives only in the
-- user row: bumping it (every password change does) voids every cookie
-- issued before, without keeping a list of sessions. Capabilities are
-- deliberately NOT embedded in the cookie: they're looked up fresh
-- from the user table on every request, so a capability change or
-- archive takes effect on the user's very next request rather than
-- only after their session cookie expires. See doc/auth.md for why
-- each piece is built the way it is.
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
auth.SESSION_TTL_SECONDS = SESSION_TTL_SECONDS

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
-- user.session_version: covered by every session cookie's signature
-- (cookie_signature), and bumped by auth.set_password -- so changing a
-- password, by any route, ends every session that existed before it.
--
-- password_reset.purpose: "reset" (forgot-password), "setup" (an
-- account with no password yet chooses its first one -- that's also
-- how its address gets verified) or "verify" (an account that already
-- has a password confirms a new address by entering that password; it
-- can't set one). password_reset.email: the address the link went to.
-- A link only works while that is still the account's address.
function ensure_auth_columns(db_path)
    add_column_if_missing(db_path, "user", "email", "VARCHAR(255) DEFAULT NULL")
    add_column_if_missing(db_path, "user", "email_verified_at", "INTEGER DEFAULT NULL")
    add_column_if_missing(db_path, "user", "session_version", "INTEGER NOT NULL DEFAULT 0")
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

-- Also bumps session_version, which ends every existing session for
-- the account: whoever changes a password (the user on /account, an
-- admin, a reset link) wants the old one, and any session opened with
-- it, to stop working. /account re-issues the caller's own cookie.
function auth.set_password(db_path, login, password)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    if password == nil or password == "" then
        return nil, "password is required"
    end
    hash = bcrypt.hash(password, 12)
    db.exec(db_path, string.format(
        "UPDATE user SET password_hash = %s, session_version = session_version + 1 WHERE login = %s;",
        db.quote(hash), db.quote(login)
    ))
    return true
end

-- An invited account has no password until its setup link is used.
-- Its password_hash holds this marker rather than a hash of some
-- random string, so "has this account ever had a password?" is a
-- fact the code can check (auth.has_password), not a guess. It can't
-- match any password: bcrypt.verify rejects it as an invalid hash.
NO_PASSWORD_HASH = "!no-password"

function auth.has_password(user)
    return user != nil and user.password_hash != nil and user.password_hash != NO_PASSWORD_HASH
end

-- Stored lowercased, and unique across accounts (checked here, not
-- via a DB constraint -- see ensure_auth_columns for why this is
-- a migration), so the forgot-password form can accept an email and
-- resolve it to exactly one account. "" clears it. A changed address
-- starts unverified (email_verified_at NULL); setting the same address
-- again leaves its verification alone. A change or clear also voids
-- every link already mailed for the account: fixing a mistyped address
-- must cut off whoever received a link at the wrong one.
function void_account_links(db_path, login)
    db.exec(db_path, string.format(
        "UPDATE password_reset SET used_at = %d WHERE login = %s AND used_at IS NULL;", os.time(), db.quote(login)
    ))
end

function auth.set_email(db_path, login, email)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. tostring(login)
    end
    if email == nil or email == "" then
        db.exec(db_path, string.format("UPDATE user SET email = NULL, email_verified_at = NULL WHERE login = %s;", db.quote(login)))
        void_account_links(db_path, login)
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
    void_account_links(db_path, login)
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
-- An unknown login still pays for one bcrypt run, so how long a failed
-- login takes doesn't tell a caller whether the login exists.
function auth.login(db_path, login, password)
    if login == nil or password == nil then
        return nil, "invalid login or password"
    end
    user = auth.get_user(db_path, login)
    if user == nil or not auth.has_password(user) then
        bcrypt.hash(password, 12)
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

-- session_version is signed but not carried in the cookie: it's read
-- from the user row at verify time, so a bumped version changes the
-- expected signature and every older cookie stops matching.
function cookie_signature(secret, login, expiry, session_version)
    return hmac.sha256(secret, login .. "." .. tostring(expiry) .. "." .. tostring(session_version))
end

function user_session_version(user)
    version = tonumber(user.session_version)
    if version == nil then
        return 0
    end
    return version
end

-- auth.issue_session_cookie(root, db_path, login) -> cookie_value_string | nil, err
-- Signs the account's canonical login (as stored), not whatever spelling
-- the caller typed -- MySQL's default collation matches logins
-- case-insensitively.
function auth.issue_session_cookie(root, db_path, login)
    secret, err = auth.session_secret(root)
    if secret == nil then
        return nil, err
    end
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. tostring(login)
    end
    expiry = os.time() + SESSION_TTL_SECONDS
    sig = cookie_signature(secret, user.login, expiry, user_session_version(user))
    return user.login .. "." .. tostring(expiry) .. "." .. sig
end

-- auth.verify_session_cookie(root, db_path, cookie_value) -> user_row | nil, err
-- Returns the account only if the signature, the expiry and the
-- account's current session_version all check out and the account is
-- active, so callers can't forget one of those checks.
function auth.verify_session_cookie(root, db_path, cookie_value)
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

    user = auth.get_user(db_path, login)
    if user == nil or (user.archived_at != nil and user.archived_at != "") then
        return nil, "no such active user"
    end
    -- Exact login, not the collation's case-insensitive match: the
    -- signature covers the stored spelling.
    if user.login != login then
        return nil, "invalid session signature"
    end
    expected_sig = cookie_signature(secret, login, expiry, user_session_version(user))
    if not constant_time_equal(sig, expected_sig) then
        return nil, "invalid session signature"
    end
    return user
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

function is_admin(user)
    return string.find(default_cap(user.cap), "a", 1, true) != nil
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
    if is_admin(user) then
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
    if purpose == "setup" or purpose == "verify" then
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
    if purpose == "verify" then
        link = base_url .. "/verify-email#token=" .. token
        subject = "Confirm your email for " .. site_name
        lines = {
            "An administrator set this address as the email for the " .. site_name .. " account \"" .. user.login .. "\".",
            "",
            "To confirm it, open this link within the next 7 days and enter the account's current password:",
            "",
            link,
            "",
            "The link works once. Password reset emails will only be sent here once you've confirmed it.",
            "If you weren't expecting this, ignore it -- nothing changes without the account's password.",
            "",
        }
    elseif purpose == "setup" then
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
-- Which link goes out depends on the account, because the address is
-- unverified and may be mistyped -- whoever reads it mustn't be able
-- to take the account over:
--   * no password yet (invited): a "setup" link that chooses one. Only
--     for non-Admin accounts; Admins get a password from another Admin.
--   * has a password: a "verify" link, which also asks for that
--     password, so it proves the reader is the account's owner as well
--     as the mailbox's. It can't change the password.
function auth.send_setup_link(root, db_path, login, site_name)
    user = auth.get_user(db_path, login)
    if user == nil or (user.archived_at != nil and user.archived_at != "") then
        return nil, "no such active user: " .. tostring(login)
    end
    if user.email == nil or user.email == "" then
        return nil, login .. " has no email on file"
    end
    if auth.has_password(user) then
        return send_account_link(root, db_path, user, "verify", site_name)
    end
    if is_admin(user) then
        return nil, login .. " is an Admin with no password -- set one on /admin-users instead of emailing a setup link"
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
--
-- Not for Admin accounts: a setup link is only as safe as the mailbox
-- it lands in, and the address hasn't been verified yet. An Admin is
-- created with a password (daat user add, or /admin-users without
-- mail), or created without "a" and promoted once it has one.
function auth.invite_user(root, db_path, login, email, cap, site_name)
    if email == nil or email == "" then
        return nil, "email is required"
    end
    if string.find(default_cap(cap), "a", 1, true) != nil then
        return nil, "Admin accounts can't be set up by email -- invite without 'a', then grant it once the account has a password"
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
    db.exec(db_path, string.format(
        "UPDATE user SET password_hash = %s WHERE login = %s;", db.quote(NO_PASSWORD_HASH), db.quote(login)
    ))
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

-- auth.check_account_link(root, db_path, token) -> login, link | nil
-- Valid means: issued by this store, not yet used, not expired, the
-- account is still active, and the address it was mailed to is still
-- the account's address. A "reset" or "setup" link (both set a
-- password) is also refused for an Admin -- checked again here, not
-- only when the link was issued, so an account promoted after its link
-- went out can't use it. link is the password_reset row (purpose, email).
function check_account_link(root, db_path, token)
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
    -- Mailed to an address the account no longer has (or, for a row
    -- from before addresses were recorded, to an unknown one): refused,
    -- so correcting a mistyped address cuts off the wrong recipient
    -- even if set_email's voiding were ever bypassed.
    link = rows[1]
    if link.email == nil or link.email == "" or link.email != user.email then
        return nil
    end
    if link.purpose != "verify" and is_admin(user) then
        return nil
    end
    return user.login, link
end

-- auth.check_password_reset(root, db_path, token) -> login, link | nil
-- A link that sets a password: "reset" or "setup", never "verify".
function auth.check_password_reset(root, db_path, token)
    login, link = check_account_link(root, db_path, token)
    if login == nil or (link.purpose != "reset" and link.purpose != "setup") then
        return nil
    end
    return login, link
end

-- auth.check_email_verification(root, db_path, token) -> login, link | nil
function auth.check_email_verification(root, db_path, token)
    login, link = check_account_link(root, db_path, token)
    if login == nil or link.purpose != "verify" then
        return nil
    end
    return login, link
end

-- Using any link voids every other outstanding link for the account,
-- so an older email lying around can't be used afterwards, and marks
-- the address the link went to as verified (check_account_link has
-- already confirmed it's still the account's address).
function finish_account_link(db_path, login, link)
    void_account_links(db_path, login)
    db.exec(db_path, string.format(
        "UPDATE user SET email_verified_at = %d WHERE login = %s AND email = %s;",
        os.time(), db.quote(login), db.quote(link.email)
    ))
end

-- auth.complete_password_reset(root, db_path, token, new_password)
--   -> login | nil, err
-- Setting the password also ends every existing session for the
-- account (auth.set_password bumps session_version).
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
    finish_account_link(db_path, login, link)
    return login
end

-- auth.complete_email_verification(root, db_path, token, password)
--   -> login | nil, err
-- The account's current password is required as well as the link:
-- the link proves the mailbox, the password proves the account, and
-- an address only becomes a reset destination with both.
function auth.complete_email_verification(root, db_path, token, password)
    login, link = auth.check_email_verification(root, db_path, token)
    if login == nil then
        return nil, "This confirmation link is invalid or has expired."
    end
    if auth.login(db_path, login, password) == nil then
        return nil, "That isn't this account's password."
    end
    finish_account_link(db_path, login, link)
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
            print("Link sent to " .. user.email .. " -- the address is verified once it's used")
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
