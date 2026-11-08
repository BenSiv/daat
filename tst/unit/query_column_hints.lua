-- tst/unit/query_column_hints.lua
-- A query that fails on a column that doesn't exist names the real
-- columns (#8): view.query_aliases resolves a column's prefix through the
-- query's own FROM/JOIN aliases, and entity.query's recover hint lists
-- the real columns of the table it meant and the closest name. Run
-- against the demo-lab schemas (tst/eval/demo-lab/schemas/), with the
-- guesses the 2026-10-30 live scorecard saw.

agent_tools = require("agent_tools")
view = require("view")
schema = require("schema")
init = require("init")
lfs = require("lfs")

unit = require("unit")
check = unit.check
tests = unit.suite()

-- Referenced types first, so each reference resolves when it's registered.
DEMO_SCHEMAS = {"person", "ingredient", "culture_medium", "project", "experiment", "sample", "measurement"}

function query_error(db_path, sql_text)
    result, err = agent_tools.execute_tool(db_path, "test", 0, "entity", "query", {sql = sql_text})
    check(result == nil, "expected the query to fail: " .. sql_text)
    return tostring(err)
end

function contains(text, part)
    return string.find(text, part, 1, true) != nil
end

function tests.query_aliases_maps_each_alias_to_its_table()
    print("Testing view.query_aliases")
    a = view.query_aliases("SELECT e.title FROM experiment e JOIN project AS p ON p.id = e.project LEFT JOIN person pe ON pe.id = p.lead WHERE e.status = 'running'")
    check(a.e == "experiment" and a.p == "project" and a.pe == "person", "aliases with and without AS")
    check(a.experiment == "experiment" and a.project == "project", "each table under its own name too")
    check(a.where == nil and a.left == nil, "clause words aren't aliases")
    b = view.query_aliases("SELECT * FROM sample s, measurement m WHERE m.sample = s.id")
    check(b.s == "sample" and b.m == "measurement", "a comma-separated FROM list")
    c = view.query_aliases("SELECT COUNT(*) FROM experiment WHERE archived_at IS NULL")
    check(c.experiment == "experiment" and c.where == nil, "a table with no alias")
end

function tests.an_alias_the_query_never_defines_is_named(db_path)
    print("Testing a prefix with no table or alias behind it")
    -- From the 2026-10-30 live run: p.name, with project never aliased p.
    err = query_error(db_path, "SELECT p.title FROM experiment e JOIN project ON e.project = project.id")
    check(contains(err, "the query has no table or alias 'p'"), "names the missing alias, got: " .. err)
    check(contains(err, "e = experiment") and contains(err, "project"), "lists what the query does name, got: " .. err)
end

function tests.a_wrong_column_gets_the_closest_real_one(db_path)
    print("Testing a guessed column gets did-you-mean and the table's real columns")
    err = query_error(db_path, "SELECT e.lab_number FROM experiment e WHERE e.archived_id IS NULL")
    check(contains(err, "did you mean e.archived_at?"), "suggests archived_at, got: " .. err)
    check(contains(err, "real columns -- experiment: id,") and contains(err, "lab_number") and contains(err, "started_on"),
        "lists experiment's real columns, got: " .. err)
    -- The generic line is still there: the hint is added, never instead.
    check(contains(err, "call entity.fields/entity.relationships for the real names"), "keeps the original error")
end

function tests.a_longer_guess_containing_the_real_name_is_matched(db_path)
    print("Testing time_hours suggests hours")
    err = query_error(db_path, "SELECT m.time_hours FROM measurement m")
    check(contains(err, "did you mean m.hours?"), "suggests hours, got: " .. err)
end

function tests.a_guess_with_no_close_column_only_lists_the_real_ones(db_path)
    print("Testing no suggestion when nothing is really close")
    -- m.time was told "did you mean m.name?" 8 times on the 2026-11-08 run.
    for _, guess in ipairs({"m.time", "m.od", "m.date"}) do
        err = query_error(db_path, "SELECT " .. guess .. " FROM measurement m")
        check(contains(err, "did you mean") == false, guess .. " shouldn't get a suggestion, got: " .. err)
        check(contains(err, "real columns -- measurement: id,") and contains(err, "hours") and contains(err, "od600"),
            guess .. " should still list the real columns, got: " .. err)
    end
end

function tests.a_multi_value_join_table_gets_its_columns(db_path)
    print("Testing a multi-value field's join table")
    err = query_error(db_path, "SELECT cmi.ingredient_id FROM culture_medium_ingredients cmi")
    check(contains(err, "did you mean cmi.ingredients_id?"), "suggests ingredients_id, got: " .. err)
    check(contains(err, "culture_medium_ingredients: "), "lists the join table's columns, got: " .. err)
end

function tests.an_unprefixed_column_lists_every_table_in_the_query(db_path)
    print("Testing a column without a prefix")
    err = query_error(db_path, "SELECT start_date FROM experiment JOIN project ON experiment.project = project.id")
    check(contains(err, "experiment: ") and contains(err, "project: "), "lists both tables, got: " .. err)
end

function tests.entity_relationships_lists_the_real_columns(db_path)
    print("Testing entity.relationships carries the column names")
    result = agent_tools.execute_tool(db_path, "test", 0, "entity", "relationships", {})
    check(contains(result, "measurement.sample -> sample (reference)"), "keeps the edges, got: " .. tostring(result))
    check(contains(result, "\nmeasurement: sample, hours, od600\n"), "lists a type's columns, got: " .. tostring(result))
    check(contains(result, "culture_medium_ingredients: culture_medium_id, ingredients_id (join table for culture_medium.ingredients)"),
        "lists a multi-value join table, got: " .. tostring(result))
    check(contains(result, "\nculture_medium: label, ph\n"), "a multi-value field isn't a column, got: " .. tostring(result))
    check(contains(result, "Every entity table also has: id, name,"), "names the system columns, got: " .. tostring(result))
    check(contains(result, "stored in entity_ref(from_type, from_id, field_name, to_type, to_id): ") and contains(result, "sample.source"),
        "says where a polymorphic field lives, got: " .. tostring(result))
end

function tests.other_errors_get_no_column_hint(db_path)
    print("Testing an error that isn't a missing column gets no column hint")
    err = query_error(db_path, "SELECT FROM experiment")
    check(contains(err, "real columns") == false and contains(err, "did you mean") == false,
        "a syntax error isn't told about columns, got: " .. err)
end

dir = os.tmpname()
os.remove(dir)
lfs.mkdir(dir)
init.do_init({}, dir)
db_path = dir .. "/.store/store.db"
for _, name in ipairs(DEMO_SCHEMAS) do
    def, err = schema.load_file("tst/eval/demo-lab/schemas/" .. name .. ".lua")
    check(def != nil, "can't load the demo-lab schema " .. name .. ": " .. tostring(err))
    if def != nil then
        schema.register(db_path, def)
    end
end

unit.run(tests, db_path)
os.execute("rm -rf '" .. dir .. "'")
