#!/usr/bin/env bats
# An extension can own entity types and views: capabilities.schemas/
# views name files under the extension's own schemas/ and views/
# directories, loaded through the same sandboxed schema.register/
# view.load path as the deployment's own schemas/ and views/, but only
# while the extension is approved (see doc/extensibility.md).

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p extensions/tracker/schemas extensions/tracker/views
    cat > extensions/tracker/manifest.lua <<'EOF'
return {
    name = "tracker",
    events = {},
    entity_types = {},
    capabilities = {
        read = {}, write = {}, net = "none",
        schemas = {"ticket"},
        views = {"open_tickets"},
    },
}
EOF
    cat > extensions/tracker/main.lua <<'EOF'
return {}
EOF
    cat > extensions/tracker/schemas/ticket.lua <<'EOF'
return {
    name = "ticket",
    fields = {
        {name = "document", type = "reference", required = true, entity_type = "document"},
        {name = "state", type = "select", required = true, values = {"open", "closed"}, display = true},
    },
}
EOF
    cat > extensions/tracker/views/open_tickets.lua <<'EOF'
return {
    name = "open_tickets",
    title = "Open tickets",
    sql = "SELECT id, state FROM ticket WHERE state = 'open'",
    columns = {
        {name = "id", label = "ID"},
        {name = "state", label = "State"},
    },
}
EOF
    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "tester" "i")
}

teardown() {
    cleanup_test_env
}

@test "an unapproved extension's entity type is never registered" {
    run "$BIN" schema list
    [[ ! "$output" =~ "ticket" ]]
}

@test "approving the extension registers its entity type and generates its table" {
    "$BIN" extension approve tracker
    run "$BIN" schema list
    [[ "$output" =~ "ticket" ]]
    run sqlite3 .store/store.db "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ticket';"
    [ "$output" = "ticket" ]
}

@test "an extension-owned type works like any other: create, validate, browse" {
    "$BIN" extension approve tracker
    "$BIN" schema sync
    "$BIN" entity create document title="Fix the pump" content="The pump leaks."
    run "$BIN" entity create ticket document=1 state=open
    [[ "$output" =~ "Created ticket" ]]
    run "$BIN" entity create ticket document=1 state=bogus
    [[ "$output" =~ "Registration failed" ]]
    run_cgi "/browse" "type=ticket"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "State" ]]
}

@test "editing an approved extension's schema file resyncs without re-approval" {
    "$BIN" extension approve tracker
    "$BIN" schema list > /dev/null
    cat > extensions/tracker/schemas/ticket.lua <<'EOF'
return {
    name = "ticket",
    fields = {
        {name = "document", type = "reference", required = true, entity_type = "document"},
        {name = "state", type = "select", required = true, values = {"open", "closed"}, display = true},
        {name = "owner", type = "text", required = false},
    },
}
EOF
    run "$BIN" schema show ticket
    [[ "$output" =~ "owner" ]]
}

@test "declaring a new owned schema makes the extension unapproved until re-approved" {
    "$BIN" extension approve tracker
    sed -i 's/schemas = {"ticket"}/schemas = {"ticket", "milestone"}/' extensions/tracker/manifest.lua
    cat > extensions/tracker/schemas/milestone.lua <<'EOF'
return { name = "milestone", fields = { {name = "title", type = "text", required = true} } }
EOF
    run "$BIN" schema list
    [[ ! "$output" =~ "milestone" ]]
    "$BIN" extension approve tracker
    run "$BIN" schema list
    [[ "$output" =~ "milestone" ]]
}

@test "an extension schema file defining a different name than declared fails the sync" {
    sed -i 's/name = "ticket"/name = "not_ticket"/' extensions/tracker/schemas/ticket.lua
    "$BIN" extension approve tracker
    run "$BIN" schema sync
    [[ "$output" =~ "declares schema 'ticket'" ]]
    run "$BIN" schema list
    [[ ! "$output" =~ "not_ticket" ]]
}

@test "the same entity type in schemas/ and an extension fails the sync instead of overriding" {
    mkdir -p schemas
    cat > schemas/ticket.lua <<'EOF'
return { name = "ticket", fields = { {name = "title", type = "text", required = true} } }
EOF
    "$BIN" extension approve tracker
    run "$BIN" schema sync
    [[ "$output" =~ "defined by both schemas/ticket.lua and extension 'tracker'" ]]
}

@test "revoking the extension keeps the table and its rows" {
    "$BIN" extension approve tracker
    "$BIN" schema sync
    "$BIN" entity create document title="Fix the pump" content="The pump leaks."
    "$BIN" entity create ticket document=1 state=open
    "$BIN" extension revoke tracker
    "$BIN" schema sync
    run sqlite3 .store/store.db "SELECT COUNT(*) FROM ticket;"
    [ "$output" -eq 1 ]
}

@test "an extension-owned view is listed, approvable, and served once the extension is approved" {
    run "$BIN" view list
    [[ ! "$output" =~ "open_tickets" ]]
    "$BIN" extension approve tracker
    "$BIN" schema sync
    run "$BIN" view list
    [[ "$output" =~ "open_tickets" ]]
    "$BIN" view approve open_tickets
    "$BIN" entity create document title="Fix the pump" content="The pump leaks."
    "$BIN" entity create ticket document=1 state=open
    run_cgi "/view" "view_name=open_tickets"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "open" ]]
}

@test "an unapproved extension's view 404s" {
    run_cgi "/view" "view_name=open_tickets"
    [[ "$output" =~ "404 Not Found" ]]
}

@test "a document's page shows extension-owned records that reference it, with a pre-filled Add link" {
    "$BIN" extension approve tracker
    "$BIN" schema sync
    "$BIN" entity create document title="Fix the pump" content="The pump leaks."
    "$BIN" entity create ticket document=1 state=open
    run_cgi "/document" "entity_id=1"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Related records" ]]
    [[ "$output" =~ "ticket (1)" ]]
    [[ "$output" =~ "register?type=ticket&lock_document=1" ]]
    # Core self-references stay in their own sections, not Related records.
    [[ ! "$output" =~ "<h4>document_tag (" ]]
    [[ ! "$output" =~ "<h4>document (" ]]
}

@test "a document nothing references shows no Related records section" {
    "$BIN" entity create document title="Just a note" content="Nothing attached."
    run_cgi "/document" "entity_id=1"
    [[ "$output" =~ "200 OK" ]]
    [[ ! "$output" =~ "Related records" ]]
}
