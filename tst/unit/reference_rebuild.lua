-- tst/unit/reference_rebuild.lua
-- reference.rebuild_names (`repair references`) must finish even when two
-- name prefixes are one value to the database: MariaDB's case- and
-- accent-insensitive collation made a plain INSERT abort the repair on
-- prod after the index was rebuilt and before any document was re-read.
-- SQLite compares the prefixes exactly, so the test pins the statement:
-- every prefix insert is an INSERT OR IGNORE / INSERT IGNORE.

init = require("init")
entity = require("entity")
schema = require("schema")
reference = require("document.reference")
db = require("database")
lfs = require("lfs")

unit = require("unit")
check = unit.check
tests = unit.suite()

GIZMO = {
    name = "gizmo",
    fields = {{name = "label", type = "text", required = true, display = true}},
}

function tests.prefix_inserts_ignore_duplicates(db_path)
    print("Testing every prefix rebuild_names writes is an ignore-insert")
    original_exec = db.exec
    plain = {}
    db.exec = function(path, statement, ...)
        if string.find(statement, "entity_name_prefix", 1, true) != nil
            and string.find(string.upper(statement), "^%s*INSERT") != nil
            and string.find(string.upper(statement), "IGNORE", 1, true) == nil then
            table.insert(plain, statement)
        end
        return original_exec(path, statement, ...)
    end
    ok, err = pcall(reference.rebuild_names, db_path)
    db.exec = original_exec
    check(ok, "rebuild failed: " .. tostring(err))
    check(#plain == 0, "plain INSERT into entity_name_prefix: " .. tostring(plain[1]))
end

function tests.rebuild_twice_keeps_every_name(db_path)
    print("Testing a second rebuild over an already-built index indexes the same names")
    first = reference.rebuild_names(db_path)
    second = reference.rebuild_names(db_path)
    check(first == second and first >= 2, "expected the same count twice, got " .. tostring(first) .. " and " .. tostring(second))
    rows = db.query(db_path, "SELECT COUNT(*) AS n FROM entity_name_prefix WHERE prefix = 'gx10';")
    check(tonumber(rows[1].n) == 1, "expected the shared prefix once")
end

function tests.rebuild_queries_scale_with_types_not_rows(db_path)
    print("Testing rebuild_names reads entity_field per entity type, never once per row")
    batch = {}
    for i = 1, 25 do
        table.insert(batch, {name = string.format("IMP-%04d", 1000 + i), label = "Imported " .. tostring(i)})
    end
    ids, issues = entity.create_batch(db_path, "gizmo", batch, "tester")
    check(ids != nil and #ids == 25, "expected 25 imported gizmos")

    type_count = #schema.list(db_path)
    original_query = db.query
    field_queries = 0
    db.query = function(path, query, ...)
        if string.find(query, "FROM entity_field", 1, true) != nil then
            field_queries = field_queries + 1
        end
        return original_query(path, query, ...)
    end
    ok, err = pcall(reference.rebuild_names, db_path)
    db.query = original_query
    check(ok, "rebuild failed: " .. tostring(err))
    check(field_queries <= type_count,
        string.format("rebuild_names queried entity_field %d times across %d types (per-row N+1)", field_queries, type_count))
end

function tests.type_without_display_indexes_builtin_name_only(db_path)
    print("Testing an entity type with no display field indexes imported row.name and skips unnamed rows cleanly")
    instrument = {
        name = "instrument",
        fields = {
            {name = "number", type = "number", required = true},
            {name = "asset_code", type = "text", required = true},
        },
    }
    schema.register(db_path, instrument)
    schema.sync_table(db_path, instrument)
    named_id, _ = entity.create(db_path, "instrument", {name = "SPEC-901", number = 1, asset_code = "EQ-001"}, "tester")
    unnamed_id, _ = entity.create(db_path, "instrument", {number = 2, asset_code = "EQ-002"}, "tester")
    check(named_id != nil and unnamed_id != nil, "created both instruments")

    rows = db.query(db_path, "SELECT entity_id, name_key FROM entity_name_index WHERE entity_type = 'instrument';")
    check(rows != nil and #rows == 1 and tonumber(rows[1].entity_id) == tonumber(named_id) and rows[1].name_key == "spec901",
        "expected only SPEC-901 indexed on create")

    reference.rebuild_names(db_path)
    rows = db.query(db_path, "SELECT entity_id, name_key FROM entity_name_index WHERE entity_type = 'instrument';")
    check(rows != nil and #rows == 1 and tonumber(rows[1].entity_id) == tonumber(named_id) and rows[1].name_key == "spec901",
        "expected only SPEC-901 indexed after rebuild")
end

function tests.rebuild_migrates_legacy_index_and_tolerates_add_column_race()
    print("Testing rebuild_names adds distinctive before CLI repair and init_schema tolerates concurrent ADD COLUMN")
    legacy_dir = os.tmpname()
    os.remove(legacy_dir)
    lfs.mkdir(legacy_dir)
    init.do_init({}, legacy_dir)
    legacy_db = legacy_dir .. "/.store/store.db"
    schema.register(legacy_db, GIZMO)
    schema.sync_table(legacy_db, GIZMO)
    entity.create(legacy_db, "gizmo", {label = "GX-2001"}, "tester")

    -- Simulate a store built before #38 whose first command after deploy is
    -- `daat repair references` from the CLI, before any web request ran init_schema.
    db.exec(legacy_db, "DROP TABLE entity_name_index;")
    db.exec(legacy_db, "CREATE TABLE entity_name_index (name_key VARCHAR(255) NOT NULL, entity_type VARCHAR(64) NOT NULL, entity_id INTEGER NOT NULL);")
    count = reference.rebuild_names(legacy_db)
    check(count == 1, "rebuild_names migrated legacy table and indexed GX-2001, got " .. tostring(count))

    -- Simulate a concurrent CGI request winning `ADD COLUMN distinctive` right
    -- before our ALTER runs, vs a genuine ALTER failure where the column stays absent.
    db.exec(legacy_db, "DROP TABLE entity_name_index;")
    db.exec(legacy_db, "CREATE TABLE entity_name_index (name_key VARCHAR(255) NOT NULL, entity_type VARCHAR(64) NOT NULL, entity_id INTEGER NOT NULL);")
    original_exec = db.exec
    db.exec = function(path, statement, ...)
        if string.find(statement, "ADD COLUMN", 1, true) != nil and string.find(statement, "distinctive", 1, true) != nil then
            original_exec(path, statement, ...)
            error("duplicate column name: distinctive")
        end
        return original_exec(path, statement, ...)
    end
    ok_race, race_err = pcall(reference.init_schema, legacy_db)
    db.exec = original_exec
    check(ok_race, "concurrent ADD COLUMN should succeed once column exists: " .. tostring(race_err))

    db.exec(legacy_db, "DROP TABLE entity_name_index;")
    db.exec(legacy_db, "CREATE TABLE entity_name_index (name_key VARCHAR(255) NOT NULL, entity_type VARCHAR(64) NOT NULL, entity_id INTEGER NOT NULL);")
    db.exec = function(path, statement, ...)
        if string.find(statement, "ADD COLUMN", 1, true) != nil and string.find(statement, "distinctive", 1, true) != nil then
            error("disk full")
        end
        return original_exec(path, statement, ...)
    end
    ok_fail, fail_err = pcall(reference.init_schema, legacy_db)
    db.exec = original_exec
    check(ok_fail == false and string.find(tostring(fail_err), "disk full", 1, true) != nil,
        "real ADD COLUMN failure still raises when column is missing: " .. tostring(fail_err))

    os.execute("rm -rf '" .. legacy_dir .. "'")
end

dir = os.tmpname()
os.remove(dir)
lfs.mkdir(dir)
init.do_init({}, dir)
db_path = dir .. "/.store/store.db"
schema.register(db_path, GIZMO)
schema.sync_table(db_path, GIZMO)
entity.create_batch(db_path, "gizmo", {{label = "GX-1001"}, {label = "GX-1002"}}, "tester")

unit.run(tests, db_path)
os.execute("rm -rf '" .. dir .. "'")
