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

# The token from the most recently sent reset link.
last_token() {
    tail -1 "$MAIL_TEST_OUTBOX" | grep -o 'reset-password?token=[0-9a-f]*' | head -1 | sed 's/.*token=//'
}

add_user_with_email() {
    "$BIN" user add "$1" oldpass123 i >/dev/null
    "$BIN" user email "$1" "$2" >/dev/null
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
    [[ "$output" =~ "https://lims.example.com/reset-password?token=" ]]
    [[ ! "$output" =~ "example.com//reset-password" ]]

    token=$(last_token)
    [ "${#token}" = "64" ]
    run raw_get "/reset-password" "token=${token}"
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

    run raw_get "/reset-password" "token=${token}"
    [[ "$output" =~ "already been used" ]]
    [[ ! "$output" =~ "new_password" ]]
    run raw_form_post "/reset-password" "token=${token}&new_password=second222&confirm_password=second222"
    [[ ! "$output" =~ "302 Found" ]]
    run raw_login hanne first111
    [[ "$output" =~ "302 Found" ]]
}

@test "using one link voids every other outstanding link for that account" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    first=$(last_token)
    # Step past the throttle window without waiting 5 minutes.
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE password_reset SET issued_at = issued_at - 600;"
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    second=$(last_token)
    [ "$first" != "$second" ]

    raw_form_post "/reset-password" "token=${second}&new_password=newpass456&confirm_password=newpass456" >/dev/null
    run raw_get "/reset-password" "token=${first}"
    [[ "$output" =~ "already been used" ]]
}

@test "an expired link is rejected" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    token=$(last_token)
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE password_reset SET expires_at = issued_at - 1;"
    run raw_get "/reset-password" "token=${token}"
    [[ "$output" =~ "has expired" ]]
    run raw_form_post "/reset-password" "token=${token}&new_password=newpass456&confirm_password=newpass456"
    [[ ! "$output" =~ "302 Found" ]]
    run raw_login hanne oldpass123
    [[ "$output" =~ "302 Found" ]]
}

@test "a made-up or malformed token is rejected" {
    run raw_get "/reset-password" "token=$(printf 'a%.0s' {1..64})"
    [[ "$output" =~ "invalid" ]]
    run raw_get "/reset-password" "token=../../etc"
    [[ "$output" =~ "invalid" ]]
    run raw_get "/reset-password"
    [[ "$output" =~ "invalid" ]]
}

@test "mismatched passwords keep the form up and leave the link usable" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    token=$(last_token)
    run raw_form_post "/reset-password" "token=${token}&new_password=aaa11111&confirm_password=bbb22222"
    [[ "$output" =~ "don&#39;t match" || "$output" =~ "don't match" ]]
    [[ "$output" =~ "Choose a new password" ]]
    run raw_form_post "/reset-password" "token=${token}&new_password=aaa11111&confirm_password=aaa11111"
    [[ "$output" =~ "302 Found" ]]
}

@test "the database stores only a hash of the token, never the token itself" {
    add_user_with_email hanne hanne@example.com
    raw_form_post "/forgot-password" "identifier=hanne" >/dev/null
    token=$(last_token)
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT token_hash FROM password_reset;"
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
    sqlite3 "$TEST_DIR/.store/store.db" "CREATE TABLE user_old AS SELECT login, password_hash, cap, created_at, archived_at FROM user; DROP TABLE user; ALTER TABLE user_old RENAME TO user;"
    "$BIN" user add alice pass123 i >/dev/null
    run raw_get "/login"
    run "$BIN" user email alice alice@example.com
    [[ "$output" =~ "Email updated" ]]
}

@test "admins can set a user's email, and give one at creation" {
    "$BIN" user add admin adminpass i >/dev/null
    "$BIN" user capabilities admin ia >/dev/null
    raw=$(raw_login admin adminpass)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    cookie="session=${session}; csrf=${csrf}"

    run raw_form_post "/admin-users-create" "csrf_token=${csrf}&login=hanne&password=pw123456&email=hanne%40example.com&cap=i" "$cookie"
    [[ "$output" =~ "302 Found" ]]
    run "$BIN" user list
    [[ "$output" =~ "hanne  cap=i  email=hanne@example.com" ]]

    run raw_form_post "/admin-users-create" "csrf_token=${csrf}&login=dup&password=pw123456&email=hanne%40example.com&cap=i" "$cookie"
    [[ "$output" =~ "already used" ]]
    run "$BIN" user list
    [[ ! "$output" =~ "dup" ]]

    run raw_form_post "/admin-users-email" "csrf_token=${csrf}&login=hanne&email=h.volpin%40example.com" "$cookie"
    [[ "$output" =~ "302 Found" ]]
    run "$BIN" user list
    [[ "$output" =~ "email=h.volpin@example.com" ]]

    run raw_get "/admin-users" "" "$cookie"
    [[ "$output" =~ 'value="h.volpin@example.com"' ]]

    run raw_form_post "/admin-users-email" "csrf_token=wrong&login=hanne&email=x%40example.com" "$cookie"
    [[ "$output" =~ "403 Forbidden" ]]
}

@test "/account-email sets the user's own email, but only with the current password" {
    read session csrf < <(login_test_user "alice" "i")
    cookie="session=${session}; csrf=${csrf}"

    run raw_form_post "/account-email" "csrf_token=${csrf}&email=alice%40example.com&current_password=wrong" "$cookie"
    [[ "$output" =~ "Current password is incorrect." ]]
    run "$BIN" user list
    [[ "$output" =~ "email=-" ]]

    run raw_form_post "/account-email" "csrf_token=${csrf}&email=alice%40example.com&current_password=testpass123" "$cookie"
    [[ "$output" =~ "Email saved." ]]
    [[ "$output" =~ 'value="alice@example.com"' ]]
    run "$BIN" user list
    [[ "$output" =~ "email=alice@example.com" ]]

    run raw_form_post "/account-email" "csrf_token=wrong&email=evil%40example.com&current_password=testpass123" "$cookie"
    [[ "$output" =~ "CSRF check failed." ]]
    run "$BIN" user list
    [[ "$output" =~ "email=alice@example.com" ]]
}
