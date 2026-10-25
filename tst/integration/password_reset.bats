#!/usr/bin/env bats

# Forgot-password flow: /forgot-password -> emailed link ->
# /reset-password, plus the email field it depends on. Mail goes
# through the "test" mail provider (src/provider/mail_test.lua), which
# appends each message to $MAIL_TEST_OUTBOX as one JSON line.

load test_helper.bash

MAIL_CONFIG=', mail_provider = "test", mail_from = "noreply@example.com", public_url = "https://lims.example.com/"'

setup() {
    setup_test_env
    write_platform_config "$MAIL_CONFIG"
    "$BIN" init
    export MAIL_TEST_OUTBOX="$TEST_DIR/outbox"
}

teardown() {
    cleanup_test_env
}

raw_form_post() {
    local path_info="$1"
    local body="$2"
    local cookie="${3:-}"
    printf '%s' "$body" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="$path_info" QUERY_STRING="" \
        HTTP_COOKIE="$cookie" "$BIN"
}

raw_login() {
    raw_form_post "/login" "login=$1&password=$2"
}

outbox_count() {
    if [ ! -f "$MAIL_TEST_OUTBOX" ]; then
        echo 0
        return
    fi
    wc -l < "$MAIL_TEST_OUTBOX" | tr -d ' '
}

# The token from the most recently sent link, whichever page it opens
# (/reset-password for reset and setup links, /verify-email for verify).
last_token() {
    tail -1 "$MAIL_TEST_OUTBOX" | grep -oE '(reset-password|verify-email)#token=[0-9a-f]*' | head -1 | sed 's/.*token=//'
}

# Which page the most recently sent link opens.
last_link_page() {
    tail -1 "$MAIL_TEST_OUTBOX" | grep -oE '(reset-password|verify-email)#token=' | head -1 | sed 's/#token=//'
}

# An account whose email is verified the only way there is for an
# account that has a password: the verify link `user email` sends, used
# with that password. The outbox is cleared afterwards, so a test's own
# outbox_count starts from zero.
add_user_with_email() {
    "$BIN" user add "$1" oldpass123 i >/dev/null
    "$BIN" user email "$1" "$2" >/dev/null
    raw_form_post "/verify-email" "token=$(last_token)&password=oldpass123" >/dev/null
    rm -f "$MAIL_TEST_OUTBOX"
}

@test "with no mail configured, /login has no forgot link and both reset routes 404" {
    write_platform_config ""
    run raw_get "/login"
    [[ ! "$output" =~ "Forgot password?" ]]
    run raw_get "/forgot-password"
    [[ "$output" =~ "404 Not Found" ]]
    run raw_get "/reset-password" "token=abc"
    [[ "$output" =~ "404 Not Found" ]]
}

@test "mail_provider alone isn't enough -- public_url is required too" {
    write_platform_config ', mail_provider = "test", mail_from = "noreply@example.com"'
    run raw_get "/forgot-password"
    [[ "$output" =~ "404 Not Found" ]]
}

@test "with mail configured, /login links to /forgot-password, reachable without a session" {
    run raw_get "/login"
    [[ "$output" =~ 'href="/forgot-password"' ]]
    run raw_get "/forgot-password"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Login or email" ]]
}

@test "requesting by login emails the account's address a working reset link" {
    add_user_with_email hanne hanne@example.com
    run raw_form_post "/forgot-password" "identifier=hanne"
    [[ "$output" =~ "Check your email" ]]
    [ "$(outbox_count)" = "1" ]
    run cat "$MAIL_TEST_OUTBOX"
    [[ "$output" =~ '"to":"hanne@example.com"' ]]
    [[ "$output" =~ "https://lims.example.com/reset-password#token=" ]]
    [[ ! "$output" =~ "reset-password?token=" ]]
    [[ ! "$output" =~ "example.com//reset-password" ]]

    token=$(last_token)
    [ "${#token}" = "64" ]
    run raw_get "/reset-password"
    [[ "$output" =~ "Choose a new password" ]]
    [[ "$output" =~ "Referrer-Policy: no-referrer" ]]

    run raw_form_post "/reset-password" "token=${token}&new_password=newpass456&confirm_password=newpass456"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /login?reset=1" ]]

    run raw_login hanne newpass456
    [[ "$output" =~ "302 Found" ]]
    run raw_login hanne oldpass123
    [[ "$output" =~ "401 Unauthorized" ]]

    run raw_get "/login" "reset=1"
    [[ "$output" =~ "Password updated." ]]
}

@test "requesting by email is case-insensitive" {
    add_user_with_email hanne Hanne@Example.com
    run raw_form_post "/forgot-password" "identifier=HANNE%40example.com"
    [ "$(outbox_count)" = "1" ]
    run cat "$MAIL_TEST_OUTBOX"
    [[ "$output" =~ '"to":"hanne@example.com"' ]]
}

@test "unknown login, no email on file, and archived accounts all get the same response and no email" {
    "$BIN" user add noemail pass123 i >/dev/null
    add_user_with_email gone gone@example.com
    "$BIN" user archive gone >/dev/null
    add_user_with_email real real@example.com

    # Byte-identical apart from the per-request CSP nonce.
    expected=$(raw_form_post "/forgot-password" "identifier=real" | sed 's/nonce-[^ ;"]*//g; s/nonce="[^"]*"//g')
    [[ "$expected" =~ "Check your email" ]]

    for who in nosuchuser noemail gone nobody%40example.com; do
        actual=$(raw_form_post "/forgot-password" "identifier=${who}" | sed 's/nonce-[^ ;"]*//g; s/nonce="[^"]*"//g')
        [ "$actual" = "$expected" ]
    done
    [ "$(outbox_count)" = "1" ]
}

@test "admin accounts can't be reset by email -- same response, no email" {
    add_user_with_email boss boss@example.com
    "$BIN" user capabilities boss ia >/dev/null
    run raw_form_post "/forgot-password" "identifier=boss"
    [[ "$output" =~ "Check your email" ]]
    run raw_form_post "/forgot-password" "identifier=boss%40example.com"
    [[ "$output" =~ "Check your email" ]]
    [ "$(outbox_count)" = "0" ]
}

@test "an outstanding link stops working if the account is made an admin" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    token=$(last_token)
    "$BIN" user capabilities hanne ia >/dev/null
    run raw_form_post "/reset-password" "token=${token}&new_password=newpass456&confirm_password=newpass456"
    [[ "$output" =~ "invalid" ]]
    run raw_login hanne oldpass123
    [[ "$output" =~ "302 Found" ]]
}

@test "the reset page reads the token from the URL fragment, never the query string" {
    run raw_get "/reset-password"
    [[ "$output" =~ 'id="reset-token"' ]]
    [[ "$output" =~ "window.location.hash" ]]
    [[ "$output" =~ "history.replaceState" ]]
    [[ "$output" =~ '<script nonce="' ]]
}

@test "a second request within the throttle window sends no second email" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    run raw_form_post "/forgot-password" "identifier=hanne"
    [[ "$output" =~ "Check your email" ]]
    [ "$(outbox_count)" = "1" ]
}

@test "a reset link works only once" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    token=$(last_token)
    raw_form_post "/reset-password" "token=${token}&new_password=first111&confirm_password=first111" >/dev/null

    run raw_form_post "/reset-password" "token=${token}&new_password=second222&confirm_password=second222"
    [[ ! "$output" =~ "302 Found" ]]
    [[ "$output" =~ "already been used" ]]
    [[ ! "$output" =~ "new_password" ]]
    run raw_login hanne first111
    [[ "$output" =~ "302 Found" ]]
}

@test "using one link voids every other outstanding link for that account" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    first=$(last_token)
    # Step past the throttle window without waiting 5 minutes.
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE auth_email_link SET issued_at = issued_at - 600;"
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    second=$(last_token)
    [ "$first" != "$second" ]

    raw_form_post "/reset-password" "token=${second}&new_password=newpass456&confirm_password=newpass456" >/dev/null
    run raw_form_post "/reset-password" "token=${first}&new_password=other789&confirm_password=other789"
    [[ "$output" =~ "already been used" ]]
}

@test "an expired link is rejected" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    token=$(last_token)
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE auth_email_link SET expires_at = issued_at - 1;"
    run raw_form_post "/reset-password" "token=${token}&new_password=newpass456&confirm_password=newpass456"
    [[ ! "$output" =~ "302 Found" ]]
    [[ "$output" =~ "has expired" ]]
    run raw_login hanne oldpass123
    [[ "$output" =~ "302 Found" ]]
}

@test "a made-up or malformed token is rejected" {
    run raw_form_post "/reset-password" "token=$(printf 'a%.0s' {1..64})&new_password=x1234567&confirm_password=x1234567"
    [[ "$output" =~ "invalid" ]]
    run raw_form_post "/reset-password" "token=../../etc&new_password=x1234567&confirm_password=x1234567"
    [[ "$output" =~ "invalid" ]]
    run raw_form_post "/reset-password" "new_password=x1234567&confirm_password=x1234567"
    [[ "$output" =~ "invalid" ]]
}

@test "mismatched passwords keep the form up and leave the link usable" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    token=$(last_token)
    run raw_form_post "/reset-password" "token=${token}&new_password=aaa11111&confirm_password=bbb22222"
    [[ "$output" =~ "don&#39;t match" || "$output" =~ "don't match" ]]
    [[ "$output" =~ "Choose a new password" ]]
    [[ "$output" =~ "value=\"${token}\"" ]]
    run raw_form_post "/reset-password" "token=${token}&new_password=aaa11111&confirm_password=aaa11111"
    [[ "$output" =~ "302 Found" ]]
}

@test "the database stores only a hash of the token, never the token itself" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    token=$(last_token)
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT token_hash FROM auth_email_link;"
    [ -n "$output" ]
    [ "$output" != "$token" ]
}

@test "a failed send leaves the page response unchanged and doesn't count against the throttle" {
    add_user_with_email hanne hanne@example.com
    unset MAIL_TEST_OUTBOX
    raw_form_post "/forgot-password" "identifier=hanne" >"$TEST_DIR/page" 2>"$TEST_DIR/err"
    grep -q "Check your email" "$TEST_DIR/page"
    ! grep -q "MAIL_TEST_OUTBOX" "$TEST_DIR/page"
    grep -q "could not send reset email" "$TEST_DIR/err"

    export MAIL_TEST_OUTBOX="$TEST_DIR/outbox"
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    [ "$(outbox_count)" = "1" ]
}

@test "user email: stored lowercased, validated, unique, and shown in user list" {
    "$BIN" user add alice pass123 i >/dev/null
    "$BIN" user add bob pass123 i >/dev/null
    run "$BIN" user email alice Alice@Example.COM
    [[ "$output" =~ "Email updated" ]]
    run "$BIN" user list
    [[ "$output" =~ "email=alice@example.com" ]]

    run "$BIN" user email bob alice@example.com
    [[ "$output" =~ "already used" ]]
    run "$BIN" user email bob "not an email"
    [[ "$output" =~ "invalid email" ]]
    run "$BIN" user email bob $'bob@example.com\r\nBcc: x@evil.com'
    [[ "$output" =~ "invalid email" ]]

    run "$BIN" user email alice ""
    run "$BIN" user list
    [[ "$output" =~ "alice  cap=i  email=-" ]]
}

@test "the email column is added to a user table created before it existed" {
    sqlite3 "$TEST_DIR/.store/store.db" "CREATE TABLE user_old AS SELECT login, password_hash, cap, created_at, archived_at FROM auth_user; DROP TABLE auth_user; ALTER TABLE user_old RENAME TO user;"
    # A store whose accounts table is still named `user` predates migration 5.
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE system_state SET number_value = 4 WHERE name = 'store.schema_version';"
    "$BIN" user add alice pass123 i >/dev/null
    run raw_get "/login"
    run "$BIN" user email alice alice@example.com
    [[ "$output" =~ "Email updated" ]]
}

admin_cookie() {
    "$BIN" user add admin adminpass i >/dev/null
    "$BIN" user capabilities admin ia >/dev/null
    raw=$(raw_login admin adminpass)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    echo "$csrf" "session=${session}; csrf=${csrf}"
}

@test "an admin creates an account with an email, no password -- the setup link sets it and verifies the email" {
    read csrf cookie < <(admin_cookie)

    run raw_get "/admin-users" "" "$cookie"
    [[ "$output" =~ "Create and email setup link" ]]
    [[ ! "$output" =~ 'placeholder="password" required' ]]

    run raw_form_post "/admin-users-create" "csrf_token=${csrf}&login=hanne&email=Hanne%40Example.com&cap=i" "$cookie"
    [[ "$output" =~ "302 Found" ]]
    run "$BIN" user list
    [[ "$output" =~ "hanne  cap=i  email=hanne@example.com (unverified)" ]]
    [ "$(outbox_count)" = "1" ]
    run cat "$MAIL_TEST_OUTBOX"
    [[ "$output" =~ '"to":"hanne@example.com"' ]]
    [[ "$output" =~ "Set up your" ]]

    # Unverified: forgot-password sends nothing yet.
    run raw_form_post "/forgot-password" "identifier=hanne"
    [[ "$output" =~ "Check your email" ]]
    [ "$(outbox_count)" = "1" ]

    token=$(last_token)
    run raw_form_post "/reset-password" "token=${token}&new_password=chosen123&confirm_password=chosen123"
    [[ "$output" =~ "Location: /login?reset=1" ]]
    run raw_login hanne chosen123
    [[ "$output" =~ "302 Found" ]]
    run "$BIN" user list
    [[ "$output" =~ "email=hanne@example.com  active" ]]

    run raw_form_post "/forgot-password" "identifier=hanne"
    [ "$(outbox_count)" = "2" ]
}

@test "admin create needs a valid, unused email, and creates nothing otherwise" {
    read csrf cookie < <(admin_cookie)
    add_user_with_email taken taken@example.com
    for email in "" "not-an-email" "taken%40example.com"; do
        run raw_form_post "/admin-users-create" "csrf_token=${csrf}&login=newbie&email=${email}&cap=i" "$cookie"
        [[ "$output" =~ "email is required" || "$output" =~ "invalid email" || "$output" =~ "already used" ]]
    done
    run "$BIN" user list
    [[ ! "$output" =~ "newbie" ]]
    [ "$(outbox_count)" = "0" ]
}

@test "changing an email unverifies it and mails a verify link; resaving resends; an old link verifies nothing new" {
    read csrf cookie < <(admin_cookie)
    add_user_with_email hanne hanne@example.com

    run raw_form_post "/admin-users-email" "csrf_token=${csrf}&login=hanne&email=h.volpin%40example.com" "$cookie"
    [[ "$output" =~ "302 Found" ]]
    run "$BIN" user list
    [[ "$output" =~ "email=h.volpin@example.com (unverified)" ]]
    [ "$(outbox_count)" = "1" ]
    [ "$(last_link_page)" = "verify-email" ]
    first=$(last_token)

    run raw_form_post "/admin-users-email" "csrf_token=${csrf}&login=hanne&email=h.volpin%40example.com" "$cookie"
    [ "$(outbox_count)" = "2" ]

    # A link mailed to the previous address doesn't verify the new one.
    run raw_form_post "/admin-users-email" "csrf_token=${csrf}&login=hanne&email=hv%40example.com" "$cookie"
    run raw_form_post "/verify-email" "token=${first}&password=oldpass123"
    [[ "$output" =~ "invalid, has expired" ]]
    run "$BIN" user list
    [[ "$output" =~ "email=hv@example.com (unverified)" ]]

    run raw_form_post "/admin-users-email" "csrf_token=wrong&login=hanne&email=x%40example.com" "$cookie"
    [[ "$output" =~ "403 Forbidden" ]]
}

@test "an admin's email is verified by its verify link and password, but admins still never get reset emails" {
    "$BIN" user add boss bosspass i >/dev/null
    "$BIN" user capabilities boss ia >/dev/null
    run "$BIN" user email boss boss@example.com
    [[ "$output" =~ "Link sent to boss@example.com" ]]
    token=$(last_token)
    # The link can't set the admin's password ...
    run raw_form_post "/reset-password" "token=${token}&new_password=bossnew1&confirm_password=bossnew1"
    [[ "$output" =~ "invalid, has expired" ]]
    # ... it only confirms the address, with the current password.
    run raw_form_post "/verify-email" "token=${token}&password=bosspass"
    [[ "$output" =~ "Location: /login?verified=1" ]]
    run "$BIN" user list
    [[ "$output" =~ "boss  cap=ia  email=boss@example.com  active" ]]
    rm -f "$MAIL_TEST_OUTBOX"
    run raw_form_post "/forgot-password" "identifier=boss"
    [ "$(outbox_count)" = "0" ]
}

@test "user invite: CLI creates the account and mails the setup link" {
    run "$BIN" user invite radi Radi@Example.com i
    [[ "$output" =~ "Invited radi -- setup link sent to radi@example.com" ]]
    [ "$(outbox_count)" = "1" ]
    run raw_login radi ""
    [[ "$output" =~ "401 Unauthorized" ]]
    run raw_form_post "/reset-password" "token=$(last_token)&new_password=radipass1&confirm_password=radipass1"
    run raw_login radi radipass1
    [[ "$output" =~ "302 Found" ]]
}

@test "without mail configured, admins create accounts with a password, as before" {
    write_platform_config ""
    read csrf cookie < <(admin_cookie)
    run raw_get "/admin-users" "" "$cookie"
    [[ "$output" =~ 'placeholder="password"' ]]
    run raw_form_post "/admin-users-create" "csrf_token=${csrf}&login=hanne&password=pw123456&email=&cap=i" "$cookie"
    [[ "$output" =~ "302 Found" ]]
    run raw_login hanne pw123456
    [[ "$output" =~ "302 Found" ]]
    run "$BIN" user invite radi radi@example.com
    [[ "$output" =~ "mail isn't configured" ]]
}

@test "/account shows the email read-only; there is no self-service email form" {
    read session csrf < <(login_test_user "alice" "i")
    cookie="session=${session}; csrf=${csrf}"
    run raw_get "/account" "" "$cookie"
    [[ "$output" =~ "No email on file" ]]
    [[ ! "$output" =~ 'action="account-email"' ]]

    "$BIN" user email alice alice@example.com >/dev/null
    run raw_get "/account" "" "$cookie"
    [[ "$output" =~ "alice@example.com (not verified yet" ]]

    run raw_form_post "/account-email" "csrf_token=${csrf}&email=evil%40example.com&current_password=testpass123" "$cookie"
    run "$BIN" user list
    [[ "$output" =~ "email=alice@example.com" ]]
}

# --- Email-link hardening (doc/auth.md, "Emailed links") ---

@test "an invited account has no password, so it can't log in with anything before setup" {
    "$BIN" user invite radi radi@example.com i >/dev/null
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT password_hash FROM auth_user WHERE login = 'radi';"
    [ "$output" = "!no-password" ]
    run raw_login radi '!no-password'
    [[ "$output" =~ "401 Unauthorized" ]]
}

@test "fixing a mistyped address cuts off the link sent to the wrong one" {
    read csrf cookie < <(admin_cookie)
    run raw_form_post "/admin-users-create" "csrf_token=${csrf}&login=maya&email=maya%40typo.example.com&cap=i" "$cookie"
    [ "$(last_link_page)" = "reset-password" ]
    typo_token=$(last_token)

    run raw_form_post "/admin-users-email" "csrf_token=${csrf}&login=maya&email=maya%40example.com" "$cookie"
    [ "$(outbox_count)" = "2" ]

    run raw_form_post "/reset-password" "token=${typo_token}&new_password=stolen123&confirm_password=stolen123"
    [[ "$output" =~ "invalid, has expired" ]]
    run raw_login maya stolen123
    [[ "$output" =~ "401 Unauthorized" ]]

    # The link to the corrected address works.
    run raw_form_post "/reset-password" "token=$(last_token)&new_password=mine12345&confirm_password=mine12345"
    [[ "$output" =~ "Location: /login?reset=1" ]]
    run "$BIN" user list
    [[ "$output" =~ "maya  cap=i  email=maya@example.com  active" ]]
}

@test "clearing an address voids its outstanding links" {
    "$BIN" user invite radi radi@example.com i >/dev/null
    token=$(last_token)
    "$BIN" user email radi "" >/dev/null
    run raw_form_post "/reset-password" "token=${token}&new_password=radipass1&confirm_password=radipass1"
    [[ "$output" =~ "invalid, has expired" ]]
}

@test "setting an email on an account with a password sends a verify link, which can't set the password" {
    "$BIN" user add hanne oldpass123 i >/dev/null
    "$BIN" user email hanne hanne@example.com >/dev/null
    [ "$(last_link_page)" = "verify-email" ]
    run cat "$MAIL_TEST_OUTBOX"
    [[ "$output" =~ "Confirm your email" ]]
    token=$(last_token)

    run raw_form_post "/reset-password" "token=${token}&new_password=taken999&confirm_password=taken999"
    [[ "$output" =~ "invalid, has expired" ]]
    run raw_login hanne taken999
    [[ "$output" =~ "401 Unauthorized" ]]
}

@test "a verify link needs the account's current password, and then verifies the address" {
    "$BIN" user add hanne oldpass123 i >/dev/null
    "$BIN" user email hanne hanne@example.com >/dev/null
    token=$(last_token)

    run raw_get "/verify-email"
    [[ "$output" =~ "Your current password" ]]
    [[ "$output" =~ "Referrer-Policy: no-referrer" ]]

    run raw_form_post "/verify-email" "token=${token}&password=wrongpass"
    [[ "$output" =~ "isn&#39;t this account&#39;s password" || "$output" =~ "isn't this account's password" ]]
    run "$BIN" user list
    [[ "$output" =~ "(unverified)" ]]

    run raw_form_post "/verify-email" "token=${token}&password=oldpass123"
    [[ "$output" =~ "Location: /login?verified=1" ]]
    run "$BIN" user list
    [[ "$output" =~ "hanne  cap=i  email=hanne@example.com  active" ]]

    # Used once only.
    run raw_form_post "/verify-email" "token=${token}&password=oldpass123"
    [[ "$output" =~ "invalid, has expired" ]]
}

@test "a setup or reset link can't be used on /verify-email" {
    "$BIN" user invite radi radi@example.com i >/dev/null
    run raw_form_post "/verify-email" "token=$(last_token)&password=anything"
    [[ "$output" =~ "invalid, has expired" ]]
}

@test "admins can't be invited by email" {
    run "$BIN" user invite boss boss@example.com ia
    [[ "$output" =~ "Admin accounts can't be set up by email" ]]
    run "$BIN" user list
    [[ ! "$output" =~ "boss" ]]
    [ "$(outbox_count)" = "0" ]
}

@test "a setup link stops working if the invited account is made an admin before using it" {
    "$BIN" user invite radi radi@example.com i >/dev/null
    token=$(last_token)
    "$BIN" user capabilities radi ia >/dev/null
    run raw_form_post "/reset-password" "token=${token}&new_password=radipass1&confirm_password=radipass1"
    [[ "$output" =~ "invalid, has expired" ]]
}

@test "using a reset link ends the account's existing sessions" {
    add_user_with_email hanne hanne@example.com
    session=$(raw_login hanne oldpass123 | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    run raw_get "/" "" "session=${session}"
    [[ "$output" =~ "200 OK" ]]
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    raw_form_post "/reset-password" "token=$(last_token)&new_password=newpass456&confirm_password=newpass456" >/dev/null
    run raw_get "/" "" "session=${session}"
    [[ "$output" =~ "Location: /login" ]]
}
