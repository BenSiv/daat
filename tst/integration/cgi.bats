#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p schemas views

    cat > schemas/person.lua <<'EOF'
return {
  name = "person",
  fields = {
    {name = "full_name", type = "text", required = true, display = true},
  },
}
EOF
    cat > schemas/experiment.lua <<'EOF'
return {
  name = "experiment",
  fields = {
    {name = "title", type = "text", required = true, display = true},
    {name = "owner", type = "reference", required = false, entity_type = "person"},
  },
}
EOF
    cat > schemas/sample.lua <<'EOF'
return {
  name = "sample",
  fields = {
    {name = "lot_number", type = "text", required = true},
    {name = "experiment", type = "reference", required = false, entity_type = "experiment"},
  },
}
EOF
    "$BIN" schema add schemas/person.lua
    "$BIN" schema add schemas/experiment.lua
    "$BIN" schema add schemas/sample.lua

    "$BIN" entity create person full_name="Dr. Cohen"
    "$BIN" entity create experiment title="Contamination trial" owner=1
    "$BIN" entity create sample lot_number="LOT-42" experiment=2

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "testuser" "i")
    export TEST_SESSION_COOKIE TEST_CSRF_TOKEN
    read ADMIN_SESSION_COOKIE ADMIN_CSRF_TOKEN < <(login_test_user "testadmin" "is")
    export ADMIN_SESSION_COOKIE ADMIN_CSRF_TOKEN
}

teardown() {
    cleanup_test_env
}

@test "/data renders the entity-relation diagram with a node per type and an edge for each reference field" {
    # Moved off "/" when Home became its own separate landing page --
    # see html.render_home/render_index's own comments.
    run_cgi "/data" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "platform-diagram-node\" data-entity-type=\"person\"" ]]
    [[ "$output" =~ "platform-diagram-node\" data-entity-type=\"experiment\"" ]]
    [[ "$output" =~ "platform-diagram-node\" data-entity-type=\"sample\"" ]]
    [[ "$output" =~ "platform-diagram-edge\" data-from=\"experiment\" data-to=\"person\"" ]]
    [[ "$output" =~ "platform-diagram-edge\" data-from=\"sample\" data-to=\"experiment\"" ]]
}

@test "/data's diagram is a real ERD: boxes show real field name/type rows, edges carry cardinality labels (task #86)" {
    run_cgi "/data" ""
    [ "$status" -eq 0 ]
    # sample's own real fields, not just its name -- a required text
    # field and the reference field that becomes the experiment edge.
    [[ "$output" =~ '>lot_number<' ]]
    [[ "$output" =~ 'platform-diagram-row-type" x="'[0-9.]*'" y="'[0-9.]*'">text<' ]]
    [[ "$output" =~ 'platform-diagram-row-type" x="'[0-9.]*'" y="'[0-9.]*'">reference<' ]]
    # every box gets a synthetic PK id row, not itself a real schema field
    [[ "$output" =~ "platform-diagram-row-name platform-diagram-row-pk\" x=\"" ]]
    [[ "$output" =~ '>id<' ]]
    # the experiment -> person edge is a plain reference: cardinality
    # "*" on the referencing (experiment) end, "1" on the referenced
    # (person/id) end -- not just an unlabeled connectivity line. Only
    # one reference edge exists in this fixture, so a page-wide check
    # for both label texts is unambiguous.
    [[ "$output" =~ '>*</text>' ]]
    [[ "$output" =~ '>1</text>' ]]
}

@test "/data sorts entity types by row count descending, alphabetical tiebreak, with data-count for the hide-empty toggle" {
    "$BIN" entity create person full_name="Dr. Amare"
    "$BIN" entity create person full_name="Dr. Beadle"
    # person now has 3 rows (1 from setup + 2 here); experiment and
    # sample each still have 1 -- person must sort first, then
    # experiment before sample (alphabetical tiebreak on equal counts).
    run_cgi "/data" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ 'data-count="3"><a href="browse?type=person"' ]]
    before_experiment="${output%%'type=experiment"'*}"
    [[ "$before_experiment" == *'type=person"'* ]]
    before_sample="${output%%'type=sample"'*}"
    [[ "$before_sample" == *'type=experiment"'* ]]
}

@test "/data shows an entity search box" {
    run_cgi "/data" ""
    [[ "$output" =~ "platform-entity-search-input" ]]
    [[ "$output" =~ "api/entity-search" ]]
}

@test "/api/entity-search finds a matching row via a schema's display=true field" {
    run_cgi "/api/entity-search" "query=Cohen"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ '"entity_type":"person"' ]]
    [[ "$output" =~ '"label":"Dr. Cohen"' ]]
}

@test "/api/entity-search finds a matching row via a schema's display=true field on a different type" {
    run_cgi "/api/entity-search" "query=Contamination"
    [[ "$output" =~ '"entity_type":"experiment"' ]]
    [[ "$output" =~ '"label":"Contamination trial"' ]]
}

@test "/api/entity-search skips a type with no name column value and no display=true field" {
    # sample's own schema (setup()) has no display=true field and never
    # gets its builtin name column populated -- confirms it's skipped
    # entirely rather than matched against arbitrary content columns.
    run_cgi "/api/entity-search" "query=LOT-42"
    [[ "$output" =~ "200 OK" ]]
    [[ ! "$output" =~ "LOT-42" ]]
}

@test "/api/entity-search excludes archived rows" {
    run_cgi "/api/archive" "type=person&entity_id=1" "POST"
    run_cgi "/api/entity-search" "query=Cohen"
    [[ ! "$output" =~ "Dr. Cohen" ]]
}

@test "/api/entity-search returns an empty list for an empty query, not every row" {
    run_cgi "/api/entity-search" "query="
    [[ "$output" =~ "200 OK" ]]
    [[ ! "$output" =~ '"entity_type"' ]]
}

@test "/register renders the registration form for a real entity type" {
    run_cgi "/register" "type=sample"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Register sample" ]]
}

@test "/entity-edit renders a prefilled single-row edit form for a real entity" {
    run_cgi "/entity-edit" "type=sample&entity_id=3"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Edit sample #3" ]]
    # the row's current values are embedded as JSON for the client JS to prefill
    [[ "$output" =~ '"lot_number":"LOT-42"' ]]
    # posts to the existing /api/update endpoint, not a new/duplicate write path
    [[ "$output" =~ "/api/update" ]]
}

@test "/entity-edit 404s for a nonexistent entity id" {
    run_cgi "/entity-edit" "type=sample&entity_id=999"
    [[ "$output" =~ "404 Not Found" ]]
}

@test "/detail links to /entity-edit for the same type and id" {
    run_cgi "/detail" "type=sample&entity_id=3"
    [[ "$output" =~ 'href="entity-edit?type=sample&entity_id=3"' ]]
}

write_sample_template() {
    mkdir -p templates
    cat > templates/sample_intake.lua <<'EOF'
return {
  name = "sample_intake",
  label = "Sample Intake",
  description = "Standard intake notes plus a sample registration table.",
  default_path = "Notebook/Sample Intake",
  sections = {
    {type = "heading", text = "Notes"},
    {type = "registration_table", entity_type = "sample", label = "Sample"},
  },
}
EOF
}

@test "/template shows a 'Create new page from this template' button linking to /document-edit" {
    write_sample_template
    run_cgi "/template" "template_name=sample_intake"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ 'href="document-edit?from_template=sample_intake"' ]]
}

@test "/templates list links each entry straight to a prefilled new page" {
    write_sample_template
    run_cgi "/templates"
    [[ "$output" =~ 'href="document-edit?from_template=sample_intake"' ]]
}

@test "/document-edit?from_template prefills title and rendered content for a new (unsaved) page" {
    write_sample_template
    run_cgi "/document-edit" "from_template=sample_intake"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Notebook/Sample Intake" ]]
    [[ "$output" =~ "## Notes" ]]
    [[ "$output" =~ "register?type=sample" ]]
    # nothing is actually created yet -- still the new-page form, no entity_id
    [[ "$output" =~ 'name="entity_id" value=""' ]]
}

@test "/document-edit?from_template is ignored when editing an existing page (never clobbers real content)" {
    write_sample_template
    "$BIN" entity create document title="Real page" content="Real, already-written content."
    # entity ids are a single global sequence, not per-type -- setup()
    # already created person=1/experiment=2/sample=3, so this doc is #4.
    run_cgi "/document-edit" "entity_id=4&from_template=sample_intake"
    [[ "$output" =~ "Real, already-written content." ]]
    [[ ! "$output" =~ "## Notes" ]]
}

@test "/document-edit?from_template 404s for an unknown template name" {
    run_cgi "/document-edit" "from_template=does_not_exist"
    [[ "$output" =~ "404 Not Found" ]]
}

@test "/browse lists an entity type's rows" {
    run_cgi "/browse" "type=sample"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOT-42" ]]
}

@test "/browse and /detail links are plain relative paths, not tied to any particular mount point" {
    # Regression: several links here used to carry a leftover
    # "platform/" path segment from an old mount-point convention this
    # app no longer uses -- broken under any real deployment, since
    # there's no route at "platform/browse" etc. Every link/action/src
    # this app renders for its own pages must be a plain relative
    # reference (or none at all), so it resolves correctly no matter
    # what path prefix a web server mounts this app under.
    run_cgi "/browse" "type=sample"
    [[ "$output" =~ 'href="detail?type=sample' ]]
    [[ ! "$output" =~ "platform/detail" ]]
    [[ ! "$output" =~ "platform/browse" ]]

    run_cgi "/detail" "type=sample&entity_id=3"
    [[ "$output" =~ 'href="browse?type=sample"' ]]
    [[ ! "$output" =~ "platform/browse" ]]
}

@test "/browse rejects a 'type' shaped like a stacked-SQL-statement injection" {
    run_cgi "/browse" "type=sample%3B+DROP+TABLE+sample%3B--"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "400 Bad Request" ]]
    # the entity table must survive -- confirm sample is still queryable
    run_cgi "/browse" "type=sample"
    [[ "$output" =~ "LOT-42" ]]
}

@test "/browse rejects a 'type' shaped like a path-traversal payload" {
    run_cgi "/browse" "type=..%2F..%2Fetc%2Fpasswd"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "400 Bad Request" ]]
}

@test "/api/preview rejects a 'type' shaped like a SQL-injection payload" {
    run_cgi "/api/preview" "type=sample%3B+DROP+TABLE+sample%3B--&entity_id=1"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "400 Bad Request" ]]
}

@test "/api/preview resolves a reference field to the referenced entity's name, not its raw id" {
    # Reported live 2026-07-18: the hover-popover preview showed a
    # sample's "experiment"/"container"-style reference fields as raw
    # foreign-key ids, not the referenced entity's name -- confirmed the
    # link text itself (render_reference_value) already resolved fine,
    # this was isolated to handle_preview's own field_lines loop, which
    # never reference-resolved anything.
    run_cgi "/api/preview" "type=experiment&entity_id=2"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Dr. Cohen" ]]
}

@test "/sql query textarea overrides Fossil's base 95% textarea max-width" {
    # Reported live: the query textarea measured visibly narrower than
    # the prompt-input+button row above it -- traced to Fossil's own
    # base CSS (src/default.css: "textarea { max-width: 95%; }"), which
    # otherwise wins with nothing overriding it here.
    run_cgi_admin "/sql" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "platform-sql-input" ]]
    [[ "$output" =~ "max-width: 100%" ]]
}

@test "/sql?embed=1 still gets the real theme colors, not the generic fallback" {
    # Reported live: the embedded SQL widget on /data rendered in the
    # default indigo/slate instead of the deployment's real theme --
    # ?embed=1 skips html.page_shell entirely (to avoid nesting a
    # second full page inside the iframe), which also meant it never
    # got the :root { --platform-x: ...; } block a real theme.json
    # compiles to, so every var(--platform-*, fallback) silently fell
    # back to the generic default.
    cat > theme.json <<'EOF'
{"site_name": "Celleste", "colors": {"accent": "#C97F1E"}}
EOF
    run_cgi_admin "/sql" "embed=1"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "--platform-accent: #C97F1E;" ]]
}

@test "/sql's popover JS repositions via fixed viewport coordinates, not left CSS clipped by the scrolling table wrapper (task #111)" {
    # The result table is wrapped in .platform-table-wrapper (overflow-x:
    # auto), which per the CSS Overflow spec forces overflow-y to auto
    # too -- clipping/trapping the default position:absolute popover at
    # the wrapper's edge once the table is long enough to overflow.
    # Fixed by repositioning via JS (getBoundingClientRect + position:
    # fixed) on hover instead of relying on CSS positioning alone.
    run_cgi_admin "/sql" "q=SELECT+id%2C+lot_number%2C+experiment+FROM+sample%3B"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "data-platform-popover-src" ]]
    [[ "$output" =~ "getBoundingClientRect" ]]
    [[ "$output" =~ "pop.style.position = 'fixed'" ]]
}

@test "/sql resolves a reference column on the FROM table" {
    # /sql requires Setup or Admin capability (not just baseline "i").
    run_cgi_admin "/sql" "q=SELECT+id%2C+lot_number%2C+experiment+FROM+sample%3B"
    [ "$status" -eq 0 ]
    # experiment=2 should render as a resolved link/label, not the bare id "2"
    [[ "$output" =~ "Contamination trial" ]]
}

@test "/sql resolves a reference column on a JOINed table, not just FROM (regression: view.guess_tables)" {
    # Before the join-aware fix, this reference column (experiment.owner)
    # would silently fall back to displaying the raw id "1" instead of a
    # resolved link, since the old heuristic only ever looked at the FROM
    # table (sample), not the joined one (experiment).
    query='SELECT+s.id%2C+e.owner+FROM+sample+s+JOIN+experiment+e+ON+s.experiment+%3D+e.id%3B'
    run_cgi_admin "/sql" "q=${query}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Dr. Cohen" ]]
}

@test "/sql adds a default row cap to a query with no LIMIT of its own" {
    # Found live: an unrestricted query against ~3800 rows of real
    # document content took 54 real seconds and produced a 5.7MB page
    # (html.render_sql's own O(n^2) string-concat, fixed separately) --
    # this is the second half of that fix: a query with no LIMIT at all
    # shouldn't render thousands of rows in the first place.
    for i in $(seq 1 5); do
        "$BIN" entity create person full_name="Extra $i"
    done
    # setup() already made 1 person (Dr. Cohen) -- 6 total now, well
    # under ADHOC_ROW_CAP, so nothing should be truncated yet.
    run_cgi_admin "/sql" "q=SELECT+id%2C+full_name+FROM+person%3B"
    [[ "$output" =~ "6 rows" ]]
    [[ ! "$output" =~ "Showing first" ]]
}

@test "/sql leaves a query with its own LIMIT untouched, not double-limited" {
    run_cgi_admin "/sql" "q=SELECT+id+FROM+person+LIMIT+1%3B"
    [[ "$output" =~ "1 rows" ]]
    [[ ! "$output" =~ "Showing first" ]]
}

@test "/sql's default row cap actually kicks in past ADHOC_ROW_CAP (1000) rows" {
    # Bulk insert (not $BIN entity create per row -- CGI-per-request
    # bootstrap makes 1000+ of those impractically slow for a test) to
    # exercise the real cap boundary, not just "a handful of rows".
    python3 -c "
import sys
lines = ['INSERT INTO person (full_name, created_at, updated_at) VALUES (\'Bulk %d\', datetime(), datetime());' % i for i in range(1010)]
print('\n'.join(lines))
" | sqlite3 "$TEST_DIR/.store/store.db"

    run_cgi_admin "/sql" "q=SELECT+id+FROM+person%3B"
    [[ "$output" =~ "Showing first 1000 rows" ]]
}

@test "/sql's row cap is configurable via platform.json's platform_adhoc_row_cap, not fixed at 1000" {
    for i in $(seq 1 5); do
        "$BIN" entity create person full_name="Extra $i"
    done
    # setup()'s own Dr. Cohen makes 6 total -- override the cap well
    # below that, cheaply, instead of the default test's 1010-row bulk
    # insert (which exercises the *default* value specifically).
    write_platform_config ',"platform_adhoc_row_cap":3'
    run env GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/sql" \
        QUERY_STRING="q=SELECT+id+FROM+person%3B" \
        HTTP_COOKIE="session=${ADMIN_SESSION_COOKIE}; csrf=${ADMIN_CSRF_TOKEN}" \
        HTTP_X_CSRF_TOKEN="${ADMIN_CSRF_TOKEN}" "$BIN"
    [[ "$output" =~ "Showing first 3 rows" ]]
}

@test "/view renders a canned view's rows" {
    cat > views/samples.lua <<'EOF'
return {
  name = "samples",
  title = "All samples",
  sql = "SELECT id, lot_number FROM sample;",
  columns = {
    {name = "id", label = "ID"},
    {name = "lot_number", label = "Lot"},
  },
}
EOF
    "$BIN" view approve samples

    run_cgi "/view" "view_name=samples"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOT-42" ]]
    # No entity_type declared on this view -- no register link expected.
    [[ ! "$output" =~ "Register new" ]]
}

@test "/view shows a Register new link when the view declares entity_type" {
    cat > views/samples_with_type.lua <<'EOF'
return {
  name = "samples_with_type",
  title = "All samples",
  entity_type = "sample",
  sql = "SELECT id, lot_number FROM sample;",
  columns = {
    {name = "id", label = "ID"},
    {name = "lot_number", label = "Lot"},
  },
}
EOF
    "$BIN" view approve samples_with_type

    run_cgi "/view" "view_name=samples_with_type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Register new" ]]
    [[ "$output" =~ 'href="register?type=sample"' ]]
}

@test "/view?view_name=prioritized_tasks highlights the Tasks rail icon, not Data (regression)" {
    cat > views/prioritized_tasks.lua <<'EOF'
return {
  name = "prioritized_tasks",
  title = "Tasks",
  entity_type = "task",
  sql = "SELECT id, lot_number FROM sample;",
  columns = {
    {name = "id", label = "ID"},
    {name = "lot_number", label = "Lot"},
  },
}
EOF
    "$BIN" view approve prioritized_tasks

    run_cgi "/view" "view_name=prioritized_tasks"
    [ "$status" -eq 0 ]
    [[ "$output" =~ 'title="Tasks"' ]]
    # The Tasks link itself carries the active class...
    [[ "$output" =~ 'class="platform-nav-link platform-nav-link-active" href="view?view_name=prioritized_tasks"' ]]
    # ...and Data does not.
    [[ ! "$output" =~ 'class="platform-nav-link platform-nav-link-active" href="data"' ]]
}

@test "/view?view_name=some_other_view still highlights Data (only prioritized_tasks maps to Tasks)" {
    cat > views/samples_with_type.lua <<'EOF'
return {
  name = "samples_with_type",
  title = "All samples",
  entity_type = "sample",
  sql = "SELECT id, lot_number FROM sample;",
  columns = {
    {name = "id", label = "ID"},
    {name = "lot_number", label = "Lot"},
  },
}
EOF
    "$BIN" view approve samples_with_type

    run_cgi "/view" "view_name=samples_with_type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ 'class="platform-nav-link platform-nav-link-active" href="data"' ]]
}

@test "/view refuses to run an unapproved view" {
    cat > views/unapproved.lua <<'EOF'
return {
  name = "unapproved",
  title = "Unapproved",
  sql = "SELECT id FROM sample;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
    run_cgi "/view" "view_name=unapproved"
    [[ "$output" =~ "not approved" ]]
}

@test "/api/archive excludes an entity from /browse but keeps it reachable via /detail" {
    run_cgi "/api/archive" "type=sample&entity_id=3" "POST"
    [ "$status" -eq 0 ]
    [[ "$output" =~ '"success":true' ]]

    run_cgi "/browse" "type=sample"
    [[ ! "$output" =~ "LOT-42" ]]

    run_cgi "/detail" "type=sample&entity_id=3"
    [[ "$output" =~ "LOT-42" ]]
}

@test "/api/archive requires a reason when the schema opts in via require_reason_on_archive (task #93)" {
    cat > schemas/reagent_regulated.lua <<'EOF'
return {
  name = "reagent_regulated",
  require_reason_on_archive = true,
  fields = {
    {name = "lot_number", type = "text", required = true},
  },
}
EOF
    "$BIN" schema add schemas/reagent_regulated.lua
    "$BIN" entity create reagent_regulated lot_number="LOT-R1"
    # entity ids are a single global sequence, not per-type -- setup()
    # already created person=1/experiment=2/sample=3, so this row is #4.

    run_cgi "/api/archive" "type=reagent_regulated&entity_id=4" "POST"
    [[ "$output" =~ '"success":false' ]]
    [[ "$output" =~ "reason for archiving is required" ]]

    run_cgi "/browse" "type=reagent_regulated"
    [[ "$output" =~ "LOT-R1" ]]

    run_cgi "/api/archive" "type=reagent_regulated&entity_id=4&reason=Contaminated" "POST"
    [[ "$output" =~ '"success":true' ]]

    run_cgi "/detail" "type=reagent_regulated&entity_id=4"
    [[ "$output" =~ "Reason: Contaminated" ]]
}

@test "/api/update requires a reason when the schema opts in via require_reason_on_update (task #93)" {
    cat > schemas/reagent_regulated_upd.lua <<'EOF'
return {
  name = "reagent_regulated_upd",
  require_reason_on_update = true,
  fields = {
    {name = "lot_number", type = "text", required = true},
  },
}
EOF
    "$BIN" schema add schemas/reagent_regulated_upd.lua
    "$BIN" entity create reagent_regulated_upd lot_number="LOT-R1"
    # entity ids are a single global sequence, not per-type -- setup()
    # already created person=1/experiment=2/sample=3, so this row is #4.

    run bash -c "printf '%s' '{\"lot_number\":\"LOT-R2\"}' | \
        GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=POST PATH_INFO=/api/update \
        QUERY_STRING='type=reagent_regulated_upd&entity_id=4' \
        HTTP_COOKIE='session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}' \
        HTTP_X_CSRF_TOKEN='${TEST_CSRF_TOKEN}' '$BIN'"
    [[ "$output" =~ '"success":false' ]]
    [[ "$output" =~ "reason for this change is required" ]]

    run_cgi "/detail" "type=reagent_regulated_upd&entity_id=4"
    [[ "$output" =~ "LOT-R1" ]]

    run bash -c "printf '%s' '{\"lot_number\":\"LOT-R2\"}' | \
        GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=POST PATH_INFO=/api/update \
        QUERY_STRING='type=reagent_regulated_upd&entity_id=4&reason=Recount' \
        HTTP_COOKIE='session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}' \
        HTTP_X_CSRF_TOKEN='${TEST_CSRF_TOKEN}' '$BIN'"
    [[ "$output" =~ '"success":true' ]]

    run_cgi "/detail" "type=reagent_regulated_upd&entity_id=4"
    [[ "$output" =~ "LOT-R2" ]]
    [[ "$output" =~ "Reason: Recount" ]]
}

@test "/api/unarchive restores an entity to /browse" {
    run_cgi "/api/archive" "type=sample&entity_id=3" "POST"
    run_cgi "/api/unarchive" "type=sample&entity_id=3" "POST"
    [[ "$output" =~ '"success":true' ]]

    run_cgi "/browse" "type=sample"
    [[ "$output" =~ "LOT-42" ]]
}
