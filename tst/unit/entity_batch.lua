-- tst/unit/entity_batch.lua
-- entity.create_batch runs the whole batch in one transaction: all rows
-- or none, no DDL inside it (MariaDB commits implicitly on any CREATE/
-- ALTER, which would split the transaction per row), and SQLite's
-- kept-open connection is handed back the way it was found.

init = require("init")
entity = require("entity")
schema = require("schema")
db = require("database")
database_adapter = require("database_adapter")
lfs = require("lfs")

unit = require("unit")
check = unit.check
tests = unit.suite()

WIDGET = {
    name = "widget",
    fields = {
        {name = "label", type = "text", required = true, display = true},
        {name = "size", type = "number", required = false},
    },
}

function count_widgets(db_path)
    rows = db.query(db_path, "SELECT COUNT(*) AS n FROM widget;")
    return tonumber(rows[1].n)
end

function count_events(db_path)
    rows = db.query(db_path, "SELECT COUNT(*) AS n FROM entity_event;")
    return tonumber(rows[1].n)
end

function tests.batch_creates_every_row(db_path)
    print("Testing a batch creates every row, its ledger events and name-index rows")
    events_before = count_events(db_path)
    ids, issues = entity.create_batch(db_path, "widget", {
        {label = "W-001", size = 1}, {label = "W-002", size = 2}, {label = "W-003"},
    }, "tester")
    check(ids != nil and #ids == 3, "expected 3 ids")
    check(count_widgets(db_path) == 3, "expected 3 widget rows")
    check(count_events(db_path) == events_before + 3, "expected one ledger event per row")
    named = db.query(db_path, "SELECT COUNT(*) AS n FROM entity_name_index WHERE entity_type = 'widget';")
    check(tonumber(named[1].n) == 3, "expected each row in the name index")
end

function tests.no_ddl_inside_the_transaction(db_path)
    print("Testing nothing between BEGIN and COMMIT is DDL (MariaDB would commit implicitly)")
    original_exec = db.exec
    inside, ddl = false, {}
    db.exec = function(path, statement, ...)
        upper = string.upper(statement)
        if string.find(upper, "^%s*BEGIN") != nil then
            inside = true
        elseif string.find(upper, "^%s*COMMIT") != nil or string.find(upper, "^%s*ROLLBACK") != nil then
            inside = false
        elseif inside and (string.find(upper, "^%s*CREATE") != nil or string.find(upper, "^%s*ALTER") != nil or string.find(upper, "^%s*DROP") != nil) then
            table.insert(ddl, statement)
        end
        return original_exec(path, statement, ...)
    end
    ok, err = pcall(entity.create_batch, db_path, "widget", {{label = "W-101"}, {label = "W-102"}}, "tester")
    db.exec = original_exec
    check(ok, "batch failed: " .. tostring(err))
    check(#ddl == 0, "DDL ran inside the batch transaction: " .. tostring(ddl[1]))
end

function tests.raised_error_rolls_back_the_whole_batch(db_path)
    print("Testing an error raised on row 2 rolls back row 1 too, and leaves no transaction open")
    before = count_widgets(db_path)
    original_create = entity.create
    calls = 0
    entity.create = function(...)
        calls = calls + 1
        if calls == 2 then
            error("boom")
        end
        return original_create(...)
    end
    ok, err = pcall(entity.create_batch, db_path, "widget", {{label = "W-201"}, {label = "W-202"}}, "tester")
    entity.create = original_create
    check(ok == false and string.find(tostring(err), "boom") != nil, "expected the error to propagate")
    check(count_widgets(db_path) == before, "expected row 1 rolled back")
    ids, _ = entity.create_batch(db_path, "widget", {{label = "W-203"}}, "tester")
    check(ids != nil and count_widgets(db_path) == before + 1, "a later batch must commit on its own")
end

function tests.failed_row_rolls_back_the_whole_batch(db_path)
    print("Testing a row entity.create refuses rolls back the rows before it")
    before = count_widgets(db_path)
    original_create = entity.create
    calls = 0
    entity.create = function(...)
        calls = calls + 1
        if calls == 2 then
            return nil, {{field = "label", severity = "error", message = "refused"}}
        end
        return original_create(...)
    end
    ids, issues = entity.create_batch(db_path, "widget", {{label = "W-301"}, {label = "W-302"}}, "tester")
    entity.create = original_create
    check(ids == nil and issues != nil and issues[1].message == "refused", "expected the row's issues back")
    check(count_widgets(db_path) == before, "expected row 1 rolled back")
end

function tests.keep_open_is_restored(db_path)
    print("Testing SQLite's kept-open connection is closed again after a batch that opened it")
    database_adapter.sqlite_keep_open(false)
    entity.create_batch(db_path, "widget", {{label = "W-401"}}, "tester")
    check(database_adapter.sqlite_connection_count() == 0, "expected no cached connection left behind")
end

function tests.keep_open_preserved_when_already_enabled(db_path)
    print("Testing SQLite keep-open stays enabled when caller enabled it before create_batch")
    database_adapter.sqlite_keep_open(true)
    entity.create_batch(db_path, "widget", {{label = "W-402"}}, "tester")
    check(database_adapter.is_sqlite_keep_open() == true, "expected keep_open to remain enabled")
    database_adapter.sqlite_keep_open(false)
end

function tests.ctx_query_supports_in_list_and_batched_overrides(db_path)
    print("Testing ctx.query IN-list filter and multi-row computed field overrides")
    tagged_def = {
        name = "tagged_item",
        fields = {
            {name = "code", type = "text", required = true},
            {name = "tags", type = "multi_select", values = {"alpha", "beta", "gamma"}},
            {name = "origin", type = "polymorphic_reference", allowed_entity_types = {"widget"}},
        },
    }
    schema.register(db_path, tagged_def)
    w_ids, _ = entity.create_batch(db_path, "widget", {{label = "Origin-A"}, {label = "Origin-B"}}, "tester")
    id1, _ = entity.create(db_path, "tagged_item", {code = "T1", tags = {"alpha", "gamma"}, origin = {{type = "widget", id = w_ids[1]}}}, "tester")
    id2, _ = entity.create(db_path, "tagged_item", {code = "T2", tags = {"beta"}, origin = {{type = "widget", id = w_ids[2]}}}, "tester")
    entity.create(db_path, "tagged_item", {code = "T3", tags = {"alpha"}}, "tester")

    ctx = entity.build_ctx(db_path, {name = "perf_test", capabilities = {read = {"entity"}}})
    empty_res = ctx.query("tagged_item", {code = {}})
    check(#empty_res == 0, "expected empty table filter to return 0 rows")

    matched = ctx.query("tagged_item", {id = {id1, id2}})
    check(#matched == 2, "expected 2 rows from IN filter, got " .. tostring(#matched))
    by_code = {}
    for _, r in ipairs(matched) do
        by_code[r.code] = r
    end
    check(by_code["T1"] != nil and #by_code["T1"].tags == 2, "expected 2 tags on T1")
    check(by_code["T1"].origin != nil and #by_code["T1"].origin == 1 and tonumber(by_code["T1"].origin[1].id) == tonumber(w_ids[1]), "expected polymorphic origin on T1")
    check(by_code["T2"] != nil and #by_code["T2"].tags == 1 and by_code["T2"].tags[1] == "beta", "expected 1 tag on T2")
end

function tests.counts_by_type_and_preload_all_fields_cache_and_delta_refresh(db_path)
    print("Testing entity.counts_by_type cold UNION ALL, warm 0-scan cache hit, and dirty-type-only delta refresh")
    types = schema.list(db_path)
    cold = entity.counts_by_type(db_path, types)
    for _, t in ipairs(types) do
        expected = entity.count(db_path, t.name)
        check(cold[t.name] == expected, "cold count mismatch for " .. t.name .. ": " .. tostring(cold[t.name]) .. " vs " .. tostring(expected))
    end

    -- Warm hit: zero SELECT COUNT(*) table scans when MAX(event_id) is unchanged.
    original_query = db.query
    count_queries = 0
    db.query = function(path, statement, ...)
        if string.find(string.upper(statement), "COUNT%(%*%)") != nil then
            count_queries = count_queries + 1
        end
        return original_query(path, statement, ...)
    end
    warm = entity.counts_by_type(db_path, types)
    db.query = original_query
    check(count_queries == 0, "expected 0 COUNT(*) queries on warm cache hit, got " .. tostring(count_queries))
    check(warm["widget"] == cold["widget"], "warm widget count mismatch")

    -- An update-only event does not change active counts -> 0 COUNT(*) scans.
    w_rows = db.query(db_path, "SELECT id FROM widget WHERE archived_at IS NULL LIMIT 1;")
    entity.update(db_path, "widget", tonumber(w_rows[1].id), {label = "W-Updated"}, "tester")
    count_queries = 0
    db.query = function(path, statement, ...)
        if string.find(string.upper(statement), "COUNT%(%*%)") != nil then
            count_queries = count_queries + 1
        end
        return original_query(path, statement, ...)
    end
    after_update = entity.counts_by_type(db_path, types)
    db.query = original_query
    check(count_queries == 0, "expected 0 COUNT(*) queries after update-only event, got " .. tostring(count_queries))
    check(after_update["widget"] == cold["widget"], "update must not alter active count")

    -- Creating and archiving a widget recounts only 'widget', never 'tagged_item'.
    new_id, _ = entity.create(db_path, "widget", {label = "W-Delta"}, "tester")
    scanned_tagged = false
    db.query = function(path, statement, ...)
        if string.find(statement, "COUNT%(%*%)") != nil and string.find(statement, "tagged_item") != nil then
            scanned_tagged = true
        end
        return original_query(path, statement, ...)
    end
    after_create = entity.counts_by_type(db_path, types)
    db.query = original_query
    check(scanned_tagged == false, "delta refresh must not rescan unchanged tagged_item table")
    check(after_create["widget"] == cold["widget"] + 1, "expected widget count + 1 after create")

    entity.archive(db_path, "widget", new_id, "tester")
    after_archive = entity.counts_by_type(db_path, types)
    check(after_archive["widget"] == cold["widget"], "expected widget count restored after archive")

    -- schema.relationships preloads all entity_field rows in 1 query.
    schema.clear_cache(db_path)
    field_queries = 0
    db.query = function(path, statement, ...)
        if string.find(statement, "FROM entity_field") != nil then
            field_queries = field_queries + 1
        end
        return original_query(path, statement, ...)
    end
    edges = schema.relationships(db_path, types)
    for _, t in ipairs(types) do
        schema.fields(db_path, t.name)
    end
    db.query = original_query
    check(field_queries == 1, "expected 1 entity_field preload query across all types, got " .. tostring(field_queries))
    check(#edges >= 1, "expected at least 1 relationship edge")
end

dir = os.tmpname()
os.remove(dir)
lfs.mkdir(dir)
init.do_init({}, dir)
db_path = dir .. "/.store/store.db"
schema.register(db_path, WIDGET)
schema.sync_table(db_path, WIDGET)

unit.run(tests, db_path)
os.execute("rm -rf '" .. dir .. "'")
