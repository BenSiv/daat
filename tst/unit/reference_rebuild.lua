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
reference = require("reference")
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
