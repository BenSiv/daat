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
    database_adapter.sqlite_close_all()
    entity.create_batch(db_path, "widget", {{label = "W-401"}}, "tester")
    check(database_adapter.sqlite_connection_count() == 0, "expected no cached connection left behind")
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
