-- tst/unit/entity_find.lua
-- entity.find turns a name as the user writes it into the entity it refers
-- to (#38): exact on the label and identifier fields, ignoring case, spacing
-- and separators, every match listed, nothing partial or ranked. The
-- `identifier` flag is what puts a field like lab_number in reach, in the
-- name index as well as in the slower compare for names the index skips.

agent_tools = require("agent_tools")
reference = require("reference")
document = require("document")
entity = require("entity")
schema = require("schema")
db = require("database")
init = require("init")
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

function tests.a_name_not_indexed_yet_is_still_found(db_path)
    print("Testing the fallback finds a field marked identifier before repair runs")
    id = new_batch(db_path, "Before repair", "EXP-950")
    db.exec(db_path, string.format("DELETE FROM entity_name_index WHERE entity_type = 'batch' AND entity_id = %d;", id))
    result = find(db_path, {text = "exp 950"})
    check(contains(result, "batch " .. id .. " \"Before repair\" (lab_number EXP-950)"), "got: " .. tostring(result))
end

function tests.the_flag_is_validated(db_path)
    print("Testing schema.validate on the identifier flag")
    err = schema.validate({name = "bad", fields = {{name = "code", type = "text", identifier = "yes"}}})
    check(contains(err, "'identifier' must be true or false"), "got: " .. tostring(err))
    err = schema.validate({name = "bad", fields = {{name = "owner", type = "reference", entity_type = "batch", identifier = true}}})
    check(contains(err, "can't be an identifier"), "got: " .. tostring(err))
    check(schema.validate({name = "good", fields = {{name = "code", type = "text", identifier = true}}}) == nil, "a text field can be one")
end

dir = os.tmpname()
os.remove(dir)
lfs.mkdir(dir)
init.do_init({}, dir)
db_path = dir .. "/.store/store.db"
schema.register(db_path, BATCH)
schema.register(db_path, MEDIUM)

unit.run(tests, db_path)
os.execute("rm -rf '" .. dir .. "'")
