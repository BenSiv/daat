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

    # Agent-tools plugin surface (brex 278013129): an approved
    # extension declaring capabilities.tools contributes tools the chat
    # agent can call, dispatched under tool_name = the extension's own
    # name -- exercised below through a real scripted chat turn, the
    # same harness tst/integration/agent.bats uses for built-in tools.
    mkdir -p extensions/tool-demo
    cat > extensions/tool-demo/manifest.lua <<'EOF'
return {
    name = "tool-demo",
    events = {},
    entity_types = {},
    capabilities = {
        read = {"entity"},
        write = {"entity"},
        net = "none",
        tools = {
            {name = "lookup", description = "Looks up widgets by label.", destructive = false,
             parameters = {type = "object", properties = {label = {type = "string"}}, required = {"label"}}},
            {name = "bump", description = "Creates a bumped widget.", destructive = true,
             parameters = {type = "object", properties = {}}},
        },
    },
}
EOF
    cat > extensions/tool-demo/main.lua <<'EOF'
return {
    tools = {
        lookup = function(ctx, args)
            rows = ctx.query("widget", {label = args.label})
            return "found " .. tostring(#rows) .. " widget(s) labeled " .. tostring(args.label)
        end,
        bump = function(ctx, args)
            ctx.create_entity("widget", {label = "bumped-by-tool"})
            return "Bumped via tool!"
        end,
    },
}
EOF

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "plainuser" "i")
}

start_chat() {
    local cookie="$1"
    local csrf="$2"
    local resp sid
    resp=$(raw_post_json "/api/chat-widget-start" '{"title":"Chat"}' "$cookie" "$csrf" "")
    sid=$(json_body "$resp" | jq -r '.session_id')
    printf 'session_id=%s' "$sid"
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

# ---- Agent-tools plugin surface (brex 278013129) ----

@test "an approved extension's non-destructive tool executes automatically within the same chat turn" {
    "$BIN" entity create widget label="gadget"
    "$BIN" extension approve tool-demo
    cookie="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}"
    resp=$(start_chat "$cookie" "$TEST_CSRF_TOKEN")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "tool-demo.lookup" '{"label":"gadget"}')"$'\1'"$(done_response "Found it.")"
    run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${session_id}\",\"message\":\"look up gadget\"}" "$cookie" "$TEST_CSRF_TOKEN" "$scripted"
    [[ "$output" =~ "200 OK" ]]
    [[ "$(json_body "$output" | jq -r '.pending')" = "null" ]]

    run latest_tool_result "$session_id"
    [[ "$output" =~ "found 1 widget(s) labeled gadget" ]]
}

@test "an approved extension's destructive tool pauses for approval, and approving it really dispatches through ctx" {
    "$BIN" extension approve tool-demo
    cookie="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}"
    resp=$(start_chat "$cookie" "$TEST_CSRF_TOKEN")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "tool-demo.bump" '{}')"
    send_resp=$(raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${session_id}\",\"message\":\"bump it\"}" "$cookie" "$TEST_CSRF_TOKEN" "$scripted")
    [[ "$(json_body "$send_resp" | jq -r '.pending.tool')" = "tool-demo" ]]
    [[ "$(json_body "$send_resp" | jq -r '.pending.method')" = "bump" ]]

    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM widget WHERE label = 'bumped-by-tool';"
    [ "$output" -eq 0 ]

    pending_id=$(json_body "$send_resp" | jq -r '.pending.id')
    run raw_post_json "/api/chat-widget-approve" "{\"pending_id\":${pending_id},\"session_id\":\"${session_id}\"}" "$cookie" "$TEST_CSRF_TOKEN" "$(done_response "Bumped.")"
    [[ "$output" =~ "200 OK" ]]

    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM widget WHERE label = 'bumped-by-tool';"
    [ "$output" -eq 1 ]
    # Not necessarily id 1 -- ledger ids are a single sequence shared
    # across every entity type, and this session's own transcript
    # document has already been ledgered by the time the bump is
    # approved (see agent.bats' own comment on the same caveat). Look
    # it up by label instead.
    bumped_id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM widget WHERE label = 'bumped-by-tool';")
    run "$BIN" entity show widget "$bumped_id"
    [[ "$output" =~ "extension:tool-demo" ]]
}

@test "editing capabilities.tools invalidates approval, same as any other capability change" {
    "$BIN" extension approve tool-demo
    run "$BIN" extension show tool-demo
    [[ "$output" =~ "status:       approved" ]]

    sed -i 's/Looks up widgets by label\./Looks up widgets by label (v2)./' extensions/tool-demo/manifest.lua
    run "$BIN" extension show tool-demo
    [[ "$output" =~ "NOT APPROVED" ]]

    "$BIN" extension approve tool-demo
    run "$BIN" extension show tool-demo
    [[ "$output" =~ "status:       approved" ]]
}
