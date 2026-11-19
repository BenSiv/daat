-- tst/unit/entity_find.lua
-- entity.find turns a name as the user writes it into the entity it refers
-- to (#38): exact on the label and identifier fields, ignoring case, spacing
-- and separators, every match listed, nothing partial or ranked. The
-- `identifier` flag is what puts a field like lab_number in reach. One name
-- index serves it and document references: every name is in it, marked
-- distinctive or not, and only references keep to the distinctive ones.

agent_tools = require("agent_tools")
reference = require("document.reference")
document = require("document")
entity = require("entity")
schema = require("schema")
db = require("database")
init = require("init")
config = require("config")
lfs = require("lfs")

unit = require("unit")
check = unit.check
tests = unit.suite()

BATCH = {
    name = "batch",
    fields = {
        {name = "title", type = "text", required = true, display = true},
        {name = "lab_number", type = "text", required = true, identifier = true},
        {name = "notes", type = "text", required = false},
    },
}

MEDIUM = {
    name = "medium",
    fields = {
        {name = "label", type = "text", required = true, display = true},
    },
}

-- No display field, like most celleste-lims types: a row registered in daat
-- has no builtin name either, so its identifier is all it's known by.
GEAR = {
    name = "gear",
    fields = {
        {name = "number", type = "number", required = true},
        {name = "asset_code", type = "text", required = true, identifier = true},
        {name = "room", type = "text", required = false},
    },
}

function find(db_path, args)
    return agent_tools.execute_tool(db_path, "test", 0, "entity", "find", args)
end

function contains(text, part)
    return string.find(tostring(text), part, 1, true) != nil
end

function new_batch(db_path, title, lab_number, notes)
    id, err = entity.create(db_path, "batch", {title = title, lab_number = lab_number, notes = notes}, "tester")
    check(id != nil, "can't create batch: " .. tostring(err))
    return tonumber(id)
end

function tests.an_identifier_field_resolves_however_it_is_written(db_path)
    print("Testing a lab number resolves ignoring case, spacing and separators")
    id = new_batch(db_path, "Light stress trial", "EXP-017")
    for _, written in ipairs({"EXP-017", "exp-017", "Exp 017", "exp017", " EXP.017 "}) do
        result = find(db_path, {text = written})
        check(contains(result, "batch " .. id .. " \"Light stress trial\" (lab_number EXP-017)"),
            written .. " should resolve, got: " .. tostring(result))
    end
    one = find(db_path, {text = "EXP-017"})
    check(contains(one, "Use its id: entity.get with entity_type batch and entity_id " .. id .. ", or batch.id = " .. id .. " in entity.query."),
        "names the id to use, got: " .. tostring(one))
    check(contains(one, "Several entities") == false, "one match isn't several")
    check(contains(one, "cite as: EXP-017 ([Light stress trial](/detail?type=batch&entity_id=" .. id .. "))"),
        "a ready-made citation with the lab number outside the link, got: " .. tostring(one))
end

function tests.a_label_resolves_without_repeating_itself(db_path)
    print("Testing a display label resolves, including one the index skips")
    new_batch(db_path, "Run-A9", "EXP-100")
    labelled = find(db_path, {text = "run a9"})
    check(contains(labelled, "\"Run-A9\"") and contains(labelled, "(title") == false, "got: " .. tostring(labelled))
    id = entity.create(db_path, "medium", {label = "YPD"}, "tester")
    check(reference.name_key("YPD") == nil, "YPD isn't distinctive, so this is the fallback compare")
    short = find(db_path, {text = "ypd"})
    check(contains(short, "medium " .. tonumber(id) .. " \"YPD\""), "got: " .. tostring(short))
    check(contains(short, "cite as: [YPD](/detail?type=medium&entity_id=" .. tonumber(id) .. ")"),
        "a label match cites the label as the link, got: " .. tostring(short))
    rows = db.query(db_path, string.format(
        "SELECT distinctive FROM entity_name_index WHERE entity_type = 'medium' AND entity_id = %d;", tonumber(id)))
    check(#rows == 1 and tonumber(rows[1].distinctive) == 0, "YPD is indexed, as not distinctive")
    check(#reference.find(db_path, "Plates were poured with YPD today.") == 0,
        "a name that isn't distinctive is never a document reference")
end

function tests.only_the_whole_name_on_a_naming_field_matches(db_path)
    print("Testing no partial match, and no match on a field that isn't a name")
    new_batch(db_path, "Partial trial", "EXP-200", "Repeat of EXP-300 with more light")
    check(contains(find(db_path, {text = "EXP-20"}), "No entity is named"), "a prefix isn't a match")
    check(contains(find(db_path, {text = "Partial"}), "No entity is named"), "part of a label isn't a match")
    check(contains(find(db_path, {text = "EXP-300"}), "No entity is named"), "a mention in notes isn't a match")
end

function tests.every_match_is_listed_and_a_type_narrows_them(db_path)
    print("Testing a shared name lists every entity, and entity_type narrows it")
    first = new_batch(db_path, "Shared one", "EXP-400")
    second = new_batch(db_path, "Shared two", "EXP-400")
    third = entity.create(db_path, "medium", {label = "EXP-400"}, "tester")
    result = find(db_path, {text = "EXP-400"})
    check(contains(result, "batch " .. first .. " ") and contains(result, "batch " .. second .. " ")
        and contains(result, "medium " .. tonumber(third) .. " "), "all three listed, got: " .. tostring(result))
    check(contains(result, "Several entities have this name") and contains(result, "Use its id") == false,
        "several matches don't pick one, got: " .. tostring(result))
    narrowed = find(db_path, {text = "EXP-400", entity_type = "medium"})
    check(contains(narrowed, "medium ") and contains(narrowed, "batch ") == false, "got: " .. tostring(narrowed))
end

function tests.no_match_says_a_number_is_not_a_row_id(db_path)
    print("Testing the no-match answer")
    id = new_batch(db_path, "Row id trap", "EXP-500")
    numbered = find(db_path, {text = tostring(id)})
    check(contains(numbered, "No entity is named") and contains(numbered, "not a row id"), "a row id isn't a name, got: " .. tostring(numbered))
    check(contains(numbered, "checked the label and identifier fields of every entity type."), "says what was checked, got: " .. tostring(numbered))
    narrowed = find(db_path, {text = "EXP-555", entity_type = "medium"})
    check(contains(narrowed, "identifier fields of every medium."), "names the type it checked, got: " .. tostring(narrowed))
    worded = find(db_path, {text = "nothing here"})
    check(contains(worded, "No entity is named") and contains(worded, "row id") == false, "got: " .. tostring(worded))
    empty = find(db_path, {text = "--"})
    check(contains(empty, "No entity is named"), "only separators, got: " .. tostring(empty))
end

function tests.an_archived_entity_is_not_found(db_path)
    print("Testing an archived entity isn't found, before or after its hook updates the index")
    id = new_batch(db_path, "To archive", "EXP-600")
    check(contains(find(db_path, {text = "EXP-600"}), "batch " .. id), "found before archiving")
    entity.archive(db_path, "batch", id, "tester")
    check(contains(find(db_path, {text = "EXP-600"}), "No entity is named"), "gone even while the index lags")
    document.on_entity_archived(db_path, "batch", id)
    rows = db.query(db_path, string.format(
        "SELECT COUNT(*) AS n FROM entity_name_index WHERE entity_type = 'batch' AND entity_id = %d;", id))
    check(tonumber(rows[1].n) == 0, "the hook drops every name, got " .. tostring(rows[1].n))
    check(contains(find(db_path, {text = "EXP-600"}), "No entity is named"), "gone after the hook")
end

function tests.a_wrong_type_gets_the_shared_hint(db_path)
    print("Testing a wrong entity_type")
    result, err = find(db_path, {text = "EXP-017", entity_type = "batches"})
    check(result == nil, "a wrong type is an error")
    check(contains(err, "unknown entity type: batches") and contains(err, "did you mean 'batch'?"), "got: " .. tostring(err))
    missing, missing_err = find(db_path, {})
    check(missing == nil and contains(missing_err, "find requires text"), "got: " .. tostring(missing_err))
end

function tests.a_type_outside_the_index_is_refused_not_missed(db_path)
    print("Testing document and tag aren't claimed as checked")
    result, err = find(db_path, {text = "Some document title", entity_type = "document"})
    check(result == nil and contains(err, "doesn't look up documents") and contains(err, "document.search"),
        "points to document.search, got: " .. tostring(result) .. " / " .. tostring(err))
    result, err = find(db_path, {text = "growth", entity_type = "tag"})
    check(result == nil and contains(err, "doesn't look up tag") and contains(err, "entity.query"),
        "points to entity.query, got: " .. tostring(result) .. " / " .. tostring(err))
end

function tests.an_entity_with_no_label_is_shown_by_its_identifier(db_path)
    print("Testing a display-less row with no builtin name")
    id = entity.create(db_path, "gear", {number = 3, asset_code = "EQ-041", room = "B12"}, "tester")
    result = find(db_path, {text = "eq 041"})
    check(contains(result, "gear " .. tonumber(id) .. " (asset_code EQ-041)"), "shown by its identifier, got: " .. tostring(result))
    check(contains(result, "cite as: [EQ-041](/detail?type=gear&entity_id=" .. tonumber(id) .. ")"),
        "cited by its identifier, got: " .. tostring(result))
    check(contains(result, "nil") == false, "never a literal nil, got: " .. tostring(result))
    named = entity.create(db_path, "gear", {name = "SPEC-901", number = 4, asset_code = "EQ-042"}, "tester")
    imported = find(db_path, {text = "EQ-042"})
    check(contains(imported, "gear " .. tonumber(named) .. " \"SPEC-901\" (asset_code EQ-042)"),
        "an imported row keeps its builtin name as the label, got: " .. tostring(imported))
end

function tests.aliases_apply_as_they_do_to_documents(db_path)
    print("Testing reference_aliases rewrite the name before the lookup")
    id = new_batch(db_path, "Alias trial", "EXP-027")
    original = config.platform_config
    config.platform_config = function()
        return {reference_aliases = {{"experiment%s*(%d)", "exp%1"}}}
    end
    result = find(db_path, {text = "Experiment 027"})
    config.platform_config = original
    check(contains(result, "batch " .. id .. " \"Alias trial\" (lab_number EXP-027)"), "got: " .. tostring(result))
    check(contains(find(db_path, {text = "Experiment 027"}), "No entity is named"), "without the alias it's no match")
end

function tests.the_index_holds_every_name_and_rebuild_keeps_them(db_path)
    print("Testing the name index holds an entity's label and identifier, and survives repair")
    id = new_batch(db_path, "Indexed A1", "EXP-700")
    function keys()
        rows = db.query(db_path, string.format(
            "SELECT name_key FROM entity_name_index WHERE entity_type = 'batch' AND entity_id = %d ORDER BY name_key;", id))
        out = {}
        for _, row in ipairs(rows) do
            table.insert(out, row.name_key)
        end
        return table.concat(out, ",")
    end
    check(keys() == "exp700,indexeda1", "both names indexed, got: " .. keys())
    reference.rebuild_names(db_path)
    check(keys() == "exp700,indexeda1", "rebuild keeps both, got: " .. keys())
end

function tests.names_written_alike_get_one_index_row(db_path)
    print("Testing a label and identifier sharing a key don't look like two entities")
    id = new_batch(db_path, "EXP-800", "exp 800")
    rows = db.query(db_path, string.format(
        "SELECT COUNT(*) AS n FROM entity_name_index WHERE entity_type = 'batch' AND entity_id = %d;", id))
    check(tonumber(rows[1].n) == 1, "expected one row, got " .. tostring(rows[1].n))
    found = reference.find(db_path, "see EXP-800")
    check(#found == 1 and found[1].entity_id == id, "still a reference target")
end

function tests.a_document_mention_of_an_identifier_is_a_reference(db_path)
    print("Testing a mention of an identifier reaches document references")
    id = new_batch(db_path, "Mentioned trial", "EXP-900")
    found = reference.find(db_path, "The notes for EXP-900 are here.")
    check(#found == 1 and found[1].entity_type == "batch" and found[1].entity_id == id, "expected the batch")
end

function tests.a_newly_marked_field_is_found_after_the_names_rebuild(db_path)
    print("Testing a name missing from the index is found once rebuild_names runs, and no table is scanned")
    id = new_batch(db_path, "Before repair", "EXP-950")
    db.exec(db_path, string.format("DELETE FROM entity_name_index WHERE entity_type = 'batch' AND entity_id = %d;", id))
    original_query = db.query
    scans = 0
    db.query = function(path, query, ...)
        if string.find(query, "FROM batch", 1, true) != nil or string.find(query, "FROM medium", 1, true) != nil then
            scans = scans + 1
        end
        return original_query(path, query, ...)
    end
    missed = find(db_path, {text = "exp 950"})
    db.query = original_query
    check(contains(missed, "No entity is named"), "only the index is read, got: " .. tostring(missed))
    check(scans == 0, "a miss reads no entity table, read " .. tostring(scans))
    reference.rebuild_names(db_path)
    check(contains(find(db_path, {text = "exp 950"}), "batch " .. id .. " \"Before repair\" (lab_number EXP-950)"), "found after the rebuild")
end

function tests.the_rebuild_batches_its_inserts_and_reads_only_naming_columns(db_path)
    print("Testing rebuild_names inserts in batches and selects only the columns it needs")
    for i = 1, 30 do
        new_batch(db_path, string.format("Batch run %d", i), string.format("EXP-%d", 3000 + i), "long notes nobody needs here")
    end
    original_exec = db.exec
    original_query = db.query
    inserts = 0
    selected = {}
    db.exec = function(path, statement, ...)
        if string.find(statement, "INSERT INTO entity_name_index", 1, true) != nil then
            inserts = inserts + 1
        end
        return original_exec(path, statement, ...)
    end
    db.query = function(path, query, ...)
        if string.find(query, "FROM `batch`", 1, true) != nil then
            table.insert(selected, query)
        end
        return original_query(path, query, ...)
    end
    count = reference.rebuild_names(db_path)
    db.exec = original_exec
    db.query = original_query
    check(count >= 60, "every label and lab number indexed, got " .. tostring(count))
    check(inserts <= #schema.list(db_path), "one insert per type here, got " .. tostring(inserts))
    check(#selected == 1 and contains(selected[1], "`lab_number`") and contains(selected[1], "`notes`") == false,
        "only id, name, display and identifier columns, got: " .. tostring(selected[1]))
end

function tests.the_flag_is_validated(db_path)
    print("Testing schema.validate on the identifier flag")
    err = schema.validate({name = "bad", fields = {{name = "code", type = "text", identifier = "yes"}}})
    check(contains(err, "'identifier' must be true or false"), "got: " .. tostring(err))
    err = schema.validate({name = "bad", fields = {{name = "owner", type = "reference", entity_type = "batch", identifier = true}}})
    check(contains(err, "can't be an identifier"), "got: " .. tostring(err))
    check(schema.validate({name = "good", fields = {{name = "code", type = "text", identifier = true}}}) == nil, "a text field can be one")
    check(schema.validate({name = "good", fields = {{name = "code", type = "select", values = {"A1", "B2"}, identifier = true}}}) == nil,
        "a select field can be one")
    for _, field_type in ipairs({"number", "date", "sql_select"}) do
        err = schema.validate({name = "bad", fields = {{name = "code", type = field_type, identifier = true}}})
        check(contains(err, "can't be an identifier"), field_type .. " is refused, got: " .. tostring(err))
    end
end

dir = os.tmpname()
os.remove(dir)
lfs.mkdir(dir)
init.do_init({}, dir)
db_path = dir .. "/.store/store.db"
schema.register(db_path, BATCH)
schema.register(db_path, MEDIUM)
schema.register(db_path, GEAR)

unit.run(tests, db_path)
os.execute("rm -rf '" .. dir .. "'")
