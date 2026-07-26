#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add admin secret123 ia
    "$BIN" user add alice secret123 i
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

admin_session() {
    local raw session csrf
    raw=$(raw_login admin secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    echo "${session} ${csrf}"
}

# Builds a real multipart/form-data body at $TEST_DIR/body.bin from
# alternating field/value pairs, and POSTs it to /settings-save --
# piping stdin straight into `run "$BIN"` doesn't carry through bats'
# own `run` correctly (same reasoning as auth.bats' raw_admin_action),
# so this runs the binary directly and lets the caller wrap the *call*
# in `run` instead. A value starting with "@" is treated as a file
# path to upload (name="logo_file"; filename=...; real bytes), every
# other value is a plain text field -- covers both without a second
# helper.
BOUNDARY="platformtestboundary"

post_settings() {
    local session="$1" csrf="$2"
    shift 2
    local body="${TEST_DIR}/body.bin"
    : > "$body"
    printf -- '--%s\r\nContent-Disposition: form-data; name="csrf_token"\r\n\r\n%s\r\n' "$BOUNDARY" "$csrf" >> "$body"
    while [ "$#" -ge 2 ]; do
        local field="$1" value="$2"
        shift 2
        if [[ "$value" == @* ]]; then
            local filepath="${value#@}"
            printf -- '--%s\r\nContent-Disposition: form-data; name="%s"; filename="upload.png"\r\nContent-Type: image/png\r\n\r\n' "$BOUNDARY" "$field" >> "$body"
            cat "$filepath" >> "$body"
            printf '\r\n' >> "$body"
        else
            printf -- '--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' "$BOUNDARY" "$field" "$value" >> "$body"
        fi
    done
    printf -- '--%s--\r\n' "$BOUNDARY" >> "$body"

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/settings-save" QUERY_STRING="" \
        CONTENT_TYPE="multipart/form-data; boundary=${BOUNDARY}" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" HTTP_X_CSRF_TOKEN="${csrf}" \
        "$BIN" < "$body"
}

make_test_png() {
    python3 -c "
import base64
open('$1','wb').write(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='))
"
}

@test "/settings requires Admin capability, not just baseline" {
    read session csrf < <(admin_session)

    raw=$(raw_login alice secret123)
    alice_session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/settings" QUERY_STRING="" \
        HTTP_COOKIE="session=${alice_session}" run "$BIN"
    [[ "$output" =~ "403 Forbidden" ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/settings" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Save settings" ]]
}

@test "settings-save without the matching CSRF token is rejected" {
    read session csrf < <(admin_session)

    # Real session cookie (including its real csrf), but no
    # HTTP_X_CSRF_TOKEN header and no csrf_token field in the body --
    # same "submitted token missing/wrong, cookie is real" shape as
    # auth.bats' own CSRF-header test.
    body="${TEST_DIR}/nocsrf.bin"
    printf -- '--%s\r\nContent-Disposition: form-data; name="site_name"\r\n\r\nShould Not Save\r\n--%s--\r\n' \
        "$BOUNDARY" "$BOUNDARY" > "$body"
    # Plain command substitution, not bats' `run` -- piping/redirecting
    # stdin into `run "$BIN"` directly doesn't carry through bats' own
    # `run` correctly (same reasoning as auth.bats' raw_admin_action).
    output=$(GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/settings-save" QUERY_STRING="" \
        CONTENT_TYPE="multipart/form-data; boundary=${BOUNDARY}" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" \
        "$BIN" < "$body")
    [[ "$output" =~ "403 Forbidden" ]]
    [[ "$output" =~ "CSRF check failed" ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/settings" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" run "$BIN"
    [[ ! "$output" =~ "Should Not Save" ]]
}

@test "settings-save persists site_name, a color, the checkbox, and the chat prompt" {
    read session csrf < <(admin_session)
    run post_settings "$session" "$csrf" \
        "site_name" "My Lab" \
        "hide_home_heading" "1" \
        "color_accent" "#ff6600" \
        "system_prompt_extra" "Always be concise."
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: settings" ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/settings" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" run "$BIN"
    [[ "$output" =~ 'value="My Lab"' ]]
    [[ "$output" =~ 'value="#ff6600"' ]]
    [[ "$output" =~ "checked" ]]
    [[ "$output" =~ "Always be concise." ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" run "$BIN"
    [[ "$output" =~ "<title>My Lab</title>" ]]
    [[ "$output" =~ "platform-accent: #ff6600;" ]]
}

@test "settings-save rejects a color value that would break out of the <style> block" {
    read session csrf < <(admin_session)
    run post_settings "$session" "$csrf" "color_accent" "</style><script>alert(1)</script>"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Invalid color value" ]]
    [[ ! "$output" =~ "<script>alert" ]]
}

@test "settings-save accepts a real PNG logo upload and rejects a fake one" {
    read session csrf < <(admin_session)
    make_test_png "${TEST_DIR}/real.png"
    run post_settings "$session" "$csrf" "logo_file" "@${TEST_DIR}/real.png"
    [[ "$output" =~ "302 Found" ]]
    [ -f "${TEST_DIR}/theme-assets/logo.png" ]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" run "$BIN"
    [[ "$output" =~ 'src="theme-asset?name=logo.png"' ]]

    echo "not a real png" > "${TEST_DIR}/fake.png"
    run post_settings "$session" "$csrf" "logo_file" "@${TEST_DIR}/fake.png"
    [[ "$output" =~ "must be a real PNG file" ]]
}
