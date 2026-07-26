# tst/integration/test_helper.bash
# Shared setup for bats CLI/CGI integration tests -- each test gets a
# fresh scratch directory (never the repo root, to avoid colliding with
# a developer's own .store/ store) and the real, built binary.

resolve_bin() {
    if [ -x "$PROJECT_ROOT/bin/platform" ]; then
        BIN="$PROJECT_ROOT/bin/platform"
    else
        BIN="platform"
    fi
}

setup_test_env() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    resolve_bin
    export TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

# Raw content of the most recent tool_result message for a session --
# tool_result rows (and toolCall lines within an assistant message) are
# deliberately filtered out of the live /chat page and the floating
# widget (agent.all_messages' include_tool_calls=false), so a test
# asserting on what a tool call actually returned needs to check
# agent_message directly instead of scraping rendered HTML. The row's
# content is JSON ({tool_call_id, tool_name, text, is_error}), but a
# plain substring match against the raw JSON blob works fine for these
# tests' purposes -- no need to actually decode it.
latest_tool_result() {
    local session_id="$1"
    sqlite3 "$TEST_DIR/.store/store.db" \
        "SELECT content FROM agent_message WHERE session_id = '${session_id}' AND role = 'tool_result' ORDER BY id DESC LIMIT 1;"
}

cleanup_test_env() {
    cd "$PROJECT_ROOT"
    rm -rf "$TEST_DIR"
}

# Creates a user (via the real `user add` CLI command, bcrypt hash and
# all) and logs them in through a real CGI POST to /login -- not a
# shortcut env-var stub. Echoes "<session_cookie> <csrf_token>"
# (space-separated; both values are plain hex/dot-delimited, so a
# space is a safe separator) for the caller to capture with `read`.
login_test_user() {
    local login="$1"
    local cap="$2"
    "$BIN" user add "$login" "testpass123" "$cap" >/dev/null

    local raw
    raw=$(printf 'login=%s&password=testpass123' "$login" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")

    local session_cookie csrf_token
    session_cookie=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;[:space:]]*' | head -1 | sed 's/^Set-Cookie: session=//')
    csrf_token=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;[:space:]]*' | head -1 | sed 's/^Set-Cookie: csrf=//')

    echo "${session_cookie} ${csrf_token}"
}

# Runs the binary in real CGI mode -- the same GATEWAY_INTERFACE
# env-var trigger a real web server's CGI/FastCGI invocation would use
# (see main.lua's main()), not the CLI dispatch. Attaches a real,
# previously-logged-in session (TEST_SESSION_COOKIE/TEST_CSRF_TOKEN,
# baseline "i" capability -- see login_test_user, called from each
# bats file's own setup()).
run_cgi() {
    local path_info="$1"
    local query_string="${2:-}"
    local method="${3:-GET}"
    GATEWAY_INTERFACE="CGI/1.1" \
    REQUEST_METHOD="$method" \
    PATH_INFO="$path_info" \
    QUERY_STRING="$query_string" \
    HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" \
    HTTP_X_CSRF_TOKEN="${TEST_CSRF_TOKEN}" \
    run "$BIN"
}

# Builds one scripted structured-tool-call turn for AGENT_TEST_RESPONSES
# (agent_provider_test.converse expects each "\1"-delimited entry to be
# a JSON object mirroring the pi-ai bridge's own AssistantMessage shape
# -- see agent_provider_pi.lua/bridge/pi-bridge.mjs) -- replaces the old
# <tool>/<method>/<args> tag-text scripting since the pi-ai migration.
# `dotted_name` is "tool.method" (e.g. "document.search"); `args_json`
# is a raw JSON object literal -- build it by hand, test args here are
# always simple key/value pairs that never need escaping.
tool_call_response() {
    local dotted_name="$1"
    local args_json="$2"
    printf '{"content":[{"type":"toolCall","id":"call_1","name":"%s","arguments":%s}],"stopReason":"toolUse"}' "$dotted_name" "$args_json"
}

# Builds one scripted turn with MULTIPLE parallel toolCall blocks (task:
# real parallel-tool-call execution, not just the first) -- pass
# "dotted_name" "args_json" pairs, e.g.:
#   multi_tool_call_response "entity.list_types" "{}" "entity.fields" '{"entity_type":"task"}'
multi_tool_call_response() {
    local all_blocks=""
    local i=1
    while [ "$#" -gt 0 ]; do
        local dotted_name="$1"
        local args_json="$2"
        shift 2
        local entry
        entry=$(printf '{"type":"toolCall","id":"call_%d","name":"%s","arguments":%s}' "$i" "$dotted_name" "$args_json")
        if [ -z "$all_blocks" ]; then
            all_blocks="$entry"
        else
            all_blocks="${all_blocks},${entry}"
        fi
        i=$((i + 1))
    done
    printf '{"content":[%s],"stopReason":"toolUse"}' "$all_blocks"
}

# Builds one scripted final-answer turn for AGENT_TEST_RESPONSES. `text`
# is JSON-escaped (backslash/quote/newline) so callers can pass a plain
# shell string without hand-escaping it themselves.
done_response() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    text="${text//$'\n'/\\n}"
    printf '{"content":[{"type":"text","text":"%s"}],"stopReason":"stop"}' "$text"
}

# Builds one scripted final-answer turn carrying a real Gemini 2.5
# thought-summary block alongside the final text (task: chat agent
# thinking visibility) -- mirrors what the pi-ai bridge itself returns
# when thinking is enabled (see agent_provider_pi.lua/bridge/
# pi-bridge.mjs and agent.lua's own extract_thinking_text). Both
# `thinking_text`/`answer_text` are JSON-escaped the same way
# done_response's own `text` is.
thinking_response() {
    local thinking_text="$1"
    local answer_text="$2"
    thinking_text="${thinking_text//\\/\\\\}"
    thinking_text="${thinking_text//\"/\\\"}"
    thinking_text="${thinking_text//$'\n'/\\n}"
    answer_text="${answer_text//\\/\\\\}"
    answer_text="${answer_text//\"/\\\"}"
    answer_text="${answer_text//$'\n'/\\n}"
    printf '{"content":[{"type":"thinking","thinking":"%s"},{"type":"text","text":"%s"}],"stopReason":"stop"}' "$thinking_text" "$answer_text"
}

# Same as run_cgi, but authenticated as a "is" (Setup+Admin) capability
# user -- for routes gated above the baseline "i" capability (/sql).
run_cgi_admin() {
    local path_info="$1"
    local query_string="${2:-}"
    local method="${3:-GET}"
    GATEWAY_INTERFACE="CGI/1.1" \
    REQUEST_METHOD="$method" \
    PATH_INFO="$path_info" \
    QUERY_STRING="$query_string" \
    HTTP_COOKIE="session=${ADMIN_SESSION_COOKIE}; csrf=${ADMIN_CSRF_TOKEN}" \
    HTTP_X_CSRF_TOKEN="${ADMIN_CSRF_TOKEN}" \
    run "$BIN"
}
