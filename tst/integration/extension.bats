#!/usr/bin/env bats
# UI plugin surface (doc/plugin-system-research.md, brex 757245439): an
# approved extension declaring capabilities.ui gets a page at
# /ext/<name> plus a sidebar nav entry, rendered from a plain Lua table
# of canvas elements -- never raw HTML from the extension itself.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p schemas
    cat > schemas/widget.lua <<'EOF'
return {
  name = "widget",
  fields = { {name = "label", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/widget.lua

    mkdir -p extensions/canvas-demo
    cat > extensions/canvas-demo/manifest.lua <<'EOF'
return {
    name = "canvas-demo",
    events = {},
    entity_types = {},
    capabilities = {
        read = {},
        write = {"entity"},
        net = "none",
        ui = {label = "Canvas Demo", icon = "🧪"},
    },
}
EOF
    cat > extensions/canvas-demo/main.lua <<'EOF'
return {
    render = function(ctx)
        return {elements = {
            {type = "heading", text = "Canvas Demo"},
            {type = "button", label = "Bump", action = "bump"},
        }}
    end,
    actions = {
        bump = function(ctx, args)
            ctx.create_entity("widget", {label = "bumped"})
            return {elements = {
                {type = "text", text = "Bumped!"},
            }}
        end,
    },
}
EOF

    mkdir -p extensions/no-ui-demo
    cat > extensions/no-ui-demo/manifest.lua <<'EOF'
return {
    name = "no-ui-demo",
    events = {"entity.before_create"},
    entity_types = {"widget"},
    capabilities = {read = {}, write = {}, net = "none"},
}
EOF
    cat > extensions/no-ui-demo/main.lua <<'EOF'
return {on_before = function(new, old, ctx) return {} end}
EOF

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "plainuser" "i")
}

teardown() {
    cleanup_test_env
}

@test "GET /ext/<name> 404s for an unapproved extension" {
    run_cgi "/ext/canvas-demo"
    [[ "$output" =~ "404 Not Found" ]]
}

@test "GET /ext/<name> renders the extension's canvas once approved" {
    "$BIN" extension approve canvas-demo
    run_cgi "/ext/canvas-demo"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Canvas Demo" ]]
    [[ "$output" =~ "Bump" ]]
    [[ "$output" =~ 'data-action="bump"' ]]
}

@test "editing capabilities.ui invalidates approval, same as any other capability change" {
    "$BIN" extension approve canvas-demo
    run_cgi "/ext/canvas-demo"
    [[ "$output" =~ "200 OK" ]]

    sed -i 's/icon = "🧪"/icon = "🔧"/' extensions/canvas-demo/manifest.lua
    run_cgi "/ext/canvas-demo"
    [[ "$output" =~ "404 Not Found" ]]

    "$BIN" extension approve canvas-demo
    run_cgi "/ext/canvas-demo"
    [[ "$output" =~ "200 OK" ]]
}

@test "GET /ext/<name> 404s for an approved extension with no capabilities.ui at all" {
    "$BIN" extension approve no-ui-demo
    run_cgi "/ext/no-ui-demo"
    [[ "$output" =~ "404 Not Found" ]]
}

@test "the nav rail includes the plugin's entry only once approved" {
    run_cgi "/"
    [[ ! "$output" =~ "ext/canvas-demo" ]]

    "$BIN" extension approve canvas-demo
    run_cgi "/"
    [[ "$output" =~ "ext/canvas-demo" ]]
    [[ "$output" =~ "Canvas Demo" ]]
}

@test "POST /ext/<name>/action runs the named action, gated by write.entity, and returns the re-rendered canvas" {
    "$BIN" extension approve canvas-demo
    output=$(raw_post_json "/ext/canvas-demo/action" '{"action":"bump","args":{}}' \
        "session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" "${TEST_CSRF_TOKEN}")
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Bumped!" ]]

    run "$BIN" entity show widget 1
    [[ "$output" =~ "bumped" ]]
    [[ "$output" =~ "extension:canvas-demo" ]]
}

@test "POST /ext/<name>/action requires the matching CSRF token" {
    "$BIN" extension approve canvas-demo
    output=$(printf '%s' '{"action":"bump","args":{}}' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/ext/canvas-demo/action" QUERY_STRING="" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" "$BIN")
    [[ "$output" =~ "403 Forbidden" ]]

    run "$BIN" entity list widget
    [[ ! "$output" =~ "#1" ]]
}

@test "POST /ext/<name>/action 404s for an unknown action name" {
    "$BIN" extension approve canvas-demo
    output=$(raw_post_json "/ext/canvas-demo/action" '{"action":"not_a_real_action","args":{}}' \
        "session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" "${TEST_CSRF_TOKEN}")
    [[ "$output" =~ "404 Not Found" ]]
}
