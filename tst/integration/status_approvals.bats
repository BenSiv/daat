#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
}

teardown() {
    cleanup_test_env
}

@test "daat status and doctor work before and after init, including --json and drift detection" {
    run "$BIN" status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "not initialized" ]]
    [[ "$output" =~ "cmark-gfm" ]]

    run "$BIN" doctor --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.store.initialized')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]

    rm -f config.lua theme.lua
    run "$BIN" init --with-examples
    [ "$status" -eq 0 ]

    run "$BIN" status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.store.initialized')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.schemas.in_sync')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.views[0].status')" = "unapproved" ]
    [ "$(printf '%s' "$output" | jq -r '.extensions[0].status')" = "unapproved" ]

    # Sync schemas and approve view + extension, then mutate SQL to verify 'drifted' status.
    "$BIN" schema sync >/dev/null
    "$BIN" view approve widgets-in-stock >/dev/null
    "$BIN" extension approve widget-quantity-range >/dev/null

    run "$BIN" status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.schemas.in_sync')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.views[0].status')" = "approved" ]
    [ "$(printf '%s' "$output" | jq -r '.extensions[0].status')" = "approved" ]

    sed -i 's/ORDER BY label ASC/ORDER BY id DESC/' views/widgets-in-stock.lua
    run "$BIN" status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.views[0].status')" = "drifted" ]
}

@test "/system-status enforces Admin + CSRF and approves/revokes schemas, views, and extensions in the UI" {
    rm -f config.lua theme.lua
    "$BIN" init --with-examples >/dev/null
    write_config
    read admin_session admin_csrf < <(login_test_user "admin_u" "ia")
    read user_session user_csrf < <(login_test_user "plain_u" "i")

    admin_cookie="session=${admin_session}; csrf=${admin_csrf}"
    user_cookie="session=${user_session}; csrf=${user_csrf}"

    # Non-admin receives 403 Forbidden.
    out=$(raw_get "/system-status" "" "$user_cookie")
    [[ "$out" =~ "403 Forbidden" ]]

    # /system links to Status & Approvals for Admin.
    sys_out=$(raw_get "/system" "" "$admin_cookie")
    [[ "$sys_out" =~ "Status &amp; Approvals" ]]

    # Admin sees /system-status with auto-synced schemas + Approve actions for views/extensions.
    st_out=$(raw_get "/system-status" "" "$admin_cookie")
    [[ "$st_out" =~ "200 OK" ]]
    [[ "$st_out" =~ "Up to date" ]]
    [[ "$st_out" =~ "widgets-in-stock" ]]
    [[ "$st_out" =~ "widget-quantity-range" ]]

    # Missing CSRF is rejected.
    bad_csrf=$(raw_post "/system-status-view-approve" "name=widgets-in-stock" "$admin_cookie" "wrong")
    [[ "$bad_csrf" =~ "403 Forbidden" ]]

    "$BIN" entity create category label="Fasteners" >/dev/null
    "$BIN" entity create widget label="Bolt" quantity=10 status=in_stock category=1 >/dev/null

    # Before view approval, /view?view_name=widgets-in-stock is refused.
    unapp_view=$(raw_get "/view" "view_name=widgets-in-stock" "$admin_cookie")
    [[ "$unapp_view" =~ "403 Forbidden" ]]

    # 2. Approve view via UI POST -> /view renders rows; then revoke -> 403 again.
    app_v=$(raw_post "/system-status-view-approve" "csrf_token=${admin_csrf}&name=widgets-in-stock" "$admin_cookie" "$admin_csrf")
    [[ "$app_v" =~ "302 Found" ]]
    ok_view=$(raw_get "/view" "view_name=widgets-in-stock" "$admin_cookie")
    [[ "$ok_view" =~ "200 OK" ]]
    [[ "$ok_view" =~ "Bolt" ]]

    rev_v=$(raw_post "/system-status-view-revoke" "csrf_token=${admin_csrf}&name=widgets-in-stock" "$admin_cookie" "$admin_csrf")
    [[ "$rev_v" =~ "302 Found" ]]
    rev_view=$(raw_get "/view" "view_name=widgets-in-stock" "$admin_cookie")
    [[ "$rev_view" =~ "403 Forbidden" ]]

    # 3. Approve extension via UI POST -> negative quantity is rejected by before-hook!
    app_e=$(raw_post "/system-status-extension-approve" "csrf_token=${admin_csrf}&name=widget-quantity-range" "$admin_cookie" "$admin_csrf")
    [[ "$app_e" =~ "302 Found" ]]
    run "$BIN" entity create widget label="Bad" quantity=-5
    [[ "$output" =~ "quantity cannot be negative" ]]
}
