-- tst/unit/view_test.lua
-- Unit tests for src/view.lua -- table-guessing and reference-column
-- resolution across joins (the fix behind commit c01f452).

view = require("view")
db = require("database")

unit = require("unit")
check = unit.check
tests = unit.suite()

function tests.guess_from_table_plain()
    print("Testing guess_from_table: plain query")
    t = view.guess_from_table("SELECT * FROM sample LIMIT 20;")
    check(t == "sample", "expected 'sample', got " .. tostring(t))
end

function tests.guess_from_table_aliased()
    print("Testing guess_from_table: aliased FROM, alias discarded")
    t = view.guess_from_table("SELECT s.id FROM sample s JOIN experiment e ON s.experiment = e.id;")
    check(t == "sample", "expected 'sample' (alias discarded), got " .. tostring(t))
end

function tests.guess_tables_plain()
    print("Testing guess_tables: single-table query")
    tables = view.guess_tables("SELECT * FROM sample LIMIT 20;")
    check(#tables == 1, "expected 1 table, got " .. tostring(#tables))
    check(tables[1] == "sample", "expected 'sample', got " .. tostring(tables[1]))
end

function tests.guess_tables_join()
    print("Testing guess_tables: plain JOIN")
    tables = view.guess_tables("SELECT s.id, e.title FROM sample s JOIN experiment e ON s.experiment = e.id;")
    check(#tables == 2, "expected 2 tables, got " .. tostring(#tables))
    check(tables[1] == "sample", "expected first table 'sample' (FROM order), got " .. tostring(tables[1]))
    check(tables[2] == "experiment", "expected second table 'experiment', got " .. tostring(tables[2]))
end

function tests.guess_tables_left_join_as_alias()
    print("Testing guess_tables: LEFT JOIN with AS aliases")
    tables = view.guess_tables("SELECT s.id FROM sample AS s LEFT JOIN experiment AS e ON s.experiment = e.id;")
    check(#tables == 2, "expected 2 tables, got " .. tostring(#tables))
    check(tables[2] == "experiment", "expected 'experiment' via LEFT JOIN, got " .. tostring(tables[2]))
end

function tests.guess_tables_dedup()
    print("Testing guess_tables: same table joined twice is not duplicated")
    tables = view.guess_tables("SELECT * FROM sample s1 JOIN sample s2 ON s1.id = s2.id;")
    check(#tables == 1, "expected 1 deduped table, got " .. tostring(#tables))
end

function tests.reference_columns_single_table()
    print("Testing reference_columns: back-compat single string argument")
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE entity_field (entity_type TEXT, name TEXT, ref_entity_type TEXT, type TEXT);")
    db.exec(db_path, "INSERT INTO entity_field VALUES ('sample', 'experiment', 'experiment', 'reference');")
    columns = view.reference_columns(db_path, "sample")
    check(columns["experiment"] == "experiment", "expected sample.experiment -> experiment, got " .. tostring(columns["experiment"]))
    os.remove(db_path)
end

function tests.reference_columns_across_join()
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

function tests.reference_columns_first_table_wins_collision()
    print("Testing reference_columns: FROM table wins a column-name collision over a joined table")
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE entity_field (entity_type TEXT, name TEXT, ref_entity_type TEXT, type TEXT);")
    db.exec(db_path, "INSERT INTO entity_field VALUES ('sample', 'owner', 'person', 'reference');")
    db.exec(db_path, "INSERT INTO entity_field VALUES ('experiment', 'owner', 'lab_group', 'reference');")

    columns = view.reference_columns(db_path, {"sample", "experiment"})
    check(columns["owner"] == "person", "expected FROM table's meaning of 'owner' to win, got " .. tostring(columns["owner"]))
    os.remove(db_path)
end

function tests.reference_columns_nil_table_list()
    print("Testing reference_columns: nil input returns empty table, not an error")
    columns = view.reference_columns("/tmp/doesnotmatter.db", nil)
    check(type(columns) == "table", "expected a table")
    n = 0
    for _ in pairs(columns) do n = n + 1 end
    check(n == 0, "expected empty table for nil input")
end

function tests.is_select_only_rejects_ddl()
    print("Testing is_select_only: rejects DDL/DML keywords on word boundaries")
    check(view.is_select_only("SELECT * FROM sample;") == true, "plain select should pass")
    check(view.is_select_only("DROP TABLE sample;") == false, "DROP should be rejected")
    check(view.is_select_only("SELECT updated_at FROM sample;") == true, "a column literally named updated_at must not be rejected as containing UPDATE")
end

function tests.is_select_only_accepts_a_leading_with_clause()
    print("Testing is_select_only: a CTE (WITH ... SELECT) is accepted, same as a plain SELECT")
    check(view.is_select_only("WITH totals AS (SELECT 1) SELECT * FROM totals;") == true,
        "a WITH-prefixed query should be accepted")
    check(view.is_select_only("  WITH totals AS (SELECT 1) SELECT * FROM totals;") == true,
        "leading whitespace before WITH shouldn't matter")
    check(view.is_select_only("WITHOUT_A_SPACE_IS_NOT_WITH SELECT 1") == false,
        "a bare word starting with 'with' isn't the WITH keyword")
end

function tests.is_select_only_still_rejects_ddl_inside_a_with_clause()
    print("Testing is_select_only: a CTE query still rejects DDL/stacked statements")
    check(view.is_select_only("WITH totals AS (SELECT 1) DROP TABLE sample;") == false,
        "DDL after a WITH clause should still be rejected")
    check(view.is_select_only("WITH totals AS (SELECT 1) SELECT * FROM totals; DROP TABLE sample;") == false,
        "a stacked statement after a WITH query should still be rejected")
end

function tests.select_only_problem_names_the_offending_token()
    print("Testing select_only_problem: names the keyword, semicolon or missing SELECT")
    check(view.select_only_problem("SELECT * FROM sample") == nil, "plain select has no problem")
    check(string.find(view.select_only_problem("SELECT REPLACE(name, 'a', 'b') FROM sample"), "'replace'", 1, true) != nil,
        "REPLACE() should be named")
    check(string.find(view.select_only_problem("SELECT 1; SELECT 2"), "';'", 1, true) != nil, "stacked statement should name ';'")
    check(string.find(view.select_only_problem("SHOW TABLES"), "must start with SELECT", 1, true) != nil, "non-SELECT should say so")
end

function tests.select_only_ignores_keywords_inside_quoted_strings()
    print("Testing select_only_problem: keywords inside '...' are inert, unless a backslash makes the literal ambiguous")
    check(view.is_select_only("SELECT * FROM entity_event WHERE event_type = 'create'") == true,
        "'create' as a string value should pass")
    check(view.is_select_only("SELECT * FROM entity_event WHERE event_type IN ('update', 'archive')") == true,
        "'update' as a string value should pass")
    check(view.is_select_only("SELECT 'it''s' FROM t WHERE x = 'delete'") == true, "doubled quotes stay inside the literal")
    check(view.is_select_only("SELECT * FROM t WHERE note LIKE '%;%'") == true, "semicolon inside a quoted literal is inert")
    check(view.is_select_only("SELECT 'a' FROM t WHERE 1 = 1 OR (DELETE)") == false, "a keyword after a closed literal is still checked")
    check(view.is_select_only("SELECT 'a\\' ' DELETE FROM t '") == false, "with a backslash, every word is checked")
    check(view.is_select_only("SELECT GET_LOCK('daat_store_migrate', 1)") == false, "GET_LOCK must be refused")
    check(view.is_select_only("SELECT RELEASE_LOCK('daat_store_migrate')") == false, "RELEASE_LOCK must be refused")
    check(view.is_select_only("SELECT SLEEP(5)") == false, "SLEEP must be refused")
    check(view.is_select_only("SELECT LOAD_FILE('/etc/passwd')") == false, "LOAD_FILE must be refused")
    check(view.is_select_only("SELECT 1 INTO OUTFILE '/tmp/x'") == false, "INTO OUTFILE must be refused")
    check(view.is_select_only("SELECT * FROM t /*! UNION SELECT 1 */") == false, "MySQL executable comments must be refused")
end

function tests.run_agent_query_blocks_all_allowlist_bypass_shapes()
    print("Testing run_agent_query blocks aliased comma-joins, quoted/commented identifiers, schema prefixes, and fake CTE literals")
    init = require("init")
    lfs = require("lfs")
    dir = os.tmpname()
    os.remove(dir)
    lfs.mkdir(dir)
    init.do_init({}, dir)
    db_path = dir .. "/.store/store.db"

    -- Sanity check: allowed table works
    cols, rows, err = view.run_agent_query(db_path, "SELECT id, title FROM document")
    check(err == nil and cols != nil, "plain registered document query must succeed, got: " .. tostring(err))

    bypasses = {
        "SELECT u.password_hash FROM document d, auth_user u",
        "SELECT u.password_hash FROM document AS d, auth_user AS u",
        "SELECT password_hash FROM \"auth_user\" UNION SELECT title FROM document",
        "SELECT password_hash FROM `auth_user` UNION SELECT title FROM document",
        "SELECT password_hash FROM [auth_user] UNION SELECT title FROM document",
        "SELECT password_hash FROM /* comment */ auth_user UNION SELECT title FROM document",
        "SELECT password_hash FROM -- line comment\n auth_user UNION SELECT title FROM document",
        "SELECT password_hash FROM (SELECT 1 FROM document) sub, auth_user u",
        "SELECT password_hash FROM main.auth_user UNION SELECT title FROM document",
        "WITH legit AS (SELECT 'auth_user AS (' AS x FROM document) SELECT password_hash FROM auth_user",
        "SELECT content FROM document STRAIGHT_JOIN agent_message",
    }
    for _, bad_sql in ipairs(bypasses) do
        _, bad_rows, bad_err = view.run_agent_query(db_path, bad_sql)
        check(bad_rows == nil and bad_err != nil and string.find(bad_err, "refusing to run", 1, true) != nil,
            "expected allowlist refusal for: " .. bad_sql .. " (got err=" .. tostring(bad_err) .. ")")
    end

    -- Legitimate CTE with column list and quoted string literals still works
    cte_cols, cte_rows, cte_err = view.run_agent_query(
        db_path,
        "WITH docs(doc_id) AS (SELECT id FROM document WHERE title != 'limit') SELECT doc_id FROM docs"
    )
    check(cte_err == nil and cte_cols != nil, "valid column-listed CTE over document must succeed, got: " .. tostring(cte_err))

    -- view.load blocks ../ traversal before touching the filesystem
    f = io.open(dir .. "/secret.lua", "w")
    io.write(f, "return {name = \"secret\", sql = \"SELECT 1;\", columns = {{name = \"x\"}}}\n")
    io.close(f)
    loaded, load_err = view.load(db_path, "../secret", dir)
    check(loaded == nil and load_err != nil and string.find(load_err, "invalid view name", 1, true) != nil,
        "view.load must reject ../secret traversal, got: " .. tostring(load_err))

    check(view.guess_from_table("SELECT id FROM `sample` WHERE id = 1") == "sample", "guess_from_table should strip backticks")
    guessed = view.guess_tables("SELECT s.id FROM `sample` s LEFT JOIN `plant` p ON p.id = s.source")
    check(#guessed == 2 and guessed[1] == "sample" and guessed[2] == "plant", "guess_tables should strip backticks on FROM and JOIN")

    os.execute("rm -rf '" .. dir .. "'")
end

unit.run(tests)
