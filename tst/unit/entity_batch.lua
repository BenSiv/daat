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

function archived_widgets(db_path)
    rows = db.query(db_path, "SELECT COUNT(*) AS n FROM widget WHERE archived_at IS NOT NULL AND archived_at != '';")
    return tonumber(rows[1].n)
end

-- How many queries read a table's archived rows while `fn` runs, and
-- whether any read tagged_item's.
function watch_archived_scans(fn)
    original_query = db.query
    watched = {scans = 0, tagged = false}
    db.query = function(path, statement, ...)
        if string.find(statement, "archived_at IS NOT NULL", 1, true) != nil then
            watched.scans = watched.scans + 1
            if string.find(statement, "tagged_item", 1, true) != nil then
                watched.tagged = true
            end
        end
        return original_query(path, statement, ...)
    end
    result = fn()
    db.query = original_query
    return result, watched
end

function tests.archived_summary_is_indexed_cached_and_refreshed_by_type(db_path)
    print("Testing entity.archived_summary: entity_event index, warm 0-scan cache hit, dirty-type-only refresh (#62 review)")
    check(db.index_exists(db_path, "entity_event", "entity_event_entity_id_idx") == true,
        "expected entity_event_entity_id_idx on a new store")
    types = schema.list(db_path)
    a, _ = entity.create(db_path, "widget", {label = "W-Arch-A"}, "tester")
    b, _ = entity.create(db_path, "widget", {label = "W-Arch-B"}, "tester")
    c, _ = entity.create(db_path, "widget", {label = "W-Arch-C"}, "tester")
    entity.archive(db_path, "widget", a, "tester", nil, "superseded by a repeat run")
    entity.archive(db_path, "widget", b, "tester", nil, "superseded by a repeat run")

    cold = entity.archived_summary(db_path, types)
    check(cold["widget"] != nil, "cold summary should have widget")
    check(cold["widget"].total == archived_widgets(db_path), "cold widget total should match the table, got " ..
        tostring(cold["widget"].total))
    top = cold["widget"].reasons[1]
    check(top != nil, "widget should have a reason")
    check(top.reason == "superseded by a repeat run" and top.n >= 2, "the most common widget reason, got " .. tostring(top.reason))

    -- Nothing new in the ledger: no table read at all.
    warm, watched = watch_archived_scans(function() return entity.archived_summary(db_path, types) end)
    check(watched.scans == 0, "expected 0 archived-row scans on a warm hit, got " .. tostring(watched.scans))
    check(warm["widget"].total == cold["widget"].total, "warm widget total mismatch")

    -- An update that doesn't touch archived_at changes nothing to re-read.
    entity.update(db_path, "widget", c, {label = "W-Arch-C2"}, "tester")
    _, watched = watch_archived_scans(function() return entity.archived_summary(db_path, types) end)
    check(watched.scans == 0, "an ordinary update should re-read nothing, got " .. tostring(watched.scans))

    -- Archiving a widget re-reads widget only; unarchiving brings it back.
    entity.archive(db_path, "widget", c, "tester", nil, "folded into W-Arch-A")
    after_archive, watched = watch_archived_scans(function() return entity.archived_summary(db_path, types) end)
    check(watched.tagged == false, "a widget archive must not rescan tagged_item")
    check(after_archive["widget"].total == cold["widget"].total + 1, "expected one more archived widget")
    entity.unarchive(db_path, "widget", c, "tester")
    after_unarchive = entity.archived_summary(db_path, types)
    check(after_unarchive["widget"].total == cold["widget"].total, "an unarchive takes it back off")
end

function tests.single_row_crud_is_transactional_and_ddl_free(db_path)
    print("Testing single-row create/update/archive/unarchive roll back ledger + projection atomically and run zero DDL in-tx")
    verify = require("verify")
    extension_mod = require("extension")

    fresh_def = {
        name = "fresh_multi",
        fields = {
            {name = "code", type = "text", required = true},
            {name = "flags", type = "multi_select", values = {"x", "y", "z"}},
            {name = "source_ref", type = "polymorphic_reference", allowed_entity_types = {"widget"}},
        },
    }
    schema.register(db_path, fresh_def)
    schema.sync_table(db_path, fresh_def)

    w_id, _ = entity.create(db_path, "widget", {label = "W-Ref"}, "tester")

    -- Verify zero DDL inside BEGIN...COMMIT even on first-ever write to fresh_multi's companion tables
    original_exec = db.exec
    in_tx = false
    tx_ddl = {}
    db.exec = function(path, stmt, ...)
        up = string.upper(stmt)
        if string.find(up, "^%s*BEGIN") != nil or string.find(up, "^%s*START%s+TRANSACTION") != nil then
            in_tx = true
        elseif string.find(up, "^%s*COMMIT") != nil or string.find(up, "^%s*ROLLBACK") != nil then
            in_tx = false
        elseif in_tx and (string.find(up, "^%s*CREATE") != nil or string.find(up, "^%s*ALTER") != nil) then
            table.insert(tx_ddl, stmt)
        end
        return original_exec(path, stmt, ...)
    end
    fm_id, _ = entity.create(db_path, "fresh_multi", {
        code = "FM-1",
        flags = {"x", "y"},
        source_ref = {{type = "widget", id = w_id}},
    }, "tester")
    db.exec = original_exec
    check(fm_id != nil, "expected fresh_multi create to succeed")
    check(#tx_ddl == 0, "expected 0 DDL statements inside single-row create tx, got: " .. tostring(tx_ddl[1]))

    -- Mid-flight failure inside enqueue_after_hooks rolls back ledger + projection on create, update, and archive
    events_before = count_events(db_path)
    orig_enqueue = extension_mod.enqueue_after_hooks
    extension_mod.enqueue_after_hooks = function(...)
        error("simulated mid-crud crash")
    end

    ok_c, _ = pcall(entity.create, db_path, "fresh_multi", {code = "FM-CRASH", flags = {"z"}}, "tester")
    check(ok_c == false, "create crash should propagate")
    check(count_events(db_path) == events_before, "create crash must roll back entity_event")

    ok_u, _ = pcall(entity.update, db_path, "fresh_multi", fm_id, {code = "FM-UPD-CRASH", flags = {"z"}}, "tester")
    check(ok_u == false, "update crash should propagate")
    check(count_events(db_path) == events_before, "update crash must roll back entity_event")
    after_u = entity.get(db_path, "fresh_multi", fm_id)
    check(after_u.code == "FM-1" and #after_u.flags == 2, "update crash must preserve projected row and multivalue table")

    ok_a, _ = pcall(entity.archive, db_path, "fresh_multi", fm_id, "tester")
    extension_mod.enqueue_after_hooks = orig_enqueue
    check(ok_a == false, "archive crash should propagate")
    check(count_events(db_path) == events_before, "archive crash must roll back entity_event")
    after_a = entity.get(db_path, "fresh_multi", fm_id)
    check(after_a.archived_at == nil or after_a.archived_at == "", "archive crash must leave row active")

    l2 = verify.ledger_projection(db_path)
    check(l2.ok == true, "Law L2 must hold after rolled-back CRUD failures")
end

function tests.build_ctx_read_only_blocks_writes_during_validate(db_path)
    print("Testing entity.build_ctx read_only mode omits write methods during entity.validate")
    ro_ctx = entity.build_ctx(db_path, {
        name = "ro_ext",
        capabilities = {read = {"entity"}, write = {"entity"}},
    }, true)
    check(type(ro_ctx.query) == "function", "read_only ctx must keep query")
    check(ro_ctx.create_entity == nil and ro_ctx.update_entity == nil, "read_only ctx must omit create_entity and update_entity")

    rw_ctx = entity.build_ctx(db_path, {
        name = "rw_ext",
        capabilities = {read = {"entity"}, write = {"entity"}},
    })
    check(type(rw_ctx.create_entity) == "function" and type(rw_ctx.update_entity) == "function",
        "default build_ctx must still expose write methods for on_after/UI/tools")
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
