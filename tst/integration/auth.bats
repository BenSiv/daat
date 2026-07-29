#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
}

teardown() {
    cleanup_test_env
}

raw_login() {
    local login="$1"
    local password="$2"
    printf 'login=%s&password=%s' "$login" "$password" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN"
}

# A POST to one of the /admin-users-* routes with a real request body --
# piping straight into `run "$BIN"` doesn't carry stdin through bats'
# `run` correctly, so (matching raw_login above) this runs the binary
# directly and lets the caller wrap the *function call* in `run` instead.
raw_admin_action() {
    local path_info="$1"
    local cookie="$2"
    local body="$3"
    printf '%s' "$body" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="$path_info" QUERY_STRING="" \
        HTTP_COOKIE="$cookie" "$BIN"
}

@test "user add creates a login that can authenticate" {
    "$BIN" user add alice secret123 i
    run "$BIN" user list
    [[ "$output" =~ "alice" ]]
    [[ "$output" =~ "cap=i" ]]
}

@test "login with the correct password succeeds and issues session + csrf cookies" {
    "$BIN" user add alice secret123 i
    run raw_login alice secret123
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /" ]]
    [[ "$output" =~ "Set-Cookie: session=alice." ]]
    [[ "$output" =~ "HttpOnly" ]]
    [[ "$output" =~ "Set-Cookie: csrf=" ]]
}

@test "login with the wrong password is rejected without revealing whether the login exists" {
    "$BIN" user add alice secret123 i
    run raw_login alice wrongpass
    [[ "$output" =~ "401 Unauthorized" ]]
    [[ "$output" =~ "Invalid login or password" ]]

    run raw_login nosuchuser whatever
    [[ "$output" =~ "401 Unauthorized" ]]
    [[ "$output" =~ "Invalid login or password" ]]
}

@test "the login page itself is wrapped in the real page shell, not a bare content fragment" {
    # task #89 regression: /login used to print html.render_login's raw
    # fragment directly, with no <head>/favicon <link>/theme :root{}
    # block at all -- a deployment's theme.lua colors/site name never
    # applied to the one page every user sees before authenticating,
    # and the browser tab fell back to whatever favicon it had cached
    # from a previous origin.
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/login" QUERY_STRING="" run "$BIN"
    [[ "$output" =~ "<!doctype html>" ]]
    [[ "$output" =~ '<link rel="icon" type="image/png" href="theme-asset?name=favicon.png">' ]]
    [[ "$output" =~ "<title>Log in</title>" ]]

    run raw_login someone wrongpass
    [[ "$output" =~ "<!doctype html>" ]]
    [[ "$output" =~ '<link rel="icon"' ]]
}

@test "the login page has no nav links and no chat widget for an unauthenticated visitor" {
    # Found live 2026-07-22, right after the page-shell fix above
    # landed: page_shell's nav rail and chat widget were unconditional,
    # so /login (author == nil) rendered a fully clickable nav (every
    # link just bounces back to /login) and a chat widget someone could
    # actually try to type into. The backend already rejects an
    # unauthenticated /chat-start or /chat-message before it ever
    # reaches the agent (cgi.handle_request's own session check runs
    # first -- no billing/security exposure by itself), but showing
    # controls nobody can use is confusing UX and worth not doing.
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/login" QUERY_STRING="" run "$BIN"
    [[ ! "$output" =~ '<a class="platform-nav-link' ]]
    [[ ! "$output" =~ 'id="platform-chat-widget"' ]]

    "$BIN" user add alice secret123 i
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" run "$BIN"
    [[ "$output" =~ '<a class="platform-nav-link' ]]
    [[ "$output" =~ 'id="platform-chat-widget"' ]]
}

@test "an unauthenticated /chat-start or /chat-message never reaches the agent" {
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-start" QUERY_STRING="" run "$BIN"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /login" ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" run "$BIN"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /login" ]]
}

@test "an archived user can no longer log in" {
    "$BIN" user add alice secret123 i
    "$BIN" user archive alice
    run raw_login alice secret123
    [[ "$output" =~ "401 Unauthorized" ]]
}

@test "a request with no session cookie is redirected to /login" {
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/" QUERY_STRING="" run "$BIN"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /login" ]]
}

@test "a request with a tampered session cookie is redirected to /login" {
    "$BIN" user add alice secret123 i
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}tampered" run "$BIN"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /login" ]]
}

@test "a valid session cookie grants access, and logout clears it" {
    "$BIN" user add alice secret123 i
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/logout" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ "Location: /login" ]]
    [[ "$output" =~ "Set-Cookie: session=; Path=/; Max-Age=0" ]]
    [[ "$output" =~ "Set-Cookie: csrf=; Path=/; Max-Age=0" ]]
}

@test "a capability change takes effect on the very next request, not only after the session expires" {
    "$BIN" user add alice secret123 ""
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')

    mkdir -p schemas
    cat > schemas/widget.lua <<'EOF'
return {
  name = "widget",
  fields = { {name = "label", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/widget.lua

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/browse" QUERY_STRING="type=widget" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ "403 Forbidden" ]]

    "$BIN" user capabilities alice i

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/browse" QUERY_STRING="type=widget" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
}

@test "a mutating POST without the matching CSRF header is rejected" {
    "$BIN" user add alice secret123 i
    mkdir -p schemas
    cat > schemas/widget.lua <<'EOF'
return {
  name = "widget",
  fields = { {name = "label", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/widget.lua
    "$BIN" entity create widget label=Test1

    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/archive" QUERY_STRING="type=widget&entity_id=1" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" run "$BIN"
    [[ "$output" =~ "403 Forbidden" ]]
    [[ "$output" =~ "CSRF check failed" ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/archive" QUERY_STRING="type=widget&entity_id=1" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" HTTP_X_CSRF_TOKEN="${csrf}" run "$BIN"
    [[ "$output" =~ '"success":true' ]]
}

@test "/admin-users requires Admin capability, not just baseline" {
    "$BIN" user add alice secret123 i
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/admin-users" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ "403 Forbidden" ]]

    "$BIN" user capabilities alice ia

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/admin-users" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Manage users" ]]
    [[ "$output" =~ "alice" ]]
}

@test "admin-users-create adds a user that shows up on the page, via the plain form-field CSRF token" {
    "$BIN" user add alice secret123 ia
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')

    # Note: no HTTP_X_CSRF_TOKEN header here -- a plain HTML <form> POST
    # (unlike a JS fetch() call) can't attach a custom header at all, so
    # this exercises the form-field fallback in cgi.lua's require_csrf.
    cookie="session=${session}; csrf=${csrf}"
    body="csrf_token=${csrf}&login=bob&password=bobpass123&cap=i"
    run raw_admin_action "/admin-users-create" "$cookie" "$body"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: admin-users" ]]

    run "$BIN" user list
    [[ "$output" =~ "bob" ]]
}

@test "admin-users-create without the matching CSRF token is rejected" {
    "$BIN" user add alice secret123 ia
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')

    cookie="session=${session}; csrf=${csrf}"
    body="csrf_token=wrong&login=bob&password=bobpass123&cap=i"
    run raw_admin_action "/admin-users-create" "$cookie" "$body"
    [[ "$output" =~ "403 Forbidden" ]]
    [[ "$output" =~ "CSRF check failed" ]]

    run "$BIN" user list
    [[ ! "$output" =~ "bob" ]]
}

@test "admin-users-capabilities, admin-users-password, and admin-users-archive/unarchive all work via the admin page" {
    "$BIN" user add alice secret123 ia
    "$BIN" user add bob bobpass123 i
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    cookie="session=${session}; csrf=${csrf}"

    run raw_admin_action "/admin-users-capabilities" "$cookie" "csrf_token=${csrf}&login=bob&cap=is"
    [[ "$output" =~ "302 Found" ]]
    run "$BIN" user list
    [[ "$output" =~ "bob" ]]
    [[ "$output" =~ "cap=is" ]]

    run raw_admin_action "/admin-users-password" "$cookie" "csrf_token=${csrf}&login=bob&password=newpass456"
    [[ "$output" =~ "302 Found" ]]
    run raw_login bob newpass456
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Set-Cookie: session=bob." ]]

    run raw_admin_action "/admin-users-archive" "$cookie" "csrf_token=${csrf}&login=bob"
    [[ "$output" =~ "302 Found" ]]
    run raw_login bob newpass456
    [[ "$output" =~ "401 Unauthorized" ]]

    run raw_admin_action "/admin-users-unarchive" "$cookie" "csrf_token=${csrf}&login=bob"
    [[ "$output" =~ "302 Found" ]]
    run raw_login bob newpass456
    [[ "$output" =~ "302 Found" ]]
}

@test "/admin-users renders Archive as btn-danger (a one-way negative action) and Unarchive as plain btn-secondary" {
    "$BIN" user add alice secret123 ia
    "$BIN" user add bob bobpass123 i
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    cookie="session=${session}; csrf=${csrf}"

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/admin-users" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ 'class="btn btn-danger">Archive</button>' ]]

    run raw_admin_action "/admin-users-archive" "$cookie" "csrf_token=${csrf}&login=bob"
    [[ "$output" =~ "302 Found" ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/admin-users" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ 'class="btn btn-secondary">Unarchive</button>' ]]
    [[ ! "$output" =~ 'class="btn btn-danger">Unarchive</button>' ]]
}

@test "/account-password lets a plain baseline user change their own password (no Admin capability needed)" {
    read session csrf < <(login_test_user "alice" "i")
    cookie="session=${session}; csrf=${csrf}"

    run raw_admin_action "/account-password" "$cookie" "csrf_token=${csrf}&current_password=testpass123&new_password=newpass456"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Password changed." ]]

    run raw_login "alice" "newpass456"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Set-Cookie: session=alice." ]]
}

@test "/account-password rejects a wrong current password, and the password stays unchanged" {
    read session csrf < <(login_test_user "bob" "i")
    cookie="session=${session}; csrf=${csrf}"

    run raw_admin_action "/account-password" "$cookie" "csrf_token=${csrf}&current_password=wrongpass&new_password=newpass456"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Current password is incorrect." ]]

    run raw_login "bob" "testpass123"
    [[ "$output" =~ "302 Found" ]]
}

@test "/account-password always targets the requester's own login, never an arbitrary one from the form" {
    "$BIN" user add carol carolpass123 i
    read session csrf < <(login_test_user "dave" "i")
    cookie="session=${session}; csrf=${csrf}"

    # Even if a login field were somehow smuggled in, the route reads
    # `author` from the verified session, never from form data -- this
    # confirms the real route has no way for a smuggled `login` field to
    # redirect the change onto a different account.
    run raw_admin_action "/account-password" "$cookie" "csrf_token=${csrf}&login=carol&current_password=testpass123&new_password=newpass456"
    [[ "$output" =~ "Password changed." ]]

    run raw_login "carol" "carolpass123"
    [[ "$output" =~ "302 Found" ]]
    run raw_login "dave" "newpass456"
    [[ "$output" =~ "302 Found" ]]
}

@test "/account-password requires the matching CSRF token" {
    read session csrf < <(login_test_user "erin" "i")
    cookie="session=${session}; csrf=${csrf}"

    run raw_admin_action "/account-password" "$cookie" "csrf_token=wrong-token&current_password=testpass123&new_password=newpass456"
    [[ "$output" =~ "403 Forbidden" ]]

    run raw_login "erin" "testpass123"
    [[ "$output" =~ "302 Found" ]]
}

@test "GET /account-password renders the form for any logged-in user" {
    read session csrf < <(login_test_user "frank" "i")

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/account-password" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Change password" ]]
    [[ "$output" =~ 'name="current_password"' ]]
    [[ "$output" =~ 'name="new_password"' ]]
}
