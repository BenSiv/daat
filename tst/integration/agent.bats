#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add alice secret123 i
    "$BIN" user add bob bobpass123 i

    raw=$(printf 'login=alice&password=secret123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    SESSION=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    CSRF=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    COOKIE="session=${SESSION}; csrf=${CSRF}"

    raw_bob=$(printf 'login=bob&password=bobpass123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    BOB_SESSION=$(printf '%s' "$raw_bob" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    BOB_CSRF=$(printf '%s' "$raw_bob" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    BOB_COOKIE="session=${BOB_SESSION}; csrf=${BOB_CSRF}"
}

teardown() {
    cleanup_test_env
}

# The Location header's value carries a trailing \r (CRLF line ending)
# that a naive extraction misses -- a real bug caught manually while
# verifying this feature -- so every extraction here strips it.
extract_query_param() {
    local response="$1"
    local param="$2"
    printf '%s' "$response" | grep -o "${param}=[^ ]*" | sed "s/${param}=//" | tr -d '\r'
}

raw_get() {
    local path_info="$1"
    local query_string="$2"
    local cookie="$3"
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="$path_info" QUERY_STRING="$query_string" \
        HTTP_COOKIE="$cookie" "$BIN"
}

raw_post() {
    local path_info="$1"
    local body="$2"
    local cookie="$3"
    local test_responses="$4"
    local compaction_threshold="${5:-}"
    if [ -n "$compaction_threshold" ]; then
        write_platform_config ", agent_compaction_threshold = ${compaction_threshold}"
    fi
    printf '%s' "$body" | AGENT_TEST_RESPONSES="$test_responses" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="$path_info" QUERY_STRING="" \
        HTTP_COOKIE="$cookie" "$BIN"
}

start_chat() {
    local cookie="$1"
    local csrf="$2"
    local title="$3"
    raw_post "/chat-start" "csrf_token=${csrf}&title=${title}" "$cookie" ""
}

@test "GET /chat with no sessions shows the empty state" {
    run raw_get "/chat" "" "$COOKIE"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "No chats yet" ]]
}

@test "chat-start creates a session owned by the logged-in user" {
    run start_chat "$COOKIE" "$CSRF" "First+chat"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: chat?session_id=" ]]
}

@test "chat session list shows the session's start timestamp next to its title" {
    start_chat "$COOKIE" "$CSRF" "Timestamped+chat"

    run raw_get "/chat" "" "$COOKIE"
    [[ "$output" =~ "Timestamped chat" ]]
    [[ "$output" =~ "platform-chat-session-started" ]]
}

@test "chat-message with a plain <done> reply records both turns and returns the message" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=What+is+2%2B2%3F" "$COOKIE" "$(done_response "2+2 is 4.")"
    [[ "$output" =~ "302 Found" ]]

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "What is 2+2?" ]]
    [[ "$output" =~ "2+2 is 4." ]]
}

@test "a session with no explicit title gets one generated from its first real message" {
    resp=$(start_chat "$COOKIE" "$CSRF" "")
    session_id=$(extract_query_param "$resp" "session_id")

    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=What+is+the+boiling+point+of+water%3F" "$COOKIE" "$(done_response "100 degrees C.")"
    [[ "$output" =~ "302 Found" ]]

    run raw_get "/chat" "" "$COOKIE"
    [[ "$output" =~ "What is the boiling point of water?" ]]
    [[ ! "$output" =~ "Untitled chat" ]]
}

@test "a deployment's theme.lua system_prompt_extra is appended to the agent's system prompt (task #70)" {
    cat > theme.lua <<'EOF'
return {system_prompt_extra = "This deployment tracks bioreactor runs -- always ask for the run ID before creating a sample."}
EOF
    resp=$(start_chat "$COOKIE" "$CSRF" "Prompt extra test")
    session_id=$(extract_query_param "$resp" "session_id")

    capture_file="$TEST_DIR/captured_system_prompt.txt"
    printf 'csrf_token=%s&session_id=%s&message=hello' "$CSRF" "$session_id" | \
        AGENT_TEST_RESPONSES="$(done_response "Hi.")" \
        AGENT_TEST_CAPTURE_SYSTEM_PROMPT="$capture_file" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" \
        HTTP_COOKIE="$COOKIE" "$BIN" > /dev/null

    [ -f "$capture_file" ]
    run cat "$capture_file"
    [[ "$output" =~ "always ask for the run ID before creating a sample" ]]
}

@test "current-user/current-page annotations reach the model but are stripped from the human-facing transcript" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    # Simulates exactly what the widget's own JS prepends -- a raw form
    # POST bypasses the JS, so this locks in the *server-side* strip
    # behavior (agent.display_content) independently of the browser.
    # Built already form-urlencoded (%0A for newline, + for space)
    # rather than encoding a shell string with real newlines, which sed
    # can't do reliably line-by-line.
    encoded_message="%5BCurrent+user:+alice%5D%0A%5BCurrent+page:+home+%22Home%22%5D%0A%0Awhat+page+am+I+on%3F"
    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=${encoded_message}" "$COOKIE" "$(done_response "You are on the Home page.")"
    [[ "$output" =~ "302 Found" ]]

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "what page am I on?" ]]
    # Not a bare substring check -- the widget's own JS source
    # legitimately contains the literal text "Current user: " on every
    # page (it's the code that builds the prefix), so this checks for
    # the specific leaked-into-a-message-bubble shape instead.
    [[ ! "$output" =~ "Current user: alice]" ]]
    [[ ! "$output" =~ 'Current page: home' ]]
}

@test "a non-destructive tool call (document.search) executes automatically within the same turn" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps"
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "document.search" '{"query":"bioreactor"}')"$'\1'"$(done_response "Found it.")"
    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=find+bioreactor+pages" "$COOKIE" "$scripted"
    [[ "$output" =~ "302 Found" ]]

    # The real tool result is recorded in full (see agent_message
    # directly)...
    run latest_tool_result "$session_id"
    [[ "$output" =~ "Bioreactor Notes" ]]

    # ...but the live chat view filters raw tool output out entirely --
    # only the final answer shows. (Not checking for the absence of the
    # literal string "Tool result" here -- the floating widget's own
    # static ROLE_LABELS JS on every page defines that label regardless
    # of whether anything actually uses it.)
    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ ! "$output" =~ "Bioreactor Notes" ]]
    [[ "$output" =~ "Found it." ]]

    # Auto-executed and done -- no pending approval left behind.
    [[ ! "$output" =~ "wants to run" ]]

    # The document.search tool routes through knowledge.search_and_log:
    # every search is logged, and the retrieved document itself accrues
    # tier/heat directly (task #106 -- no separate knowledge_note; see
    # knowledge.bats for the full tiering/review coverage).
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT query_text, hit_count FROM knowledge_retrieval;"
    [[ "$output" =~ "bioreactor|1" ]]
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT retrieval_count FROM document WHERE title = 'Bioreactor Notes';"
    [ "$output" -eq 1 ]
}

@test "a destructive tool call (document.create) pauses for approval instead of executing" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "document.create" '{"title":"New Page","content":"hello"}')"
    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+page" "$COOKIE" "$scripted"
    [[ "$output" =~ "302 Found" ]]

    # Not asserting the document table is empty -- a real chat turn now
    # syncs the Knowledge Pool folder and this session's own transcript
    # document (task #108 follow-up), even one that ends in
    # pending_approval. What must still be true: the specifically
    # *proposed* page was never created (entity list only prints ids,
    # not titles, so this checks the real column directly).
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM document WHERE title = 'New Page';"
    [ "$output" -eq 0 ]

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "wants to run" ]]
    [[ "$output" =~ "document.create" ]]
    [[ "$output" =~ "Approve" ]]
    [[ "$output" =~ "Deny" ]]
}

@test "approving a pending action executes it, attributes it to the real user, and resumes the loop" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "document.create" '{"title":"New Page","content":"hello"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+page" "$COOKIE" "$scripted" >/dev/null

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)

    run raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" "$(done_response "Created it.")"
    [[ "$output" =~ "302 Found" ]]

    # Not necessarily id 1 -- ledger ids are a single sequence shared
    # across every entity type, and this session's own transcript
    # document (task #108 follow-up) has already been ledgered by the
    # time this page is approved. Look it up by title instead (entity
    # list only prints ids, not titles -- entity show is what confirms
    # content).
    new_page_id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM document WHERE title = 'New Page';")
    [ -n "$new_page_id" ]
    run "$BIN" entity show document "$new_page_id"
    [[ "$output" =~ "New Page" ]]
    [[ "$output" =~ created_by[[:space:]]+alice ]]

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ ! "$output" =~ "wants to run" ]]
    [[ "$output" =~ "Created it." ]]
}

@test "a document.create tool call preserves real multi-line content, including blank lines (regression)" {
    # Found live, back when tool calls were a hand-rolled <tool>/<args>
    # text protocol: the model's own tool call included a full
    # multi-paragraph body (a heading, blank line, prose, blank line, a
    # table), but the stored page held only the first line -- the old
    # line-based args parser (a) skipped every blank line outright and
    # (b) re-matched "key=value" per line, so anything past the first
    # line of a multi-line value was silently discarded, with no error
    # anywhere. Since the pi-ai migration, tool arguments are real JSON
    # values (see tool_call_response), so this can't recur structurally
    # -- kept as a regression test anyway, now confirming the JSON path
    # carries real multi-line/blank-line content through faithfully.
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "document.create" '{"title":"Table Test","content":"# Heading\n\nSome text.\n\n| A | B |\n|---|---|\n| 1 | 2 |"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=make+a+table" "$COOKIE" "$scripted" >/dev/null

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)
    raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" "$(done_response "Created.")" >/dev/null

    stored_content=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM document WHERE title = 'Table Test';")
    [[ "$stored_content" =~ "# Heading" ]]
    [[ "$stored_content" =~ "Some text." ]]
    [[ "$stored_content" =~ "| A | B |" ]]
    [[ "$stored_content" =~ "| 1 | 2 |" ]]
}

@test "denying a pending action never executes it, and records the denial" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "document.create" '{"title":"Denied Page","content":"hello"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+page" "$COOKIE" "$scripted" >/dev/null

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)

    run raw_post "/chat-deny" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" "$(done_response "Understood.")"
    [[ "$output" =~ "302 Found" ]]

    # Not asserting the document table is empty -- see the "pauses for
    # approval" test's own comment (task #108 follow-up: every real
    # chat turn syncs a Knowledge Pool folder + session-transcript
    # document). The specifically *denied* page must never exist
    # (entity list only prints ids, not titles, so this checks the real
    # column directly).
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM document WHERE title = 'Denied Page';"
    [ "$output" -eq 0 ]

    run latest_tool_result "$session_id"
    [[ "$output" =~ "denied" ]]
}

write_task_schema() {
    mkdir -p schemas
    cat > schemas/task.lua <<'EOF'
return {
  name = "task",
  fields = {
    {name = "title", type = "text", required = true},
    {name = "status", type = "select", required = true, values = {"open", "done"}},
  },
}
EOF
    "$BIN" schema add schemas/task.lua >/dev/null
}

@test "entity.list_types lists every registered entity type" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.list_types" '{}')"$'\1'"$(done_response "Listed.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=what+entity+types+exist" "$COOKIE" "$scripted" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "document" ]]
    [[ "$output" =~ "task" ]]
}

@test "parallel tool calls: every toolCall in one turn gets a real result, not just the first" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(multi_tool_call_response "entity.list_types" "{}" "entity.fields" '{"entity_type":"task"}')"$'\1'"$(done_response "Got both.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=what+types+and+fields+does+task+have" "$COOKIE" "$scripted" >/dev/null

    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM agent_message WHERE session_id = '${session_id}' AND role = 'tool_result' ORDER BY id ASC;"
    [[ "$output" =~ "document" ]]
    [[ "$output" =~ "task" ]]
    [[ "$output" =~ "title (text, required)" ]]
    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "Got both." ]]
}

@test "when a turn proposes two destructive calls, only the first pauses for approval -- the second gets a real skipped result, not a silent drop" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(multi_tool_call_response \
        "entity.create" '{"entity_type":"task","title":"First task","status":"open"}' \
        "entity.create" '{"entity_type":"task","title":"Second task","status":"open"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+two+tasks" "$COOKIE" "$scripted" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "wants to run" ]]
    run latest_tool_result "$session_id"
    [[ "$output" =~ "skipped" ]]

    # Only the pending one is a real, resolvable action -- the skipped
    # one never became a second agent_pending_action row.
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM agent_pending_action;"
    [ "$output" -eq 1 ]
}

@test "entity.fields lists a type's field names and types, for discovery before create/update" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.fields" '{"entity_type":"task"}')"$'\1'"$(done_response "Listed.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=what+fields+does+task+have" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "title (text, required)" ]]
    [[ "$output" =~ "status (select, required)" ]]
}

write_task_note_schema() {
    mkdir -p schemas
    cat > schemas/task_note.lua <<'EOF'
return {
  name = "task_note",
  fields = {
    {name = "body", type = "text", required = true},
    {name = "task", type = "reference", required = false, entity_type = "task"},
  },
}
EOF
    "$BIN" schema add schemas/task_note.lua >/dev/null
}

@test "entity.relationships lists every reference edge between entity types, for discovering where a field actually lives" {
    write_task_schema
    write_task_note_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.relationships" '{}')"$'\1'"$(done_response "Listed.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=what+references+what" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "task_note.task -> task (reference)" ]]
}

@test "entity.query answers a real join+aggregate question entity.list's own single-table filter can't express" {
    write_task_schema
    write_task_note_schema
    "$BIN" entity create task title="Ship it" status=open >/dev/null
    task_id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM task WHERE title = 'Ship it';")
    "$BIN" entity create task_note body="first note" task="$task_id" >/dev/null
    "$BIN" entity create task_note body="second note" task="$task_id" >/dev/null

    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    sql="SELECT task.title, COUNT(*) AS note_count FROM task_note JOIN task ON task_note.task = task.id GROUP BY task.title"
    scripted="$(tool_call_response "entity.query" "$(printf '{"sql":"%s"}' "$sql")")"$'\1'"$(done_response "Counted.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=how+many+notes+per+task" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "Ship it" ]]
    [[ "$output" =~ "note_count" ]]
    [[ "$output" =~ "| 2" ]]
}

@test "the chat widget's own JSON state surfaces entity.query's real sql for the /sql console to prefill itself with" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    # Before any entity.query call this session, the widget's state has
    # no query to offer -- the /sql console shouldn't be told to
    # prefill from nothing.
    run env GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/api/chat-widget-history" \
        QUERY_STRING="session_id=${session_id}" HTTP_COOKIE="$COOKIE" "$BIN"
    [[ ! "$output" =~ "SELECT" ]]

    scripted="$(tool_call_response "entity.query" '{"sql":"SELECT title FROM task"}')"$'\1'"$(done_response "Here they are.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=list+task+titles" "$COOKIE" "$scripted" >/dev/null

    run env GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/api/chat-widget-history" \
        QUERY_STRING="session_id=${session_id}" HTTP_COOKIE="$COOKIE" "$BIN"
    [[ "$output" =~ '"last_query_sql":"SELECT title FROM task"' ]]
}

@test "entity.query refuses any table that isn't a registered entity type, even a real internal one" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.query" '{"sql":"SELECT * FROM agent_message"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=show+me+internal+messages" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "not a registered entity type" ]]
}

@test "entity.query refuses non-SELECT SQL the same way the admin /sql console does" {
    write_task_schema
    "$BIN" entity create task title="Untouchable" status=open >/dev/null
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.query" '{"sql":"DELETE FROM task"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=delete+all+tasks" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "not a plain SELECT" ]]

    # Never actually ran -- refused before it ever reached db.query.
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM task;"
    [ "$output" -eq 1 ]
}

@test "research.investigate runs its own isolated multi-step lookup and returns a synthesized finding" {
    write_task_schema
    write_task_note_schema
    "$BIN" entity create task title="Ship it" status=open >/dev/null
    task_id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM task WHERE title = 'Ship it';")
    "$BIN" entity create task_note body="first note" task="$task_id" >/dev/null
    "$BIN" entity create task_note body="second note" task="$task_id" >/dev/null

    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    sql="SELECT COUNT(*) AS note_count FROM task_note JOIN task ON task_note.task = task.id WHERE task.title = 'Ship it'"
    scripted="$(tool_call_response "research.investigate" '{"question":"how many task_notes reference the Ship it task"}')"$'\1'"$(tool_call_response "entity.query" "$(printf '{"sql":"%s"}' "$sql")")"$'\1'"$(done_response "Found note_count=2 via a join on task_note.task = task.id.")"$'\1'"$(done_response "The Ship it task has 2 notes.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=dig+into+how+many+notes+the+Ship+it+task+has" "$COOKIE" "$scripted" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "The Ship it task has 2 notes." ]]
    run latest_tool_result "$session_id"
    [[ "$output" =~ "Found note_count=2" ]]

    # The sub-loop's own entity.query call never becomes a separate,
    # real tool_result row in this session -- only research.investigate's
    # own synthesized finding does (its noise stays isolated).
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM agent_message WHERE session_id = '${session_id}' AND role = 'tool_result';"
    [ "$output" -eq 1 ]
}

@test "research.investigate refuses a destructive action even if the sub-loop tries one, and cannot recurse into itself" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "research.investigate" '{"question":"create a task"}')"$'\1'"$(tool_call_response "entity.create" '{"entity_type":"task","title":"Sneaky","status":"open"}')"$'\1'"$(done_response "I could not create anything -- research is read-only.")"$'\1'"$(done_response "Research reported it cannot write data.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=try+to+sneak+in+a+write+via+research" "$COOKIE" "$scripted" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "Research reported it cannot write data." ]]

    # Never actually created, and never even paused for approval -- the
    # destructive call inside the sub-loop was refused outright.
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM task;"
    [ "$output" -eq 0 ]
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM agent_pending_action;"
    [ "$output" -eq 0 ]
}

@test "research.investigate stops after its own bounded turn budget instead of hanging indefinitely" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "research.investigate" '{"question":"loop forever"}')"
    for i in 1 2 3 4 5 6; do
        scripted="${scripted}"$'\1'"$(tool_call_response "entity.list_types" '{}')"
    done
    scripted="${scripted}"$'\1'"$(done_response "Giving up after the budget ran out.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=keep+digging+forever" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "exceeded its turn budget" ]]
}

@test "clarify.ask ends the turn with the real question visible, no self-check, and the conversation continues normally afterward" {
    write_task_schema
    "$BIN" entity create task title="Ship it" status=open >/dev/null
    "$BIN" entity create task title="Draft plan" status=open >/dev/null
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "clarify.ask" '{"question":"There are two open tasks -- did you mean Ship it or Draft plan?"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=archive+the+task" "$COOKIE" "$scripted" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "did you mean" ]]
    [[ "$output" =~ "Ship it" ]]
    [[ "$output" =~ "Draft plan" ]]
    # The real question is shown directly, not the generic tool-call line.
    [[ ! "$output" =~ "clarify.ask(...)" ]]

    # No self-check ran -- there's no answer yet to critique.
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM agent_message WHERE session_id = '${session_id}' AND role = 'self_check';"
    [ "$output" -eq 0 ]

    # The user's own next message is the answer -- an ordinary
    # /chat-message continues this same session with no special resume
    # endpoint, unlike a destructive pending action.
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=Ship+it" "$COOKIE" "$(done_response "Archived Ship it.")" >/dev/null
    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "Archived Ship it." ]]
}

@test "clarify.ask takes priority over a destructive call proposed in the same turn -- asks first, never pauses the write" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(multi_tool_call_response \
        "clarify.ask" '{"question":"What status should the new task have?"}' \
        "entity.create" '{"entity_type":"task","title":"Ambiguous","status":"open"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+task" "$COOKIE" "$scripted" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "What status should the new task have?" ]]

    # Never created, and never even queued as a pending approval -- the
    # question takes priority over the write proposed in the same turn.
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM task;"
    [ "$output" -eq 0 ]
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM agent_pending_action;"
    [ "$output" -eq 0 ]
}

@test "background.start enqueues without blocking the turn; platform agent run-pending-background drains it into the same conversation" {
    write_task_schema
    write_task_note_schema
    "$BIN" entity create task title="Ship it" status=open >/dev/null
    task_id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM task WHERE title = 'Ship it';")
    "$BIN" entity create task_note body="first note" task="$task_id" >/dev/null
    "$BIN" entity create task_note body="second note" task="$task_id" >/dev/null

    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "background.start" '{"question":"how many task_notes reference the Ship it task"}')"$'\1'"$(done_response "I will dig into that and let you know.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=dig+deeper+on+this+one" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "Started background task" ]]
    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "I will dig into that and let you know." ]]

    # Enqueued, not executed inline -- the turn already returned.
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT status FROM agent_background_task;"
    [ "$output" = "pending" ]

    # Drain it via the real CLI worker, exactly as a systemd timer would.
    sql="SELECT COUNT(*) AS note_count FROM task_note JOIN task ON task_note.task = task.id WHERE task.title = 'Ship it'"
    worker_scripted="$(tool_call_response "entity.query" "$(printf '{"sql":"%s"}' "$sql")")"$'\1'"$(done_response "There are 2 notes on the Ship it task.")"
    AGENT_TEST_RESPONSES="$worker_scripted" run "$BIN" agent run-pending-background
    [[ "$output" =~ "Ran 1, failed 0" ]]

    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT status FROM agent_background_task;"
    [ "$output" = "done" ]

    # The finding is appended to the same conversation as a new message --
    # no separate resume endpoint, the user just sees it next time they
    # look at this chat.
    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "There are 2 notes on the Ship it task." ]]
}

@test "background.status reports pending before the worker runs, and the real finding after" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=dig+deeper" "$COOKIE" \
        "$(tool_call_response "background.start" '{"question":"anything unusual about open tasks"}')"$'\1'"$(done_response "On it.")" >/dev/null
    task_id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM agent_background_task;")

    scripted="$(tool_call_response "background.status" "$(printf '{"task_id":%s}' "$task_id")")"$'\1'"$(done_response "Still working on it.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=any+update" "$COOKIE" "$scripted" >/dev/null
    run latest_tool_result "$session_id"
    [[ "$output" =~ "is still pending" ]]

    AGENT_TEST_RESPONSES="$(done_response "Nothing unusual found.")" run "$BIN" agent run-pending-background

    scripted2="$(tool_call_response "background.status" "$(printf '{"task_id":%s}' "$task_id")")"$'\1'"$(done_response "Here it is.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=any+update+now" "$COOKIE" "$scripted2" >/dev/null
    run latest_tool_result "$session_id"
    [[ "$output" =~ "(done): Nothing unusual found." ]]
}

@test "background.status refuses a task_id belonging to a different session" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")
    other_resp=$(start_chat "$COOKIE" "$CSRF" "Other+chat")
    other_session_id=$(extract_query_param "$other_resp" "session_id")

    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${other_session_id}&message=dig+deeper" "$COOKIE" \
        "$(tool_call_response "background.start" '{"question":"something"}')"$'\1'"$(done_response "On it.")" >/dev/null
    other_task_id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM agent_background_task;")

    scripted="$(tool_call_response "background.status" "$(printf '{"task_id":%s}' "$other_task_id")")"$'\1'"$(done_response "Couldn't find it.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=check+task" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "no such background task" ]]
}

@test "entity.list and entity.get read real rows (non-destructive, auto-executes)" {
    write_task_schema
    "$BIN" entity create task title="Ship it" status=open >/dev/null
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.list" '{"entity_type":"task"}')"$'\1'"$(done_response "Found tasks.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=list+tasks" "$COOKIE" "$scripted" >/dev/null
    run latest_tool_result "$session_id"
    [[ "$output" =~ "Ship it" ]]
    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ ! "$output" =~ "wants to run" ]]

    scripted2="$(tool_call_response "entity.get" '{"entity_type":"task","entity_id":1}')"$'\1'"$(done_response "Here it is.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=show+task+1" "$COOKIE" "$scripted2" >/dev/null
    run latest_tool_result "$session_id"
    [[ "$output" =~ "status=open" ]]
}

@test "entity.validate reports real issues for an invalid create, without writing or queuing anything" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.validate" '{"entity_type":"task","status":"bogus"}')"$'\1'"$(done_response "Checked.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=would+this+be+valid" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "title: required field is missing" ]]
    [[ "$output" =~ "status: must be one of the declared values" ]]

    # A pure check -- never actually created, and never even queued for
    # human approval the way a real entity.create attempt would be.
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM task;"
    [ "$output" -eq 0 ]
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM agent_pending_action;"
    [ "$output" -eq 0 ]
}

@test "entity.validate reports Valid for good values, and still writes nothing" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.validate" '{"entity_type":"task","title":"Ship it","status":"open"}')"$'\1'"$(done_response "That would be valid.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=would+this+be+valid" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "Valid" ]]

    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM task;"
    [ "$output" -eq 0 ]
}

@test "entity.validate with entity_id checks the merged row (update-mode), not a fresh create" {
    write_task_schema
    "$BIN" entity create task title="Ship it" status=open >/dev/null
    task_id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM task WHERE title = 'Ship it';")
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    # Only status is given -- a fresh-create validation would flag title
    # as missing, but an update against the existing row should not,
    # since the current row's own title fills in the merge.
    scripted="$(tool_call_response "entity.validate" "$(printf '{"entity_type":"task","entity_id":%s,"status":"done"}' "$task_id")")"$'\1'"$(done_response "That update would be valid.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=would+marking+it+done+be+valid" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "Valid" ]]
    [[ ! "$output" =~ "title: required field is missing" ]]

    # Still just a check -- the real row is untouched.
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT status FROM task WHERE id = ${task_id};"
    [ "$output" = "open" ]
}

@test "entity.create is destructive: pauses for approval, then really creates the row once approved" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.create" '{"entity_type":"task","title":"New task","status":"open"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+task" "$COOKIE" "$scripted" >/dev/null

    run "$BIN" entity list task
    [[ "$output" == "" ]]

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    [[ "$page_html" =~ "wants to run" ]]
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)

    run raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" "$(done_response "Created it.")"
    [[ "$output" =~ "302 Found" ]]

    # Not necessarily id 1 -- ledger ids are a single sequence shared
    # across every entity type (document included), and this session's
    # own transcript document (task #108 follow-up) has already been
    # ledgered by the time this task is approved.
    task_id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM task WHERE title = 'New task';")
    run "$BIN" entity show task "$task_id"
    [[ "$output" =~ "New task" ]]
    [[ "$output" =~ created_by[[:space:]]+alice ]]
}

@test "entity.update is destructive: pauses for approval, then really updates the row once approved" {
    write_task_schema
    "$BIN" entity create task title="Old title" status=open >/dev/null
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.update" '{"entity_type":"task","entity_id":1,"status":"done"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=mark+task+1+done" "$COOKIE" "$scripted" >/dev/null

    run "$BIN" entity show task 1
    [[ "$output" =~ status[[:space:]]+open ]]

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)

    raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" "$(done_response "Done.")" >/dev/null

    run "$BIN" entity show task 1
    [[ "$output" =~ status[[:space:]]+done ]]
}

@test "one user cannot see, message, or approve/deny another user's session" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Alice private chat")
    session_id=$(extract_query_param "$resp" "session_id")

    run raw_get "/chat" "session_id=${session_id}" "$BOB_COOKIE"
    [[ "$output" =~ "404 Not Found" ]]

    run raw_post "/chat-message" "csrf_token=${BOB_CSRF}&session_id=${session_id}&message=hi" "$BOB_COOKIE" ""
    [[ "$output" =~ "404 Not Found" ]]
}

@test "chat-start/chat-message/chat-approve/chat-deny all require the matching CSRF token" {
    run raw_post "/chat-start" "csrf_token=wrong&title=x" "$COOKIE" ""
    [[ "$output" =~ "403 Forbidden" ]]

    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    run raw_post "/chat-message" "csrf_token=wrong&session_id=${session_id}&message=hi" "$COOKIE" ""
    [[ "$output" =~ "403 Forbidden" ]]
}

@test "self-check: an unconfirmed answer isn't returned as-is -- it's recorded and the loop keeps going instead" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(done_response "There are 0.")"$'\1'"$(done_response "Actually there are 5, I checked again.")"
    printf 'csrf_token=%s&session_id=%s&message=how+many' "$CSRF" "$session_id" | \
        AGENT_TEST_RESPONSES="$scripted" \
        AGENT_TEST_SELF_CHECK_RESPONSE="$(done_response "Did you verify that? Check again.")" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" \
        HTTP_COOKIE="$COOKIE" "$BIN" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "There are 0." ]]
    [[ "$output" =~ 'class="platform-chat-msg platform-chat-self_check"' ]]
    [[ "$output" =~ "Did you verify that" ]]
    [[ "$output" =~ "Actually there are 5" ]]
}

@test "self-check: its own critique is replayed to the model clearly marked as automated, not the real user" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    capture_file="$TEST_DIR/captured_messages.json"
    scripted="$(done_response "There are 0.")"$'\1'"$(done_response "Actually there are 5, I checked again.")"
    printf 'csrf_token=%s&session_id=%s&message=how+many' "$CSRF" "$session_id" | \
        AGENT_TEST_RESPONSES="$scripted" \
        AGENT_TEST_SELF_CHECK_RESPONSE="$(done_response "Did you verify that? Check again.")" \
        AGENT_TEST_CAPTURE_MESSAGES="$capture_file" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" \
        HTTP_COOKIE="$COOKIE" "$BIN" >/dev/null

    # Whatever the last converse() call of the run actually received --
    # once the first self-check rejection happens, every later call
    # replays it (and every following one) back into history; this
    # confirms the replayed row carries the disambiguating marker, not
    # the model's own raw critique text passed off as if the real user
    # said it (the bug that caused a real production self-check loop to
    # spiral in confusion -- see agent.lua's build_history_messages).
    [ -f "$capture_file" ]
    run cat "$capture_file"
    [[ "$output" =~ "Automated self-check, not the real user" ]]
    [[ "$output" =~ "Did you verify that? Check again." ]]
}

@test "self-check: a confirmed answer returns normally, in exactly one turn -- no self-check message stored" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=hi" "$COOKIE" "$(done_response "Hello!")" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "Hello!" ]]
    [[ ! "$output" =~ 'class="platform-chat-msg platform-chat-self_check"' ]]

    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM agent_message WHERE role = 'self_check';"
    [ "$output" -eq 0 ]
}

@test "self-check: a CONFIRM answer with thinking attached is still recognized as confirmed (regression)" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    # Real production regression: once display_blocks started always
    # including thinking text (so a human can see a self-check's own
    # reasoning), a self-check reply that dutifully answered exactly
    # "CONFIRM" as its real text block still got rejected, because the
    # combined (thinking-first) string no longer started with "confirm"
    # -- self-check silently stopped ever confirming, looping every
    # turn out to the full turn budget regardless of whether the answer
    # was fine. text_only_blocks has to be what's actually checked.
    printf 'csrf_token=%s&session_id=%s&message=hi' "$CSRF" "$session_id" | \
        AGENT_TEST_RESPONSES="$(done_response "Hello!")" \
        AGENT_TEST_SELF_CHECK_RESPONSE="$(thinking_response "Let me review this answer carefully..." "CONFIRM")" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" \
        HTTP_COOKIE="$COOKIE" "$BIN" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "Hello!" ]]
    [[ ! "$output" =~ 'class="platform-chat-msg platform-chat-self_check"' ]]

    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM agent_message WHERE role = 'self_check';"
    [ "$output" -eq 0 ]
}

@test "assistant replies with Markdown formatting are actually rendered, not shown as literal asterisks" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=hi" "$COOKIE" "$(done_response "This is **bold** text.")" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "<strong>bold</strong>" ]]
    [[ ! "$output" =~ "**bold**" ]]

    # Same rendering reaches the floating widget's own JSON state, not
    # just the full /chat page.
    run env GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/api/chat-widget-history" \
        QUERY_STRING="session_id=${session_id}" HTTP_COOKIE="$COOKIE" "$BIN"
    [[ "$output" =~ "<strong>bold</strong>" ]]
}

@test "agent_max_turns (platform.lua) is configurable -- a lower limit ends the loop sooner than the default" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    # A self-check that never confirms would run all the way to the
    # default 10-turn budget (9 rejections, 10 assistant rows) -- with
    # agent_max_turns=2, it should stop at exactly 2: the second turn's
    # answer returns immediately since there's no budget left to act on
    # a critique (turn == max_turns skips self-check entirely).
    write_platform_config ', agent_max_turns = 2'
    printf 'csrf_token=%s&session_id=%s&message=how+many' "$CSRF" "$session_id" | \
        AGENT_TEST_RESPONSES="$(done_response "An answer.")" \
        AGENT_TEST_SELF_CHECK_RESPONSE="$(done_response "Not confirmed, check again.")" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" \
        HTTP_COOKIE="$COOKIE" "$BIN" >/dev/null

    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM agent_message WHERE session_id = '${session_id}' AND role = 'assistant';"
    [ "$output" -eq 2 ]
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM agent_message WHERE session_id = '${session_id}' AND role = 'self_check';"
    [ "$output" -eq 1 ]
}

@test "agent_query_row_cap (platform.lua) is configurable -- entity.query truncates at the configured cap, not just the 200 default" {
    write_task_schema
    "$BIN" entity create task title="First" status=open >/dev/null
    "$BIN" entity create task title="Second" status=open >/dev/null
    "$BIN" entity create task title="Third" status=open >/dev/null
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.query" '{"sql":"SELECT title FROM task"}')"$'\1'"$(done_response "Here.")"
    write_platform_config ', agent_query_row_cap = 1'
    printf 'csrf_token=%s&session_id=%s&message=list+tasks' "$CSRF" "$session_id" | \
        AGENT_TEST_RESPONSES="$scripted" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" \
        HTTP_COOKIE="$COOKIE" "$BIN" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "truncated at 1 rows" ]]
}

@test "compaction marks old turns out of context (dimmed) but never deletes them" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Long chat")
    session_id=$(extract_query_param "$resp" "session_id")

    for i in 1 2 3 4 5 6; do
        raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=message+number+${i}+with+extra+padding+text" \
            "$COOKIE" "$(done_response "ok")" "30" >/dev/null
    done

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "platform-chat-out-of-context" ]]
    [[ "$output" =~ "Compacted summary" ]]

    # Nothing deleted -- the full transcript is still all there.
    [[ "$output" =~ "message number 1" ]]
}

# --- Real Vertex AI end-to-end confirmation ---
#
# Deliberately NOT hardcoding a project id here (that would bake a
# specific customer's GCP project into this generic platform's own test
# suite) -- reads VERTEX_PROJECT from whatever's already in the
# environment, same as the app itself does, and skips if it's unset or
# gcloud has no usable credentials. Kept to a couple of small, cheap
# calls -- the turn-loop mechanics are already fully covered above
# against the deterministic test provider; this only needs to confirm
# the real Vertex AI wiring itself still works.

@test "real Vertex AI: agent_provider_vertex.generate returns a real model response" {
    if [ -z "${VERTEX_PROJECT:-}" ]; then
        skip "VERTEX_PROJECT not set in this environment"
    fi
    if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
        skip "no usable gcloud application-default credentials"
    fi

    # Explicitly pinned to the vertex provider (also the default) --
    # this confirms agent_provider_vertex.lua's own direct REST call
    # still works on its own, independent of which provider
    # platform.lua's agent_provider happens to default to. Still a
    # real, live module: document.lua's embeddings call always
    # delegates to it regardless of agent_provider, since
    # agent_provider_vertex.lua is the only provider with embeddings
    # support.
    cat > "${TEST_DIR}/vertex_check.lua" <<EOF
package.path = "${PROJECT_ROOT}/src/?.lua;" .. package.path
agent_provider = require("agent_provider")
result, err = agent_provider.generate("gemini-2.5-flash", "Reply in exactly one word, uppercase.", "What sound does a cow make?")
print("RESULT:", result, "ERR:", err)
EOF
    cat > "${TEST_DIR}/platform.lua" <<EOF
return {agent_provider = "vertex", vertex_project = "${VERTEX_PROJECT}", vertex_region = "${VERTEX_REGION:-us-central1}"}
EOF
    if [ -z "${LUAM_DIR:-}" ]; then
        LUAM_DIR=$(cd "${PROJECT_ROOT}/../luam" && pwd)
    fi
    run env LUA_PATH="${PROJECT_ROOT}/src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;" \
        LUA_CPATH="${LUAM_DIR}/bin/?.so;${LUAM_DIR}/lib/lfs/?.so;;" \
        "${LUAM_DIR}/bin/luam" "${TEST_DIR}/vertex_check.lua"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ERR:	nil" ]]
    [[ ! "$output" =~ "RESULT:	nil" ]]
}

@test "real Vertex AI (native Luam, no Node/pi-ai bridge): agent_provider.converse returns a real structured reply" {
    if [ -z "${VERTEX_PROJECT:-}" ]; then
        skip "VERTEX_PROJECT not set in this environment"
    fi
    if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
        skip "no usable gcloud application-default credentials"
    fi

    cat > "${TEST_DIR}/vertex_converse_check.lua" <<EOF
package.path = "${PROJECT_ROOT}/src/?.lua;" .. package.path
agent_provider = require("agent_provider")
response, err = agent_provider.converse("gemini-2.5-flash", "Reply in exactly one word, uppercase.",
    {{role = "user", content = "What sound does a cow make?"}}, {})
stop = nil
if response != nil then
    stop = response.stopReason
end
print("STOP:", stop, "ERR:", err)
EOF
    cat > "${TEST_DIR}/platform.lua" <<EOF
return {agent_provider = "vertex", vertex_project = "${VERTEX_PROJECT}", vertex_region = "${VERTEX_REGION:-us-central1}"}
EOF
    if [ -z "${LUAM_DIR:-}" ]; then
        LUAM_DIR=$(cd "${PROJECT_ROOT}/../luam" && pwd)
    fi
    run env LUA_PATH="${PROJECT_ROOT}/src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;" \
        LUA_CPATH="${LUAM_DIR}/bin/?.so;${LUAM_DIR}/lib/lfs/?.so;;" \
        "${LUAM_DIR}/bin/luam" "${TEST_DIR}/vertex_converse_check.lua"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ERR:	nil" ]]
    [[ "$output" =~ "STOP:	stop" ]]
}

@test "real Vertex AI (native Luam): a real tool-calling round trip works end to end, with thinking" {
    if [ -z "${VERTEX_PROJECT:-}" ]; then
        skip "VERTEX_PROJECT not set in this environment"
    fi
    if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
        skip "no usable gcloud application-default credentials"
    fi

    # Exercises the actual translation logic end to end -- a real
    # functionCall out, parsed into our own toolCall block; that block
    # re-encoded as assistant history; a toolResult sent back as a real
    # functionResponse; and a real final answer -- everything manually
    # verified via curl while scoping this, now locked in through the
    # real Lua implementation instead.
    cat > "${TEST_DIR}/vertex_tool_check.lua" <<EOF
package.path = "${PROJECT_ROOT}/src/?.lua;" .. package.path
agent_provider = require("agent_provider")

-- Canonical lowercase JSON Schema (doc/agent-protocol.md), matching how
-- agent.lua's own AGENT_TOOLS actually declares tools now -- exercises
-- agent_provider_vertex.lua's real vertex_schema_from_canonical
-- translation into Vertex's uppercase proto enum, not a passthrough of
-- already-uppercase input.
tools = {
    {name = "add", description = "Add two numbers", parameters = {
        type = "object",
        properties = {a = {type = "number"}, b = {type = "number"}},
        required = {"a", "b"},
    }},
}

response, err = agent_provider.converse("gemini-2.5-flash",
    "You must use the add tool to answer arithmetic questions -- never compute it yourself.",
    {{role = "user", content = "What is 15 plus 27? Use the add tool."}}, tools)
stop1 = nil
if response != nil then
    stop1 = response.stopReason
end
print("STOP1:", stop1, "ERR1:", err)

tool_call = nil
if response != nil then
    for _, block in ipairs(response.content) do
        if block.type == "toolCall" then tool_call = block end
        if block.type == "thinking" then print("HAS_THINKING: true") end
    end
end
tool_name, tool_a, tool_b = nil, nil, nil
if tool_call != nil then
    tool_name = tool_call.name
    tool_a = tool_call.arguments.a
    tool_b = tool_call.arguments.b
end
print("TOOL_NAME:", tool_name)
print("TOOL_ARGS_A:", tool_a)
print("TOOL_ARGS_B:", tool_b)

response2, err2 = nil, nil
if tool_call != nil then
    history = {
        {role = "user", content = "What is 15 plus 27? Use the add tool."},
        {role = "assistant", content = {tool_call}},
        {role = "toolResult", toolCallId = tool_call.id, toolName = tool_call.name,
            content = {{type = "text", text = "42"}}, isError = false},
    }
    response2, err2 = agent_provider.converse("gemini-2.5-flash",
        "You must use the add tool to answer arithmetic questions -- never compute it yourself.",
        history, tools)
end
stop2 = nil
if response2 != nil then
    stop2 = response2.stopReason
end
print("STOP2:", stop2, "ERR2:", err2)

final_text = ""
if response2 != nil then
    for _, block in ipairs(response2.content) do
        if block.type == "text" then final_text = final_text .. block.text end
    end
end
print("FINAL:", final_text)
EOF
    cat > "${TEST_DIR}/platform.lua" <<EOF
return {agent_provider = "vertex", vertex_project = "${VERTEX_PROJECT}", vertex_region = "${VERTEX_REGION:-us-central1}"}
EOF
    if [ -z "${LUAM_DIR:-}" ]; then
        LUAM_DIR=$(cd "${PROJECT_ROOT}/../luam" && pwd)
    fi
    run env LUA_PATH="${PROJECT_ROOT}/src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;" \
        LUA_CPATH="${LUAM_DIR}/bin/?.so;${LUAM_DIR}/lib/lfs/?.so;;" \
        "${LUAM_DIR}/bin/luam" "${TEST_DIR}/vertex_tool_check.lua"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "STOP1:	toolUse" ]]
    [[ "$output" =~ "TOOL_NAME:	add" ]]
    [[ "$output" =~ "TOOL_ARGS_A:	15" ]]
    [[ "$output" =~ "TOOL_ARGS_B:	27" ]]
    [[ "$output" =~ "STOP2:	stop" ]]
    [[ "$output" =~ "42" ]]
}

@test "real Vertex AI (native Luam): parallel tool calls in one turn all get answered, not just the first (regression)" {
    if [ -z "${VERTEX_PROJECT:-}" ]; then
        skip "VERTEX_PROJECT not set in this environment"
    fi
    if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
        skip "no usable gcloud application-default credentials"
    fi

    # Real production incident: a research.investigate run asked the
    # model to call two tools in one turn; agent_provider_vertex.lua's
    # own vertex_contents_from_messages used to turn each canonical
    # toolResult message into its own separate Vertex contents[] entry
    # (one {role="user",...} per result), instead of merging every
    # functionResponse answering one functionCall turn into a single
    # entry the way Gemini requires -- confirmed live in production's
    # own agent_message ledger: "Vertex AI error: Please ensure that the
    # number of function response parts is equal to the number of
    # function call parts of the function call turn." Reproduced here
    # against the real API before the fix, confirmed gone after it.
    cat > "${TEST_DIR}/vertex_parallel_tool_check.lua" <<EOF
package.path = "${PROJECT_ROOT}/src/?.lua;" .. package.path
agent_provider = require("agent_provider")

tools = {
    {name = "add", description = "Add two numbers", parameters = {
        type = "object",
        properties = {a = {type = "number"}, b = {type = "number"}},
        required = {"a", "b"},
    }},
    {name = "multiply", description = "Multiply two numbers", parameters = {
        type = "object",
        properties = {a = {type = "number"}, b = {type = "number"}},
        required = {"a", "b"},
    }},
}

response, err = agent_provider.converse("gemini-2.5-flash",
    "You must use the add and multiply tools for arithmetic -- never compute yourself. If asked for both a sum and a product, call BOTH tools in the same turn.",
    {{role = "user", content = "What is 15 plus 27, AND what is 6 times 7? Use both tools in parallel."}}, tools)
stop1 = nil
if response != nil then stop1 = response.stopReason end
print("STOP1:", stop1, "ERR1:", err)

tool_calls = {}
if response != nil then
    for _, block in ipairs(response.content) do
        if block.type == "toolCall" then table.insert(tool_calls, block) end
    end
end
print("NUM_TOOL_CALLS:", #tool_calls)

results = {add = "42", multiply = "42"}
history = {
    {role = "user", content = "What is 15 plus 27, AND what is 6 times 7? Use both tools in parallel."},
    {role = "assistant", content = tool_calls},
}
for _, tool_call in ipairs(tool_calls) do
    result_text = results[tool_call.name]
    if result_text == nil then result_text = "?" end
    table.insert(history, {role = "toolResult", toolCallId = tool_call.id, toolName = tool_call.name,
        content = {{type = "text", text = result_text}}, isError = false})
end

response2, err2 = agent_provider.converse("gemini-2.5-flash",
    "You must use the add and multiply tools for arithmetic -- never compute yourself. If asked for both a sum and a product, call BOTH tools in the same turn.",
    history, tools)
stop2 = nil
if response2 != nil then stop2 = response2.stopReason end
print("STOP2:", stop2, "ERR2:", err2)
EOF
    cat > "${TEST_DIR}/platform.lua" <<EOF
return {agent_provider = "vertex", vertex_project = "${VERTEX_PROJECT}", vertex_region = "${VERTEX_REGION:-us-central1}"}
EOF
    if [ -z "${LUAM_DIR:-}" ]; then
        LUAM_DIR=$(cd "${PROJECT_ROOT}/../luam" && pwd)
    fi
    run env LUA_PATH="${PROJECT_ROOT}/src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;" \
        LUA_CPATH="${LUAM_DIR}/bin/?.so;${LUAM_DIR}/lib/lfs/?.so;;" \
        "${LUAM_DIR}/bin/luam" "${TEST_DIR}/vertex_parallel_tool_check.lua"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "NUM_TOOL_CALLS:	2" ]]
    [[ "$output" =~ "ERR2:	nil" ]]
    [[ "$output" =~ "STOP2:	stop" ]]
    [[ ! "$output" =~ "function response parts" ]]
}

write_admin_schema() {
    mkdir -p schemas
    cat > schemas/secret_report.lua <<'EOF'
return {
  name = "secret_report",
  admin_write_only = true,
  fields = { {name = "title", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/secret_report.lua >/dev/null
}

write_experiment_template() {
    mkdir -p templates
    cat > templates/standard_experiment.lua <<'EOF'
return {
  name = "standard_experiment",
  label = "Standard Experiment",
  description = "Objective/hypothesis text plus an Experiment registration table.",
  default_path = "Notebook/Standard Experiment",
  sections = {
    {type = "heading", text = "Objective"},
    {type = "text", text = "Describe the goal..."},
    {type = "registration_table", entity_type = "experiment", label = "Experiment"},
  },
}
EOF
}

@test "template.list lists available templates by name/label/description" {
    write_experiment_template
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "template.list" '{}')"$'\1'"$(done_response "Listed.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=what+templates+exist" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "standard_experiment" ]]
    [[ "$output" =~ "Standard Experiment" ]]
}

@test "template.get returns rendered content, chainable straight into document.create" {
    write_experiment_template
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "template.get" '{"name":"standard_experiment"}')"$'\1'"$(done_response "Got it.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=get+the+standard+experiment+template" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "## Objective" ]]
    [[ "$output" =~ "register?type=experiment" ]]
    [[ "$output" =~ "Notebook/Standard Experiment" ]]
}

@test "template.get on an unknown name fails cleanly, not a crash" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "template.get" '{"name":"nonexistent"}')"$'\1'"$(done_response "No such template.")"
    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=get+a+bogus+template" "$COOKIE" "$scripted"
    [[ "$output" =~ "302 Found" ]]
}

@test "entity.archive and entity.unarchive are destructive: pause for approval, then really apply once approved" {
    write_task_schema
    "$BIN" entity create task title="Old task" status=open >/dev/null
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.archive" '{"entity_type":"task","entity_id":1}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=archive+task+1" "$COOKIE" "$scripted" >/dev/null

    run "$BIN" entity list task
    [[ "$output" =~ "#1" ]]

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)
    raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" "$(done_response "Archived.")" >/dev/null

    run "$BIN" entity list task
    [[ ! "$output" =~ "#1" ]]

    resp2=$(start_chat "$COOKIE" "$CSRF" "Chat2")
    session_id2=$(extract_query_param "$resp2" "session_id")
    scripted2="$(tool_call_response "entity.unarchive" '{"entity_type":"task","entity_id":1}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id2}&message=restore+task+1" "$COOKIE" "$scripted2" >/dev/null
    page_html2=$(raw_get "/chat" "session_id=${session_id2}" "$COOKIE")
    pending_id2=$(printf '%s' "$page_html2" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)
    raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id2}&session_id=${session_id2}" "$COOKIE" "$(done_response "Restored.")" >/dev/null

    run "$BIN" entity list task
    [[ "$output" =~ "#1" ]]
}

@test "entity.list supports filter_field/filter_value and limit, matching /api/v1's own GET-list shape" {
    write_task_schema
    "$BIN" entity create task title="First" status=open >/dev/null
    "$BIN" entity create task title="Second" status=done >/dev/null
    "$BIN" entity create task title="Third" status=open >/dev/null
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.list" '{"entity_type":"task","filter_field":"status","filter_value":"open"}')"$'\1'"$(done_response "Listed.")"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=list+open+tasks" "$COOKIE" "$scripted" >/dev/null

    run latest_tool_result "$session_id"
    [[ "$output" =~ "First" ]]
    [[ "$output" =~ "Third" ]]
    [[ ! "$output" =~ "Second" ]]
}

@test "the chat agent's write capability is the chatting user's own -- alice (plain 'i') is Forbidden from admin-gated writes via chat, matching her own /register form" {
    write_admin_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    # alice is a plain "i" user (setup()) with no "a" of her own -- no
    # "chat-agent" key is involved at all anymore, proving this checks
    # HER capability, not some separately configured identity. Still
    # pauses for human approval first (destructive=true gates on that
    # regardless), the capability check itself only fires once
    # execute_tool actually runs, i.e. after approval.
    scripted="$(tool_call_response "entity.create" '{"entity_type":"secret_report","title":"Leaked"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+secret+report" "$COOKIE" "$scripted" >/dev/null

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    [[ "$page_html" =~ "wants to run" ]]
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)
    raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" "$(done_response "Done.")" >/dev/null

    run "$BIN" entity list secret_report
    [[ "$output" == "" ]]
    run latest_tool_result "$session_id"
    [[ "$output" =~ "Forbidden" ]]
}

@test "once alice's own account is granted Admin capability (no chat-agent key involved at all), the same write via chat succeeds" {
    write_admin_schema
    "$BIN" user capabilities alice ia >/dev/null
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.create" '{"entity_type":"secret_report","title":"Approved report"}')"
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+secret+report" "$COOKIE" "$scripted" >/dev/null

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    [[ "$page_html" =~ "wants to run" ]]
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)
    raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" "$(done_response "Created.")" >/dev/null

    run "$BIN" entity list secret_report
    [[ "$output" != "" ]]
}
