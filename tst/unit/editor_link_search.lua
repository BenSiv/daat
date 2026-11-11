-- tst/unit/editor_link_search.lua
-- Unit coverage for the two searches behind /document-edit's inline link
-- picker:
--   1. document.search_for_link (`[[` trigger -> [[title]] / [[folder/title]])
--   2. entity.search_across_types (`@` trigger and /data search, including
--      fields marked identifier = 1 on both titled and display-less types)

init = require("init")
document = require("document")
entity = require("entity")
schema = require("schema")
db = require("database")
lfs = require("lfs")

unit = require("unit")
check = unit.check
tests = unit.suite()

function fresh_db()
    dir = os.tmpname()
    os.remove(dir)
    lfs.mkdir(dir)
    init.do_init({}, dir)
    db_path = dir .. "/.store/store.db"
    document.init_schema(db_path)
    return dir, db_path
end

function ensure_identifier_column(db_path)
    cols = {}
    for _, name in ipairs(db.get_columns(db_path, "entity_field")) do
        cols[name] = true
    end
    if cols["identifier"] == nil then
        db.exec(db_path, "ALTER TABLE entity_field ADD COLUMN identifier INTEGER DEFAULT 0;")
    end
end

function tests.document_search_disambiguates_and_skips_unlinkable()
    print("Testing document.search_for_link returns canonical [[ref]], excludes self/archived, and skips unlinkable duplicates")
    dir, db_path = fresh_db()

    home_id, _ = document.create_page(db_path, "tester", "Home", nil, "Welcome")
    guides_id, _ = document.create_page(db_path, "tester", "Guides", nil, "Folder")
    setup_root_id, _ = document.create_page(db_path, "tester", "Setup", nil, "Top-level setup")
    setup_guides_id, _ = document.create_page(db_path, "tester", "Setup", guides_id, "Guides setup")
    same_folder_dup_id, _ = document.create_page(db_path, "tester", "Setup", guides_id, "Second setup under Guides")
    bracket_id, _ = document.create_page(db_path, "tester", "Draft [WIP]", nil, "Unlinkable title")
    archived_id, _ = document.create_page(db_path, "tester", "Setup Old", nil, "Retired")
    entity.archive(db_path, "document", archived_id, "tester")

    -- Empty query lists linkable active documents, omitting `exclude_id`,
    -- archived rows, bracketed titles, and the unreachable same-folder duplicate.
    initial = document.search_for_link(db_path, "", 20, home_id)
    by_id = {}
    for _, item in ipairs(initial) do
        by_id[tonumber(item.id)] = item
    end
    check(by_id[tonumber(home_id)] == nil, "exclude_id omitted from dropdown")
    check(by_id[tonumber(archived_id)] == nil, "archived document omitted")
    check(by_id[tonumber(bracket_id)] == nil, "title with brackets omitted")
    check(by_id[tonumber(same_folder_dup_id)] == nil, "unreachable same-folder duplicate omitted")
    check(by_id[tonumber(setup_root_id)] != nil and by_id[tonumber(setup_root_id)].link_ref == "[[Setup]]",
        "root Setup uses [[Setup]]")
    check(by_id[tonumber(setup_guides_id)] != nil and by_id[tonumber(setup_guides_id)].link_ref == "[[Guides/Setup]]"
        and by_id[tonumber(setup_guides_id)].parent_title == "Guides",
        "child Setup disambiguates as [[Guides/Setup]] with parent_title Guides")

    -- Folder-qualified query ("Guides/Set") ranks the child under Guides.
    scoped = document.search_for_link(db_path, "Guides/Set", 20, nil)
    check(#scoped == 1 and tonumber(scoped[1].id) == tonumber(setup_guides_id) and scoped[1].link_ref == "[[Guides/Setup]]",
        "Guides/Set matches [[Guides/Setup]]")

    os.execute("rm -rf '" .. dir .. "'")
end

function tests.document_search_ranks_prefix_above_subsequence()
    print("Testing document.search_for_link ranks prefix and substring matches ahead of scattered subsequences")
    dir, db_path = fresh_db()

    document.create_page(db_path, "tester", "Characterisation of strain A", nil, "")
    chat_id, _ = document.create_page(db_path, "tester", "Chat: fermentation notes", nil, "")
    exp_id, _ = document.create_page(db_path, "tester", "Experiment 277", nil, "")

    chat_hits = document.search_for_link(db_path, "Chat:", 20, nil)
    check(#chat_hits >= 1 and tonumber(chat_hits[1].id) == tonumber(chat_id),
        "prefix match 'Chat:' ranks ahead of scattered letters")

    fuzzy_hits = document.search_for_link(db_path, "exp277", 20, nil)
    check(#fuzzy_hits == 1 and tonumber(fuzzy_hits[1].id) == tonumber(exp_id) and fuzzy_hits[1].link_ref == "[[Experiment 277]]",
        "ordered subsequence 'exp277' finds Experiment 277")

    os.execute("rm -rf '" .. dir .. "'")
end

function tests.entity_search_matches_identifier_fields()
    print("Testing entity.search_across_types matches identifier = 1 fields on both titled and display-less schemas")
    dir, db_path = fresh_db()

    experiment_def = {
        name = "experiment",
        fields = {
            {name = "lab_number", type = "text", required = true},
            {name = "title", type = "text", required = true, display = true},
        },
    }
    equipment_def = {
        name = "equipment",
        fields = {
            {name = "number", type = "number", required = true},
            {name = "asset_code", type = "text", required = true},
        },
    }
    schema.register(db_path, experiment_def)
    schema.sync_table(db_path, experiment_def)
    schema.register(db_path, equipment_def)
    schema.sync_table(db_path, equipment_def)

    ensure_identifier_column(db_path)
    db.exec(db_path, "UPDATE entity_field SET identifier = 1 WHERE (entity_type = 'experiment' AND name = 'lab_number') OR (entity_type = 'equipment' AND name = 'asset_code');")

    exp_id, _ = entity.create(db_path, "experiment", {lab_number = "EXP-027", title = "Growth of S. demo on Molasses medium"}, "tester")
    eq_local_id, _ = entity.create(db_path, "equipment", {number = 41, asset_code = "EQ-041"}, "tester")
    eq_imported_id, _ = entity.create(db_path, "equipment", {name = "Biolector XT #1", number = 12, asset_code = "EQ-012"}, "tester")
    eq_archived_id, _ = entity.create(db_path, "equipment", {number = 99, asset_code = "EQ-099"}, "tester")
    entity.archive(db_path, "equipment", eq_archived_id, "tester")

    -- Querying by identifier on a titled schema puts the identifier as `label`
    -- (so @EXP-027 inserts [EXP-027](...)) and keeps the title as `subtitle`.
    by_code = entity.search_across_types(db_path, "EXP-027", 5, 20)
    check(#by_code == 1 and tonumber(by_code[1].id) == tonumber(exp_id)
        and by_code[1].label == "EXP-027"
        and by_code[1].subtitle == "Growth of S. demo on Molasses medium",
        "EXP-027 returns code as label and title as subtitle")

    -- Querying by title keeps the title as `label` and attaches the identifier as `subtitle`.
    by_title = entity.search_across_types(db_path, "Molasses", 5, 20)
    check(#by_title == 1 and tonumber(by_title[1].id) == tonumber(exp_id)
        and by_title[1].label == "Growth of S. demo on Molasses medium"
        and by_title[1].subtitle == "EXP-027",
        "Molasses returns title as label and EXP-027 as subtitle")

    -- Display-less locally created row (no `name`, no `display` field) resolves via `asset_code`.
    by_asset = entity.search_across_types(db_path, "EQ-041", 5, 20)
    check(#by_asset == 1 and tonumber(by_asset[1].id) == tonumber(eq_local_id)
        and by_asset[1].label == "EQ-041" and by_asset[1].subtitle == nil,
        "display-less row EQ-041 resolves via identifier field")

    -- Imported display-less row (builtin `name` set) matches by asset_code and keeps `name` as subtitle.
    by_imp_code = entity.search_across_types(db_path, "EQ-012", 5, 20)
    check(#by_imp_code == 1 and tonumber(by_imp_code[1].id) == tonumber(eq_imported_id)
        and by_imp_code[1].label == "EQ-012" and by_imp_code[1].subtitle == "Biolector XT #1",
        "imported row EQ-012 shows code + builtin name subtitle")

    -- Archived rows stay excluded.
    archived_hits = entity.search_across_types(db_path, "EQ-099", 5, 20)
    check(#archived_hits == 0, "archived row excluded from entity search")

    os.execute("rm -rf '" .. dir .. "'")
end

unit.run(tests)
