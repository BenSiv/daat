-- tst/unit/view_test.lua
-- Unit tests for src/view.lua -- table-guessing and reference-column
-- resolution across joins (the fix behind commit c01f452).

view = require("view")
db = require("db")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_guess_from_table_plain()
    print("Testing guess_from_table: plain query")
    t = view.guess_from_table("SELECT * FROM sample LIMIT 20;")
    check(t == "sample", "expected 'sample', got " .. tostring(t))
end

function test_guess_from_table_aliased()
    print("Testing guess_from_table: aliased FROM, alias discarded")
    t = view.guess_from_table("SELECT s.id FROM sample s JOIN experiment e ON s.experiment = e.id;")
    check(t == "sample", "expected 'sample' (alias discarded), got " .. tostring(t))
end

function test_guess_tables_plain()
    print("Testing guess_tables: single-table query")
    tables = view.guess_tables("SELECT * FROM sample LIMIT 20;")
    check(#tables == 1, "expected 1 table, got " .. tostring(#tables))
    check(tables[1] == "sample", "expected 'sample', got " .. tostring(tables[1]))
end

function test_guess_tables_join()
    print("Testing guess_tables: plain JOIN")
    tables = view.guess_tables("SELECT s.id, e.title FROM sample s JOIN experiment e ON s.experiment = e.id;")
    check(#tables == 2, "expected 2 tables, got " .. tostring(#tables))
    check(tables[1] == "sample", "expected first table 'sample' (FROM order), got " .. tostring(tables[1]))
    check(tables[2] == "experiment", "expected second table 'experiment', got " .. tostring(tables[2]))
end

function test_guess_tables_left_join_as_alias()
    print("Testing guess_tables: LEFT JOIN with AS aliases")
    tables = view.guess_tables("SELECT s.id FROM sample AS s LEFT JOIN experiment AS e ON s.experiment = e.id;")
    check(#tables == 2, "expected 2 tables, got " .. tostring(#tables))
    check(tables[2] == "experiment", "expected 'experiment' via LEFT JOIN, got " .. tostring(tables[2]))
end

function test_guess_tables_dedup()
    print("Testing guess_tables: same table joined twice is not duplicated")
    tables = view.guess_tables("SELECT * FROM sample s1 JOIN sample s2 ON s1.id = s2.id;")
    check(#tables == 1, "expected 1 deduped table, got " .. tostring(#tables))
end

function test_reference_columns_single_table()
    print("Testing reference_columns: back-compat single string argument")
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE entity_field (entity_type TEXT, name TEXT, ref_entity_type TEXT, type TEXT);")
    db.exec(db_path, "INSERT INTO entity_field VALUES ('sample', 'experiment', 'experiment', 'reference');")
    columns = view.reference_columns(db_path, "sample")
    check(columns["experiment"] == "experiment", "expected sample.experiment -> experiment, got " .. tostring(columns["experiment"]))
    os.remove(db_path)
end

function test_reference_columns_across_join()
    print("Testing reference_columns: resolves a reference column on a JOINed table, not just FROM")
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE entity_field (entity_type TEXT, name TEXT, ref_entity_type TEXT, type TEXT);")
    db.exec(db_path, "INSERT INTO entity_field VALUES ('sample', 'experiment', 'experiment', 'reference');")
    db.exec(db_path, "INSERT INTO entity_field VALUES ('experiment', 'owner', 'person', 'reference');")

    -- The bug this guards against: the old single-table heuristic only
    -- ever looked at guess_from_table's result (the FROM table), so a
    -- reference column belonging to a JOINed table silently fell back to
    -- displaying the raw id instead of a resolved link.
    tables = view.guess_tables("SELECT s.id, e.owner FROM sample s JOIN experiment e ON s.experiment = e.id;")
    columns = view.reference_columns(db_path, tables)
    check(columns["owner"] == "person", "expected owner -> person via joined table, got " .. tostring(columns["owner"]))
    check(columns["experiment"] == "experiment", "expected experiment -> experiment from the FROM table, got " .. tostring(columns["experiment"]))
    os.remove(db_path)
end

function test_reference_columns_first_table_wins_collision()
    print("Testing reference_columns: FROM table wins a column-name collision over a joined table")
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE entity_field (entity_type TEXT, name TEXT, ref_entity_type TEXT, type TEXT);")
    db.exec(db_path, "INSERT INTO entity_field VALUES ('sample', 'owner', 'person', 'reference');")
    db.exec(db_path, "INSERT INTO entity_field VALUES ('experiment', 'owner', 'lab_group', 'reference');")

    columns = view.reference_columns(db_path, {"sample", "experiment"})
    check(columns["owner"] == "person", "expected FROM table's meaning of 'owner' to win, got " .. tostring(columns["owner"]))
    os.remove(db_path)
end

function test_reference_columns_nil_table_list()
    print("Testing reference_columns: nil input returns empty table, not an error")
    columns = view.reference_columns("/tmp/doesnotmatter.db", nil)
    check(type(columns) == "table", "expected a table")
    n = 0
    for _ in pairs(columns) do n = n + 1 end
    check(n == 0, "expected empty table for nil input")
end

function test_is_select_only_rejects_ddl()
    print("Testing is_select_only: rejects DDL/DML keywords on word boundaries")
    check(view.is_select_only("SELECT * FROM sample;") == true, "plain select should pass")
    check(view.is_select_only("DROP TABLE sample;") == false, "DROP should be rejected")
    check(view.is_select_only("SELECT updated_at FROM sample;") == true, "a column literally named updated_at must not be rejected as containing UPDATE")
end

function test_is_select_only_accepts_a_leading_with_clause()
    print("Testing is_select_only: a CTE (WITH ... SELECT) is accepted, same as a plain SELECT")
    check(view.is_select_only("WITH totals AS (SELECT 1) SELECT * FROM totals;") == true,
        "a WITH-prefixed query should be accepted")
    check(view.is_select_only("  WITH totals AS (SELECT 1) SELECT * FROM totals;") == true,
        "leading whitespace before WITH shouldn't matter")
    check(view.is_select_only("WITHOUT_A_SPACE_IS_NOT_WITH SELECT 1") == false,
        "a bare word starting with 'with' isn't the WITH keyword")
end

function test_is_select_only_still_rejects_ddl_inside_a_with_clause()
    print("Testing is_select_only: a CTE query still rejects DDL/stacked statements")
    check(view.is_select_only("WITH totals AS (SELECT 1) DROP TABLE sample;") == false,
        "DDL after a WITH clause should still be rejected")
    check(view.is_select_only("WITH totals AS (SELECT 1) SELECT * FROM totals; DROP TABLE sample;") == false,
        "a stacked statement after a WITH query should still be rejected")
end

-- Run them
test_guess_from_table_plain()
test_guess_from_table_aliased()
test_guess_tables_plain()
test_guess_tables_join()
test_guess_tables_left_join_as_alias()
test_guess_tables_dedup()
test_reference_columns_single_table()
test_reference_columns_across_join()
test_reference_columns_first_table_wins_collision()
test_reference_columns_nil_table_list()
test_is_select_only_rejects_ddl()
test_is_select_only_accepts_a_leading_with_clause()
test_is_select_only_still_rejects_ddl_inside_a_with_clause()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All view.lua tests passed")
