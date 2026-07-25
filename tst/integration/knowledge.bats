#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add alice secret123 i

    raw=$(printf 'login=alice&password=secret123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    SESSION=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    CSRF=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    COOKIE="session=${SESSION}; csrf=${CSRF}"
}

teardown() {
    cleanup_test_env
}

raw_post() {
    local path_info="$1"
    local body="$2"
    local cookie="$3"
    local test_responses="$4"
    printf '%s' "$body" | AGENT_PROVIDER=test AGENT_TEST_RESPONSES="$test_responses" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="$path_info" QUERY_STRING="" \
        HTTP_COOKIE="$cookie" "$BIN"
}

raw_get() {
    local path_info="$1"
    local query_string="$2"
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="$path_info" QUERY_STRING="$query_string" \
        HTTP_COOKIE="$COOKIE" "$BIN"
}

extract_query_param() {
    local response="$1"
    local param="$2"
    printf '%s' "$response" | grep -o "${param}=[^ ]*" | sed "s/${param}=//" | tr -d '\r'
}

start_chat() {
    raw_post "/chat-start" "csrf_token=${CSRF}&title=Chat" "$COOKIE" ""
}

search_for_bioreactor() {
    resp=$(start_chat)
    session_id=$(extract_query_param "$resp" "session_id")
    scripted=$'<tool>document</tool>\n<method>search</method>\n<args>\nquery=bioreactor\n</args>\1<done>Found it.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=find+bioreactor+pages" "$COOKIE" "$scripted" >/dev/null
}

# Same as search_for_bioreactor, but with an optional extra scripted
# response for task #109's own generate() call -- which only fires on
# whichever retrieval first crosses CO_RETRIEVAL_LINK_THRESHOLD for a
# given pair (not every retrieval), so most calls to this helper don't
# need one at all. Slot order matters: knowledge.search_and_log (and so
# review_retrieval/knowledge.maybe_link_co_retrieved) runs as part of
# the search *tool's own execution*, in between the tool-call proposal
# and the loop's next (final-reply) generate() call -- not after it --
# so the extra response goes in the *middle* of the scripted list, not
# appended at the end.
search_for_bioreactor_extra() {
    local extra_response="$1"
    resp=$(start_chat)
    session_id=$(extract_query_param "$resp" "session_id")
    scripted=$'<tool>document</tool>\n<method>search</method>\n<args>\nquery=bioreactor\n</args>'
    if [ -n "$extra_response" ]; then
        scripted="${scripted}"$'\1'"${extra_response}"
    fi
    scripted="${scripted}"$'\1<done>Found it.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=find+bioreactor+pages" "$COOKIE" "$scripted" >/dev/null
}

@test "platform knowledge stats shows all zeros on a fresh store" {
    run "$BIN" knowledge stats
    [[ "$output" =~ "tier0=0 tier1=0 tier2=0 tier3=0" ]]
    [[ "$output" =~ "notes=0 retrievals=0 reviewed=0 sessions=0" ]]
}

@test "document.search's tool result grounds the agent in real content, not just a title" {
    # Found live: document.search itself already fetched full content
    # for scoring, but the agent tool wrapper around it used to throw
    # that away and return only "#id title" -- the model could find
    # which pages might be relevant but never actually read one before
    # answering. Excerpted (not the full page verbatim) so a search
    # matching several long pages doesn't balloon every turn's prompt.
    long_content=$(python3 -c "print('The bioreactor procedure needs careful monitoring. ' * 40)")
    "$BIN" entity create document title="Bioreactor SOP" content="$long_content"
    search_for_bioreactor

    tool_result=$(sqlite3 .store/store.db "SELECT content FROM agent_message WHERE role='tool_result' ORDER BY id DESC LIMIT 1;")
    [[ "$tool_result" =~ "Bioreactor SOP" ]]
    [[ "$tool_result" =~ "careful monitoring" ]]
    # Truncated, not the full ~2000-char body verbatim.
    [[ "$tool_result" =~ "..." ]]
    [ "${#tool_result}" -lt 1400 ]
}

@test "document.search flags duplicate titles in its own tool result, with real disambiguating fields (task: structural fix, not a prompt reminder)" {
    # Real, already-live situation: 293 duplicate titles in production
    # (mostly repeated Benchling resyncs) -- rather than relying on the
    # model to remember not to ask the user for a raw id, the tool
    # result itself surfaces creation date/external_id and flags the
    # collision explicitly whenever it actually occurs in a result batch.
    "$BIN" entity create document title="Bioreactor SOP" content="bioreactor careful monitoring version A" external_id="etr_AAA111"
    "$BIN" entity create document title="Bioreactor SOP" content="bioreactor careful monitoring version B" external_id="etr_BBB222"
    search_for_bioreactor

    tool_result=$(sqlite3 .store/store.db "SELECT content FROM agent_message WHERE role='tool_result' ORDER BY id DESC LIMIT 1;")
    [[ "$tool_result" =~ "one of 2 pages titled 'Bioreactor SOP'" ]]
    [[ "$tool_result" =~ "etr_AAA111" ]]
    [[ "$tool_result" =~ "etr_BBB222" ]]
    [[ "$tool_result" =~ "never by asking the user for the id" ]]
}

@test "document.search excludes chat-session transcripts from results, even when they match the query" {
    # Found live: searching for real domain content ("standard experiment
    # page template") returned old chat transcripts (containing the
    # query's own words, since the user's message is part of the
    # transcript) mixed in with real docs, degrading the agent's own
    # ability to find real content via its own document.search tool.
    "$BIN" entity create document title="Bioreactor SOP" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor
    # this first session's own transcript is now a real document
    # (source_type='chat_session') containing "find bioreactor pages"
    # verbatim -- confirm it actually exists, so this test would have
    # caught the real bug (nothing to exclude if it were never created).
    chat_doc_count=$(sqlite3 .store/store.db "SELECT COUNT(*) FROM document WHERE source_type='chat_session' AND content LIKE '%bioreactor%';")
    [ "$chat_doc_count" -ge 1 ]

    search_for_bioreactor
    tool_result=$(sqlite3 .store/store.db "SELECT content FROM agent_message WHERE role='tool_result' ORDER BY id DESC LIMIT 1;")
    [[ "$tool_result" =~ "Bioreactor SOP" ]]
    [[ ! "$tool_result" =~ "Chat:" ]]
}

@test "a chat search creates a tier-0 note, logs the retrieval, and runs review" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor

    run "$BIN" knowledge stats
    # tier0=2, notes=2: Bioreactor Notes itself, plus the chat session's
    # own transcript document (task #108 follow-up -- every conversation
    # is synced into its own document under the Knowledge Pool folder,
    # which is itself a pool "note" the moment it's created).
    [[ "$output" =~ "tier0=2 tier1=0 tier2=0 tier3=0" ]]
    [[ "$output" =~ "notes=2 retrievals=1 reviewed=1 sessions=1" ]]

    run "$BIN" knowledge list 0
    [[ "$output" =~ "Bioreactor Notes" ]]
    [[ "$output" =~ "heat=1.15" ]]
}

@test "searching for the same document twice reuses its own row (no duplicate) and promotes it to tier 1" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor
    search_for_bioreactor

    run "$BIN" knowledge stats
    # notes=3: Bioreactor Notes (still exactly one row -- a retrieved
    # document accrues heat/tier directly on itself, task #106, never a
    # second row per search) plus two chat sessions' own transcript
    # documents (task #108 follow-up -- each search_for_bioreactor call
    # starts a fresh session).
    [[ "$output" =~ "notes=3 retrievals=2" ]]

    # 2 retrievals crosses the tier-0->1 promotion threshold.
    run "$BIN" knowledge list 1
    [[ "$output" =~ "Bioreactor Notes" ]]
    [[ "$output" =~ "retrievals=2" ]]
}

@test "platform knowledge show prints a document's full pool detail" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor

    run "$BIN" knowledge show 1
    [[ "$output" =~ "title: Bioreactor Notes" ]]
    [[ "$output" =~ "tier: 0" ]]
    # A real, user-authored page retrieved directly has no source_type
    # (task #106) -- it isn't "sourced from" anything, it simply IS the
    # document; only agent-derived content (reasoning notes, future
    # distilled notes) prints a "source:" line.
    [[ ! "$output" =~ "source:" ]]
    [[ "$output" =~ "cleaning steps for the bioreactor procedure" ]]
}

@test "platform knowledge promote manually overrides a document's tier" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor

    run "$BIN" knowledge promote 1 2
    [[ "$output" =~ "Document #1 set to tier 2" ]]

    run "$BIN" knowledge list 2
    [[ "$output" =~ "Bioreactor Notes" ]]
    run "$BIN" knowledge list 0
    [[ ! "$output" =~ "Bioreactor Notes" ]]
}

@test "spreading activation reinforces a retrieved document's linked neighbors, not just the exact hit" {
    # Real [[title]] links (task #106 follow-up, ACT-R "spreading
    # activation") -- only document.create_page/sync_links populates
    # document_link, so this goes through the real /document-save
    # route rather than the `entity create` CLI shortcut every other
    # test in this file uses.
    # The link target must exist BEFORE the linking page is saved --
    # document.sync_links resolves "[[title]]" against documents that
    # exist at save time and is never retroactively re-run when a
    # dangling link's target later appears.
    raw_post "/document-save" "csrf_token=${CSRF}&title=Cleaning+Checklist&parent_id=&content=Checklist+content+here." "$COOKIE" "" >/dev/null
    raw_post "/document-save" "csrf_token=${CSRF}&title=Bioreactor+SOP&parent_id=&content=Steps+for+the+bioreactor.+See+%5B%5BCleaning+Checklist%5D%5D+for+details." "$COOKIE" "" >/dev/null

    resp=$(start_chat)
    session_id=$(extract_query_param "$resp" "session_id")
    scripted=$'<tool>document</tool>\n<method>search</method>\n<args>\nquery=bioreactor\n</args>\1<done>Found it.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=find+bioreactor+pages" "$COOKIE" "$scripted" >/dev/null

    # The linked neighbor ("Cleaning Checklist") never matched the query
    # directly, so its retrieval_count stays 0 -- but it should still
    # get a heat bump above the 1.0 default via spreading activation.
    run sqlite3 .store/store.db "SELECT retrieval_count FROM document WHERE title = 'Cleaning Checklist';"
    [ "$output" -eq 0 ]
    run sqlite3 .store/store.db "SELECT heat > 1.0 FROM document WHERE title = 'Cleaning Checklist';"
    [ "$output" -eq 1 ]
}

@test "the agent's knowledge.stats tool reports the same numbers as the CLI" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor

    resp=$(start_chat)
    session_id=$(extract_query_param "$resp" "session_id")
    scripted=$'<tool>knowledge</tool>\n<method>stats</method>\n<args>\n</args>\1<done>Here you go.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=summarize+the+knowledge+pool" "$COOKIE" "$scripted" >/dev/null

    run raw_get "/chat" "session_id=${session_id}"
    # notes=2: Bioreactor Notes plus the first session's own transcript
    # document (task #108 follow-up) -- this second session's own
    # transcript isn't synced yet at the moment its knowledge.stats tool
    # call runs (sync happens once the turn concludes, not mid-turn).
    [[ "$output" =~ "notes=2" ]]
    [[ "$output" =~ "retrievals=1" ]]
}

@test "/knowledge renders the landing page for a Setup/Admin user" {
    "$BIN" user add carol carolpass123 isa
    raw_carol=$(printf 'login=carol&password=carolpass123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    carol_session=$(printf '%s' "$raw_carol" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    carol_csrf=$(printf '%s' "$raw_carol" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')

    run bash -c "GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET PATH_INFO=/knowledge QUERY_STRING= HTTP_COOKIE='session=${carol_session}; csrf=${carol_csrf}' '$BIN'"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Knowledge Pool" ]]
    [[ "$output" =~ "Tier 0: Raw Intake" ]]
    [[ "$output" =~ "Tier 3: Atomic Records" ]]
}

@test "/knowledge is forbidden for a plain (non Setup/Admin) user" {
    run raw_get "/knowledge" ""
    [[ "$output" =~ "403 Forbidden" ]]
}

@test "the icon rail no longer has a dedicated Chats entry; System links to Knowledge Pool instead" {
    "$BIN" user add carol carolpass123 isa
    raw_carol=$(printf 'login=carol&password=carolpass123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    carol_session=$(printf '%s' "$raw_carol" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    carol_csrf=$(printf '%s' "$raw_carol" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')

    run bash -c "GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET PATH_INFO=/ QUERY_STRING= HTTP_COOKIE='session=${carol_session}; csrf=${carol_csrf}' '$BIN'"
    [[ ! "$output" =~ 'title="Chats"' ]]

    run bash -c "GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET PATH_INFO=/system QUERY_STRING= HTTP_COOKIE='session=${carol_session}; csrf=${carol_csrf}' '$BIN'"
    [[ "$output" =~ 'href="knowledge"' ]]
    [[ "$output" =~ "Knowledge Pool" ]]
}

@test "two documents repeatedly co-retrieved get an agent-evaluated explicit link once the agent says YES (task #109)" {
    "$BIN" entity create document title="Bioreactor Cleaning" content="cleaning steps for the bioreactor procedure"
    "$BIN" entity create document title="Bioreactor Startup" content="startup steps for the bioreactor procedure"

    # First 2 shared retrievals stay below CO_RETRIEVAL_LINK_THRESHOLD
    # (3) -- no evaluation call needed, no extra scripted response.
    search_for_bioreactor_extra ""
    search_for_bioreactor_extra ""
    # The 3rd shared retrieval crosses the threshold -- one extra
    # generate() call fires for the evaluation itself.
    search_for_bioreactor_extra "YES"

    run sqlite3 .store/store.db "SELECT source FROM document_link WHERE from_document_id = 1 AND to_document_id = 2;"
    [[ "$output" == "co-retrieval" ]]
    run sqlite3 .store/store.db "SELECT decision, last_co_count FROM knowledge_link_review WHERE document_a_id = 1 AND document_b_id = 2;"
    [[ "$output" == "linked|3" ]]
}

@test "a co-retrieved pair the agent declines is remembered, not re-asked on the very next shared retrieval (task #109)" {
    "$BIN" entity create document title="Bioreactor Cleaning" content="cleaning steps for the bioreactor procedure"
    "$BIN" entity create document title="Bioreactor Startup" content="startup steps for the bioreactor procedure"

    search_for_bioreactor_extra ""
    search_for_bioreactor_extra ""
    search_for_bioreactor_extra "NO"

    run sqlite3 .store/store.db "SELECT COUNT(*) FROM document_link WHERE from_document_id = 1 AND to_document_id = 2;"
    [ "$output" -eq 0 ]
    run sqlite3 .store/store.db "SELECT decision, last_co_count FROM knowledge_link_review WHERE document_a_id = 1 AND document_b_id = 2;"
    [[ "$output" == "declined|3" ]]

    # A 4th shared retrieval (co_count=4) hasn't grown past
    # last_co_count(3) + CO_RETRIEVAL_REEVALUATION_STEP(3) = 6 yet, so
    # this must NOT trigger a second evaluation call -- no extra
    # scripted response provided; if the code wrongly re-evaluated here,
    # generate() would fall back to repeating the last scripted
    # response ("NO") anyway, but the real assertion is that
    # last_co_count stays 3 (unchanged), proving no re-evaluation ran.
    search_for_bioreactor_extra ""
    run sqlite3 .store/store.db "SELECT last_co_count FROM knowledge_link_review WHERE document_a_id = 1 AND document_b_id = 2;"
    [ "$output" -eq 3 ]
}

@test "an auto-created co-retrieval link survives re-saving either document's content (task #109)" {
    "$BIN" entity create document title="Bioreactor Cleaning" content="cleaning steps for the bioreactor procedure"
    "$BIN" entity create document title="Bioreactor Startup" content="startup steps for the bioreactor procedure"

    search_for_bioreactor_extra ""
    search_for_bioreactor_extra ""
    search_for_bioreactor_extra "YES"

    run sqlite3 .store/store.db "SELECT COUNT(*) FROM document_link WHERE from_document_id = 1 AND to_document_id = 2 AND source = 'co-retrieval';"
    [ "$output" -eq 1 ]

    "$BIN" entity update document 1 content="updated cleaning steps for the bioreactor procedure"

    run sqlite3 .store/store.db "SELECT COUNT(*) FROM document_link WHERE from_document_id = 1 AND to_document_id = 2 AND source = 'co-retrieval';"
    [ "$output" -eq 1 ]
}
