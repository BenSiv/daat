-- Password (bcrypt), HMAC-signed session cookie, double-submit CSRF, API key, and email-link auth.
-- Capabilities and session_version are read live per request; see doc/auth.md.

const db = require("database")
const paths = require("paths")
const bcrypt = require("bcrypt")
const hmac = require("hmac")
const mail_provider = require("mail_provider")
const store_lib = require("store")
const config_lib = require("config")

const auth = {}

hex_encode = nil

const SESSION_TTL_SECONDS = 60 * 60 * 24 * 7
auth.SESSION_TTL_SECONDS = SESSION_TTL_SECONDS

-- Dual-backend auth DDL; see doc/auth.md and doc/mariadb-migration.md.
auth.SCHEMA = """
CREATE TABLE IF NOT EXISTS auth_user (
    login VARCHAR(255) PRIMARY KEY,
    password_hash TEXT NOT NULL,
    cap VARCHAR(32) NOT NULL DEFAULT '',
    email VARCHAR(255) DEFAULT NULL,
    email_verified_at INTEGER DEFAULT NULL,
    session_version INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT (%s),
    archived_at TEXT
);

CREATE TABLE IF NOT EXISTS auth_email_link (
    token_hash VARCHAR(64) PRIMARY KEY,
    login VARCHAR(255) NOT NULL,
    purpose VARCHAR(16) NOT NULL DEFAULT 'reset',
    email VARCHAR(255) DEFAULT NULL,
    issued_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at INTEGER
);

CREATE TABLE IF NOT EXISTS auth_api_key (
    label VARCHAR(255) PRIMARY KEY,
    key_hash TEXT NOT NULL,
    cap VARCHAR(32) NOT NULL DEFAULT '',
    created_at TEXT DEFAULT (%s),
    archived_at TEXT
);
"""

-- Incremental column migrations for pre-existing deployments.
function ensure_auth_columns(db_path)
    store_mod = store_lib
    store_mod.ensure_columns(db_path, "auth_user", {
        {"email", "VARCHAR(255) DEFAULT NULL"},
        {"email_verified_at", "INTEGER DEFAULT NULL"},
        {"session_version", "INTEGER NOT NULL DEFAULT 0"},
    })
    store_mod.ensure_columns(db_path, "auth_email_link", {
        {"purpose", "VARCHAR(16) NOT NULL DEFAULT 'reset'"},
        {"email", "VARCHAR(255) DEFAULT NULL"},
    })
end

function auth.init_schema(db_path)
    ok, err = db.exec(db_path, string.format(auth.SCHEMA, db.now_expr(db_path), db.now_expr(db_path)))
    ensure_auth_columns(db_path)
    return ok, err
end

function auth.ensure_session_secret(root)
    config = config_lib
    path = config.session_secret_path(root)
    if paths.file_exists(path) then
        return true
    end

    crypto_lib = require("crypto")
    secret, rand_err = crypto_lib.random_hex(32)
    if secret == nil then
        return nil, rand_err
    end

    file = io.open(path, "w")
    if file == nil then
        return nil, "cannot create session secret file: " .. path
    end
    io.write(file, secret)
    io.close(file)
    return true
end

function auth.session_secret(root)
    config = config_lib
    path = config.session_secret_path(root)
    file = io.open(path, "r")
    if file == nil then
        return nil, "no session secret at " .. path .. " -- run 'daat init' first"
    end
    secret = io.read(file, "*all")
    io.close(file)
    return secret
end

function random_hex_token(num_bytes)
    crypto_lib = require("crypto")
    return crypto_lib.random_hex(num_bytes)
end

-- Fixed-length digest/token comparison without early byte exit.
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

function auth.create_user(db_path, login, password, cap)
    if login == nil or login == "" then
        return nil, "login is required"
    end
    -- "." delimits "<login>.<expiry>.<hmac>" in session cookies.
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
        "INSERT INTO auth_user (login, password_hash, cap) VALUES (%s, %s, %s);",
        db.quote(login), db.quote(hash), db.quote(cap)
    ))
    return login
end

function auth.get_user(db_path, login)
    rows = db.query(db_path, string.format(
        "SELECT * FROM auth_user WHERE login = %s;", db.quote(login)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function auth.list_users(db_path, include_archived)
    q = "SELECT login, cap, email, email_verified_at, created_at, archived_at FROM auth_user"
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

-- Bumps session_version to revoke all prior session cookies.
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
        "UPDATE auth_user SET password_hash = %s, session_version = session_version + 1 WHERE login = %s;",
        db.quote(hash), db.quote(login)
    ))
    return true
end

-- Sentinel rejected by bcrypt.verify for invited accounts before setup.
const NO_PASSWORD_HASH = "!no-password"

function auth.has_password(user)
    return user != nil and user.password_hash != nil and user.password_hash != NO_PASSWORD_HASH
end

function void_account_links(db_path, login)
    db.exec(db_path, string.format(
        "UPDATE auth_email_link SET used_at = %d WHERE login = %s AND used_at IS NULL;", os.time(), db.quote(login)
    ))
end

-- Lowercased unique email; changing or clearing resets verification and voids pending links.
function auth.set_email(db_path, login, email)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. tostring(login)
    end
    if email == nil or email == "" then
        db.exec(db_path, string.format("UPDATE auth_user SET email = NULL, email_verified_at = NULL WHERE login = %s;", db.quote(login)))
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
        "UPDATE auth_user SET email = %s, email_verified_at = NULL WHERE login = %s;", db.quote(email), db.quote(login)
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
        "SELECT * FROM auth_user WHERE email = %s;", db.quote(string.lower(email))
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
        "UPDATE auth_user SET cap = %s WHERE login = %s;", db.quote(cap), db.quote(login)
    ))
    return true
end

function auth.archive_user(db_path, login)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    db.exec(db_path, string.format(
        "UPDATE auth_user SET archived_at = %s WHERE login = %s;", db.now_expr(db_path), db.quote(login)
    ))
    return true
end

function auth.unarchive_user(db_path, login)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    db.exec(db_path, string.format(
        "UPDATE auth_user SET archived_at = NULL WHERE login = %s;", db.quote(login)
    ))
    return true
end

-- Returns the raw key once; only its bcrypt hash is persisted.
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
        "INSERT INTO auth_api_key (label, key_hash, cap) VALUES (%s, %s, %s);",
        db.quote(label), db.quote(hash), db.quote(cap)
    ))
    return raw_key
end

function auth.get_api_key(db_path, label)
    rows = db.query(db_path, string.format(
        "SELECT * FROM auth_api_key WHERE label = %s;", db.quote(label)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function auth.list_api_keys(db_path, include_archived)
    q = "SELECT label, cap, created_at, archived_at FROM auth_api_key"
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
        "UPDATE auth_api_key SET cap = %s WHERE label = %s;", db.quote(cap), db.quote(label)
    ))
    return true
end

function auth.archive_api_key(db_path, label)
    key = auth.get_api_key(db_path, label)
    if key == nil then
        return nil, "no such api key: " .. label
    end
    db.exec(db_path, string.format(
        "UPDATE auth_api_key SET archived_at = %s WHERE label = %s;", db.now_expr(db_path), db.quote(label)
    ))
    return true
end

function auth.unarchive_api_key(db_path, label)
    key = auth.get_api_key(db_path, label)
    if key == nil then
        return nil, "no such api key: " .. label
    end
    db.exec(db_path, string.format(
        "UPDATE auth_api_key SET archived_at = NULL WHERE label = %s;", db.quote(label)
    ))
    return true
end

-- Scans active bcrypt hashes (unindexed by raw value; see doc/auth.md).
function auth.verify_api_key(db_path, raw_key)
    if raw_key == nil or raw_key == "" then
        return nil
    end
    rows = db.query(db_path, "SELECT * FROM auth_api_key WHERE archived_at IS NULL;")
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

-- Runs dummy bcrypt on unknown/passwordless logins to equalize timing.
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

-- Signs canonical stored user.login + expiry + session_version; verify enforces exact-case match.
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
    if user.login != login then
        return nil, "invalid session signature"
    end
    expected_sig = cookie_signature(secret, login, expiry, user_session_version(user))
    if not constant_time_equal(sig, expected_sig) then
        return nil, "invalid session signature"
    end
    return user
end

function auth.generate_csrf_token()
    token, err = random_hex_token(24)
    if token == nil then
        return nil, err
    end
    return token
end

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

const RESET_TTL_SECONDS = 60 * 60
const RESET_THROTTLE_SECONDS = 5 * 60

-- Keyed HMAC digest for indexed one-time token lookup.
function reset_token_hash(secret, token)
    return hmac.sha256(secret, "password-reset." .. token)
end

function default_cap(cap)
    if cap == nil then
        return ""
    end
    return cap
end

function is_admin(user)
    return string.find(default_cap(user.cap), "a", 1, true) != nil
end

-- Active non-Admin accounts with a verified email only (see doc/auth.md).
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

const SETUP_TTL_SECONDS = 7 * 24 * 60 * 60

function send_account_link(root, db_path, user, purpose, site_name)
    config = config_lib
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
        "INSERT INTO auth_email_link (token_hash, login, issued_at, expires_at, purpose, email) VALUES (%s, %s, %d, %d, %s, %s);",
        db.quote(token_hash), db.quote(user.login), now, now + ttl, db.quote(purpose), db.quote(user.email)
    ))

    base_url = string.gsub(config.load().public_url, "/+$", "")
    -- Token rides in #fragment to stay out of server/proxy access logs.
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
        -- Mark used_at on send failure (append-only; avoids burning the 5-minute throttle).
        db.exec(db_path, string.format(
            "UPDATE auth_email_link SET used_at = %d WHERE token_hash = %s;", now, db.quote(token_hash)
        ))
        return nil, send_err
    end
    return true
end

-- Sends "setup" if passwordless (non-Admin), or "verify" (requires current password) if password exists.
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
        "UPDATE auth_user SET password_hash = %s WHERE login = %s;", db.quote(NO_PASSWORD_HASH), db.quote(login)
    ))
    auth.set_email(db_path, login, email)
    sent, send_err = auth.send_setup_link(root, db_path, login, site_name)
    if sent == nil then
        return nil, "created " .. login .. ", but the setup email could not be sent (" .. tostring(send_err) .. ") -- set their email again to resend it"
    end
    return true
end

-- Returns true (sent), false (unknown/unverified/throttled), or nil, err; callers render identical UX for true/false.
function auth.request_password_reset(root, db_path, identifier, site_name)
    config = config_lib
    user = find_reset_account(db_path, identifier)
    if user == nil then
        return false
    end

    now = os.time()
    recent = db.query(db_path, string.format(
        "SELECT COUNT(*) AS n FROM auth_email_link WHERE login = %s AND purpose = 'reset' AND used_at IS NULL AND issued_at > %d;",
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

-- Requires active account, matching current user.email, and non-Admin for password-setting links.
function check_account_link(root, db_path, token)
    if token == nil or string.match(token, "^%x+$") == nil or string.len(token) != 64 then
        return nil
    end
    secret, err = auth.session_secret(root)
    if secret == nil then
        return nil
    end
    rows = db.query(db_path, string.format(
        "SELECT login, purpose, email FROM auth_email_link WHERE token_hash = %s AND used_at IS NULL AND expires_at > %d;",
        db.quote(reset_token_hash(secret, token)), os.time()
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    user = auth.get_user(db_path, rows[1].login)
    if user == nil or (user.archived_at != nil and user.archived_at != "") then
        return nil
    end
    link = rows[1]
    if link.email == nil or link.email == "" or link.email != user.email then
        return nil
    end
    if link.purpose != "verify" and is_admin(user) then
        return nil
    end
    return user.login, link
end

function auth.check_password_reset(root, db_path, token)
    login, link = check_account_link(root, db_path, token)
    if login == nil or (link.purpose != "reset" and link.purpose != "setup") then
        return nil
    end
    return login, link
end

function auth.check_email_verification(root, db_path, token)
    login, link = check_account_link(root, db_path, token)
    if login == nil or link.purpose != "verify" then
        return nil
    end
    return login, link
end

-- Voids all outstanding links for login and marks link.email verified.
function finish_account_link(db_path, login, link)
    void_account_links(db_path, login)
    db.exec(db_path, string.format(
        "UPDATE auth_user SET email_verified_at = %d WHERE login = %s AND email = %s;",
        os.time(), db.quote(login), db.quote(link.email)
    ))
end

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

    if action == "invite" then
        config = config_lib
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
        config = config_lib
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
