#!/usr/bin/env bats
# task #84: multivalue fields (multi_select/multi_reference) -- storage
# via a companion junction table (schema.ensure_multi_field_table), not
# a lossy semicolon/comma column, plus the named-dropdown-list system.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
}

teardown() {
    cleanup_test_env
}

write_plant_schema() {
    mkdir -p schemas
    cat > schemas/plant.lua <<'EOF'
return {
  name = "plant",
  fields = {
    {name = "label", type = "text", required = true, display = true},
  },
}
EOF
}

write_sample_schema() {
    mkdir -p schemas
    cat > schemas/sample.lua <<'EOF'
return {
  name = "sample",
  fields = {
    {name = "label", type = "text", required = true, display = true},
    {name = "source_plants", type = "multi_reference", required = false, entity_type = "plant"},
    {name = "process", type = "multi_select", required = false, dropdown = "work_process"},
  },
}
EOF
}

write_work_process_dropdown() {
    mkdir -p dropdowns
    cat > dropdowns/work_process.lua <<'EOF'
return {
  name = "work_process",
  values = {"cultivation", "harvest", "processing"},
}
EOF
}

setup_full_schema() {
    write_work_process_dropdown
    write_plant_schema
    write_sample_schema
    "$BIN" schema sync
}

@test "registering a multi_reference/multi_select schema creates the companion junction tables, not a column" {
    setup_full_schema
    run sqlite3 .store/store.db ".schema sample"
    [[ ! "$output" =~ "source_plants" ]]
    [[ ! "$output" =~ "process" ]]

    run sqlite3 .store/store.db ".tables"
    [[ "$output" =~ "sample_source_plants" ]]
    [[ "$output" =~ "sample_process" ]]
}

@test "a multi_reference junction table's second column really FKs the referenced entity type, not its own parent" {
    setup_full_schema
    run sqlite3 .store/store.db ".schema sample_source_plants"
    [[ "$output" =~ "FOREIGN KEY (sample_id) REFERENCES sample(id)" ]] || [[ "$output" =~ "FOREIGN KEY(sample_id) REFERENCES sample(id)" ]] || [[ "$output" =~ "FOREIGN KEY (\`sample_id\`) REFERENCES \`sample\` (\`id\`)" ]]
    [[ "$output" =~ "REFERENCES plant(id)" ]] || [[ "$output" =~ "REFERENCES \`plant\` (\`id\`)" ]]
    [[ ! "$output" =~ "REFERENCES sample(id), source_plants_id" ]]
}

@test "a dropdown's values are resolved into entity_field.enum_values, not left empty" {
    setup_full_schema
    run sqlite3 .store/store.db "SELECT enum_values FROM entity_field WHERE entity_type='sample' AND name='process';"
    [[ "$output" =~ "cultivation" ]]
    [[ "$output" =~ "harvest" ]]
    [[ "$output" =~ "processing" ]]
}

@test "/register's own layout JSON resolves a select field's dropdown into real values, not leaving them out (regression)" {
    # Reported live: /register?type=cell_line crashed its own "+ Add Row"
    # button silently -- root cause was schema.layout's *file-based*
    # path (used whenever the schema .lua file still exists on disk,
    # i.e. the normal case) only ever copied a field's own literal
    # `values` list from the raw file; a `dropdown = "..."` reference
    # has no `values` of its own there at all -- those only ever get
    # resolved into entity_field.enum_values at sync time. The browser's
    # own addRow() (html.lua) does `field.values.forEach(...)` for every
    # select field with no guard, so a dropdown-referencing required
    # select field (the very first field on this schema, matching the
    # real cell_line.tissue_code bug) crashed the whole batch-entry
    # table before a single row could ever render.
    mkdir -p schemas dropdowns
    cat > dropdowns/tissue_codes.lua <<'EOF'
return {
  name = "tissue_codes",
  values = {"SUS", "CAL"},
}
EOF
    cat > schemas/cell_line.lua <<'EOF'
return {
  name = "cell_line",
  fields = {
    {name = "tissue_code", type = "select", required = true, dropdown = "tissue_codes"},
  },
}
EOF
    "$BIN" schema sync
    read session csrf < <(login_test_user "tester" "i")

    run env GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/register" QUERY_STRING="type=cell_line" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" "$BIN"
    [[ "$output" =~ '"name":"tissue_code"' ]]
    [[ "$output" =~ '"values":["SUS","CAL"]' ]]
}

@test "changing a dropdown's values and re-syncing updates every field referencing it" {
    setup_full_schema
    cat > dropdowns/work_process.lua <<'EOF'
return {
  name = "work_process",
  values = {"cultivation", "storage"},
}
EOF
    "$BIN" schema sync
    run sqlite3 .store/store.db "SELECT enum_values FROM entity_field WHERE entity_type='sample' AND name='process';"
    [[ "$output" =~ "storage" ]]
    [[ ! "$output" =~ "harvest" ]]
}

@test "creating an entity with array-valued multi fields populates the junction tables" {
    setup_full_schema
    "$BIN" entity create plant label="Trinidad C2"
    "$BIN" entity create plant label="Trinidad SJ"
    run "$BIN" entity create sample label="S1" source_plants="1,2" process="cultivation,harvest"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Created sample #3" ]]

    run sqlite3 .store/store.db "SELECT sample_id, source_plants_id FROM sample_source_plants ORDER BY source_plants_id;"
    [[ "$output" =~ "3|1" ]]
    [[ "$output" =~ "3|2" ]]

    run sqlite3 .store/store.db "SELECT sample_id, value FROM sample_process ORDER BY value;"
    [[ "$output" =~ "3|cultivation" ]]
    [[ "$output" =~ "3|harvest" ]]
}

@test "entity show renders a multivalue field as a readable list, not a raw table pointer" {
    setup_full_schema
    "$BIN" entity create plant label="Trinidad C2"
    "$BIN" entity create sample label="S1" source_plants="1" process="cultivation"

    run "$BIN" entity show sample 2
    [[ "$output" =~ "source_plants        [1]" ]]
    [[ "$output" =~ "process              [cultivation]" ]]
    [[ ! "$output" =~ "table: 0x" ]]
}

@test "updating a multi field resyncs the junction table -- old values genuinely removed, not just appended" {
    setup_full_schema
    "$BIN" entity create plant label="Trinidad C2"
    "$BIN" entity create plant label="Trinidad SJ"
    "$BIN" entity create sample label="S1" source_plants="1,2" process="cultivation,harvest"

    "$BIN" entity update sample 3 source_plants="2" process="processing"

    run sqlite3 .store/store.db "SELECT source_plants_id FROM sample_source_plants WHERE sample_id = 3;"
    [ "$output" = "2" ]
    run sqlite3 .store/store.db "SELECT value FROM sample_process WHERE sample_id = 3;"
    [ "$output" = "processing" ]
}

@test "ledger history records a multi field's create and update as real old/new sets" {
    setup_full_schema
    "$BIN" entity create plant label="Trinidad C2"
    "$BIN" entity create plant label="Trinidad SJ"
    "$BIN" entity create sample label="S1" source_plants="1" process="cultivation" >/dev/null
    "$BIN" entity update sample 3 source_plants="1,2"

    run "$BIN" ledger history 3
    [[ "$output" =~ "source_plants: nil -> [1]" ]]
    [[ "$output" =~ "source_plants: [1] -> [1, 2]" ]]
}

@test "a required multi field with no values is rejected" {
    write_plant_schema
    mkdir -p schemas
    cat > schemas/sample.lua <<'EOF'
return {
  name = "sample",
  fields = {
    {name = "label", type = "text", required = true, display = true},
    {name = "source_plants", type = "multi_reference", required = true, entity_type = "plant"},
  },
}
EOF
    "$BIN" schema sync

    run "$BIN" entity create sample label="S1"
    [[ "$output" =~ "required field is missing" ]]
}

@test "a multi_reference value pointing at a nonexistent row is rejected" {
    setup_full_schema
    run "$BIN" entity create sample label="S1" source_plants="999"
    [[ "$output" =~ "references a nonexistent plant entity: 999" ]]
}

@test "a multi_select value outside the declared list is rejected" {
    setup_full_schema
    run "$BIN" entity create sample label="S1" process="not_a_real_value"
    [[ "$output" =~ "contains a value not in the declared list: not_a_real_value" ]]
}

@test "/register's layout JSON exposes multi_reference/multi_select field types for the batch-entry table's JS" {
    setup_full_schema
    read session csrf < <(login_test_user alice i)

    run bash -c "GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET PATH_INFO=/register QUERY_STRING=type=sample HTTP_COOKIE='session=${session}; csrf=${csrf}' '$BIN'"
    [[ "$output" =~ '"type":"multi_reference"' ]]
    [[ "$output" =~ '"type":"multi_select"' ]]
}

@test "/api/submit accepts real JSON arrays for multi_reference/multi_select fields" {
    setup_full_schema
    "$BIN" entity create plant label="Trinidad C2"
    read session csrf < <(login_test_user alice i)

    payload='[{"label":"S1","source_plants":[1],"process":["cultivation","harvest"]}]'
    output=$(printf '%s' "$payload" | GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/submit" QUERY_STRING="type=sample" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" HTTP_X_CSRF_TOKEN="${csrf}" "$BIN")
    [[ "$output" =~ '"success":true' ]]

    run sqlite3 .store/store.db "SELECT COUNT(*) FROM sample_process;"
    [ "$output" -eq 2 ]
}

@test "/detail renders a multi_reference field as real links and a multi_select field as a value list" {
    setup_full_schema
    "$BIN" entity create plant label="Trinidad C2"
    "$BIN" entity create sample label="S1" source_plants="1" process="cultivation,harvest"
    read session csrf < <(login_test_user alice i)

    run bash -c "GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET PATH_INFO=/detail QUERY_STRING='type=sample&entity_id=2' HTTP_COOKIE='session=${session}; csrf=${csrf}' '$BIN'"
    [[ "$output" =~ 'href="detail?type=plant&entity_id=1"' ]]
    [[ "$output" =~ "Trinidad C2" ]]
    [[ "$output" =~ "cultivation, harvest" ]]
}
