-- tst/unit/document_link.lua
-- Unit tests for src/knowledge.lua's reinforce_link_strength (see
-- doc/link-strength-redesign.md, Phase 2): the usage-driven edge
-- reinforcement that will eventually weight spread_activation, once
-- Phase 3 of that doc cuts the read side over. Also covers
-- src/document.lua's source_set_add/source_set_remove/upsert_link and
-- the archive-not-delete sync_links behavior they support
-- (doc/document-link-flow.md's "Archiving and reintroduction").
--
-- Same reasoning as tst/unit/document_pool.lua for touching a real
-- (temporary) SQLite file with a minimal, hand-rolled document_link
-- table rather than the full entity/schema/ledger machinery -- what's
-- being tested is a DB-state property (does a real UPDATE land
-- correctly, in both directions, under a simulated race), not a pure
-- function of its own inputs.

knowledge = require("knowledge")
document = require("document")
db = require("database")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function close_enough(a, b, tolerance)
    if tolerance == nil then
        tolerance = 0.0000001
    end
    return math.abs(a - b) < tolerance
end

-- NOT a general-purpose blank/empty check -- scoped specifically to a
-- column value just read back via db.query, where a SQL NULL renders
-- as Lua "" here, never nil (confirmed: both TEXT and INTEGER NULL
-- columns come back this way; same reason every SQL read of
-- archived_at in src/document.lua checks "IS NULL OR = ''" rather than
-- a bare "IS NULL"). Do not reach for this on a value where "" is a
-- real, intentional distinct-from-NULL result -- e.g. document_link's
-- own `source` after document.source_set_remove, where "" specifically
-- means "no tags left" and is compared with a plain `== ""` below, not
-- this helper.
function is_sql_null(value)
    return value == nil or value == ""
end

-- Just the columns reinforce_link_strength/sync_links/upsert_link
-- actually touch -- no entity/schema/ledger setup, same reasoning as
-- document_pool.lua's own new_test_db.
function new_test_db()
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE document_link (from_document_id INTEGER NOT NULL, to_document_id INTEGER, link_text VARCHAR(255) NOT NULL, source VARCHAR(32) NOT NULL DEFAULT 'authored', raw_strength REAL NOT NULL DEFAULT 1.0, archived_at TEXT DEFAULT NULL, note TEXT DEFAULT NULL, note_source VARCHAR(32) DEFAULT NULL, created_at TEXT DEFAULT NULL, PRIMARY KEY (from_document_id, link_text));")
    -- Minimal document table -- only sync_links' own resolve_link
    -- reads this, to turn a [[title]] into a real to_document_id.
    db.exec(db_path, "CREATE TABLE document (id INTEGER PRIMARY KEY, title TEXT, parent_id INTEGER, archived_at TEXT DEFAULT NULL);")
    return db_path
end

function link_strength(db_path, from_id, to_id)
    rows = db.query(db_path, string.format(
        "SELECT raw_strength FROM document_link WHERE from_document_id = %d AND to_document_id = %d;", from_id, to_id
    ))
    return tonumber(rows[1].raw_strength)
end

function link_row(db_path, from_id, link_text)
    rows = db.query(db_path, string.format(
        "SELECT source, archived_at, to_document_id, raw_strength FROM document_link WHERE from_document_id = %d AND link_text = %s;",
        from_id, db.quote(link_text)
    ))
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1]
end

function link_note(db_path, from_id, link_text)
    rows = db.query(db_path, string.format(
        "SELECT note, note_source, created_at FROM document_link WHERE from_document_id = %d AND link_text = %s;",
        from_id, db.quote(link_text)
    ))
    return rows[1]
end

function test_link_context_quotes_the_sentence_around_the_link()
    print("Testing link_context returns just the sentence containing the link, links flattened")
    content = "# Protocol\n\nThaw the vial first. Subculture onto [[MS Medium]] every 14 days, per [[SOP 12]]. Record the date.\n"
    note = document.link_context(content, "MS Medium")
    check(note == "Subculture onto MS Medium every 14 days, per SOP 12.", "got " .. tostring(note))
end

function test_link_context_strips_list_markup_and_keeps_dotted_tokens_together()
    print("Testing link_context strips a bullet and doesn't split on 'v1.2'")
    note = document.link_context("- Uses [[Buffer v1.2]] from the v1.2 batch, not v1.1\n", "Buffer v1.2")
    check(note == "Uses Buffer v1.2 from the v1.2 batch, not v1.1", "got " .. tostring(note))
end

function test_link_context_falls_back_to_the_nearest_heading_for_a_bare_link()
    print("Testing link_context falls back to the heading above a bare list entry")
    content = "# Notes\n\n## Related meetings\n\n- [[Weekly Kickoff 2025-02-23]]\n- [[R&D Meeting 2025-05-08]]\n"
    note = document.link_context(content, "R&D Meeting 2025-05-08")
    check(note == "Listed under \"Related meetings\"", "got " .. tostring(note))
end

function test_link_context_is_nil_for_a_bare_link_with_no_heading()
    print("Testing link_context returns nil when neither a sentence nor a heading says anything")
    check(document.link_context("[[Only A Link]]", "Only A Link") == nil, "expected nil")
    check(document.link_context("no link here", "Missing") == nil, "expected nil for a link not in content")
end

function test_truncate_note_trims_blanks_and_never_splits_a_utf8_character()
    print("Testing truncate_note: blank -> nil, long -> capped at a UTF-8 boundary")
    check(document.truncate_note("   ") == nil, "blank should be nil")
    check(document.truncate_note("  hi  ") == "hi", "should trim")
    long = string.rep("a", document.LINK_NOTE_MAX_LENGTH - 1) .. "\xC3\xA9\xC3\xA9"
    cut = document.truncate_note(long)
    check(string.sub(cut, -3) == "...", "should end with ...")
    body = string.sub(cut, 1, #cut - 3)
    check(#body == document.LINK_NOTE_MAX_LENGTH - 1, "should back off before the split two-byte char, got length " .. tostring(#body))
end

function test_note_replaces_respects_priority()
    print("Testing note_replaces: human > context > model, equal rank replaces")
    check(document.note_replaces(nil, "model") == true, "empty accepts anything")
    check(document.note_replaces("model", "context") == true, "context replaces model")
    check(document.note_replaces("context", "context") == true, "equal rank refreshes")
    check(document.note_replaces("context", "model") == false, "model must not replace context")
    check(document.note_replaces("human", "context") == false, "nothing automatic replaces human")
end

function test_upsert_link_writes_note_and_created_at_on_insert()
    print("Testing upsert_link records note, note_source and created_at for a new link")
    db_path = new_test_db()
    document.upsert_link(db_path, 1, 2, "Doc Two", "co-retrieval", "B's medium is what A's protocol uses.", "model")
    row = link_note(db_path, 1, "Doc Two")
    check(row.note == "B's medium is what A's protocol uses.", "note: " .. tostring(row.note))
    check(row.note_source == "model", "note_source: " .. tostring(row.note_source))
    check(is_sql_null(row.created_at) == false, "created_at should be set")
    document.upsert_link(db_path, 1, 3, "Doc Three", "authored")
    row = link_note(db_path, 1, "Doc Three")
    check(is_sql_null(row.note) and is_sql_null(row.note_source), "no note given -> note and note_source stay NULL")
    os.remove(db_path)
end

function test_sync_links_keeps_a_human_note_across_saves()
    print("Testing a human note survives later saves, and a context note refreshes when the sentence changes")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two'), (3, 'Doc Three');")
    document.sync_links(db_path, 1, "First we use [[Doc Two]]. Then [[Doc Three]].")
    check(link_note(db_path, 1, "Doc Two").note == "First we use Doc Two.", "initial context note")
    check(link_note(db_path, 1, "Doc Two").note_source == "context", "context note_source")
    ok = document.set_link_note(db_path, 1, "Doc Two", "Doc Two is the upstream protocol.")
    check(ok == true, "set_link_note should succeed")
    document.sync_links(db_path, 1, "Now we rely on [[Doc Two]] heavily. Then [[Doc Three]] afterwards.")
    check(link_note(db_path, 1, "Doc Two").note == "Doc Two is the upstream protocol.", "human note must survive a save")
    check(link_note(db_path, 1, "Doc Three").note == "Then Doc Three afterwards.", "context note should refresh: " .. tostring(link_note(db_path, 1, "Doc Three").note))
    os.remove(db_path)
end

function test_context_note_replaces_an_earlier_model_note()
    print("Testing an author's context note replaces a model note on the same link row")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    document.upsert_link(db_path, 1, 2, "Doc Two", "co-retrieval", "Model guess.", "model")
    document.sync_links(db_path, 1, "Calibrated against [[Doc Two]].")
    row = link_note(db_path, 1, "Doc Two")
    check(row.note == "Calibrated against Doc Two.", "note: " .. tostring(row.note))
    check(row.note_source == "context", "note_source: " .. tostring(row.note_source))
    os.remove(db_path)
end

function test_set_link_note_clears_and_rejects_unknown_links()
    print("Testing set_link_note: blank clears to NULL, unknown link is an error")
    db_path = new_test_db()
    document.upsert_link(db_path, 1, 2, "Doc Two", "authored", "ctx", "context")
    document.set_link_note(db_path, 1, "Doc Two", "   ")
    row = link_note(db_path, 1, "Doc Two")
    check(is_sql_null(row.note) and is_sql_null(row.note_source), "blank should clear note and note_source")
    ok, err = document.set_link_note(db_path, 1, "Nope", "x")
    check(ok == nil and err == "no such link", "unknown link should error, got " .. tostring(err))
    os.remove(db_path)
end

function test_parse_link_judgment_is_lenient_about_format()
    print("Testing parse_link_judgment across the formats models actually return")
    v, r = knowledge.parse_link_judgment("YES: B's recipe is A's medium.")
    check(v == "YES" and r == "B's recipe is A's medium.", "plain: " .. tostring(v) .. " / " .. tostring(r))
    v, r = knowledge.parse_link_judgment("  **YES** - both calibrate probe 3\n")
    check(v == "YES" and r == "both calibrate probe 3", "bold+dash: " .. tostring(v) .. " / " .. tostring(r))
    v, r = knowledge.parse_link_judgment("no")
    check(v == "NO" and r == nil, "bare lowercase no: " .. tostring(v) .. " / " .. tostring(r))
    v, r = knowledge.parse_link_judgment("Maybe, hard to say")
    check(v == nil, "non-verdict should be nil")
    v, r = knowledge.parse_link_judgment("YESTERDAY's run")
    check(v == nil, "a word merely starting with YES is not a verdict")
end

function test_an_overlong_link_is_skipped_not_fatal()
    print("Testing a [[link]] longer than document_link can hold is skipped, and the rest of the save still syncs")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    broken = "[[" .. string.rep("x", 701) .. "]]"
    document.sync_links(db_path, 1, "Unclosed markup: " .. broken .. " and a real one: [[Doc Two]].")
    rows = db.query(db_path, "SELECT link_text FROM document_link;")
    check(#rows == 1 and rows[1].link_text == "Doc Two", "only the real link should be stored, got " .. tostring(#rows) .. " row(s)")
    os.remove(db_path)
end

function test_reinforce_adds_exactly_the_configured_delta()
    print("Testing reinforce_link_strength adds exactly 0.15")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source) VALUES (1, 2, 'Doc Two', 'co-retrieval');")
    knowledge.reinforce_link_strength(db_path, 1, 2)
    strength = link_strength(db_path, 1, 2)
    check(close_enough(strength, 1.0 + 0.15),
        "expected " .. tostring(1.0 + 0.15) .. ", got " .. tostring(strength))
    os.remove(db_path)
end

function test_reinforce_matches_the_row_regardless_of_which_direction_it_was_authored_in()
    print("Testing reinforce_link_strength finds an edge authored in either direction (task: link-strength-redesign Phase 2)")
    db_path = new_test_db()
    -- Row stored as (2 -> 1): e.g. document 2's own content contained
    -- the [[title]] link, or doc_a/doc_b happened to resolve opposite
    -- to co_retrieval_pairs' own doc_a < doc_b ordering. Reinforcing
    -- the pair as (1, 2) -- the order maybe_link_co_retrieved actually
    -- has on hand -- must still find and update this same row.
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source) VALUES (2, 1, 'Doc One', 'authored');")
    knowledge.reinforce_link_strength(db_path, 1, 2)
    strength = link_strength(db_path, 2, 1)
    check(close_enough(strength, 1.0 + 0.15),
        "reinforcing (1, 2) should have updated the (2, 1) row -- expected " .. tostring(1.0 + 0.15) .. ", got " .. tostring(strength))
    os.remove(db_path)
end

function test_racing_reinforcements_of_the_same_edge_never_lose_a_delta()
    print("Testing two racing reinforcements of the same edge: neither delta is silently lost")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source) VALUES (1, 2, 'Doc Two', 'co-retrieval');")

    -- Two "concurrent" reinforcements, applied as two ordinary
    -- sequential calls -- this is a plain additive UPDATE (raw_strength
    -- = raw_strength + delta), not a read-modify-write round trip in
    -- Lua, so unlike heat's own pool_scale history there's no lossy
    -- shape possible here to simulate a race against; this test exists
    -- to document and guard that property, not to demonstrate a fix
    -- for a bug this design could have had.
    knowledge.reinforce_link_strength(db_path, 1, 2)
    knowledge.reinforce_link_strength(db_path, 2, 1) -- same pair, opposite argument order
    strength = link_strength(db_path, 1, 2)
    check(close_enough(strength, 1.0 + (2 * 0.15)),
        "both reinforcements should land -- expected " .. tostring(1.0 + (2 * 0.15)) .. ", got " .. tostring(strength))
    os.remove(db_path)
end

function test_reinforce_is_a_no_op_for_a_pair_with_no_existing_link()
    print("Testing reinforce_link_strength doesn't error when no matching row exists")
    db_path = new_test_db()
    ok = pcall(knowledge.reinforce_link_strength, db_path, 1, 2)
    check(ok == true, "reinforcing a non-existent pair should be a safe no-op, not an error")
    os.remove(db_path)
end

function test_reinforce_unarchives_and_adds_the_co_retrieval_tag()
    print("Testing reinforce_link_strength unarchives an archived pair and folds in 'co-retrieval'")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source, archived_at) VALUES (1, 2, 'Doc Two', 'authored', '2026-01-01 00:00:00');")
    knowledge.reinforce_link_strength(db_path, 1, 2)
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at), "a repeat co-retrieval hit should unarchive the row")
    check(row.source == "authored,co-retrieval", "expected merged source 'authored,co-retrieval', got " .. tostring(row.source))
    os.remove(db_path)
end

function test_source_set_add_dedupes_and_sorts()
    print("Testing document.source_set_add dedupes and keeps the set sorted (task: document_link archiving)")
    check(document.source_set_add(nil, "authored") == "authored", "adding to an empty set should just be the tag")
    check(document.source_set_add("authored", "authored") == "authored", "adding an already-present tag should be a no-op")
    check(document.source_set_add("co-retrieval", "authored") == "authored,co-retrieval", "expected sorted 'authored,co-retrieval'")
end

function test_source_set_remove_can_empty_the_set()
    print("Testing document.source_set_remove")
    check(document.source_set_remove("authored,co-retrieval", "authored") == "co-retrieval", "expected only 'co-retrieval' left")
    check(document.source_set_remove("authored", "authored") == "", "removing the only tag should leave an empty set")
end

function test_upsert_link_inserts_a_fresh_row()
    print("Testing document.upsert_link inserts when nothing exists yet")
    db_path = new_test_db()
    document.upsert_link(db_path, 1, 2, "Doc Two", "authored")
    row = link_row(db_path, 1, "Doc Two")
    check(row != nil, "expected a fresh row to exist")
    check(row.source == "authored", "expected source 'authored', got " .. tostring(row.source))
    check(is_sql_null(row.archived_at), "a fresh row should not be archived")
    os.remove(db_path)
end

function test_upsert_link_reintroduces_an_archived_row_at_its_old_strength()
    print("Testing document.upsert_link unarchives and preserves raw_strength on reintroduction")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source, raw_strength, archived_at) VALUES (1, 2, 'Doc Two', '', 1.45, '2026-01-01 00:00:00');")
    document.upsert_link(db_path, 1, 2, "Doc Two", "authored")
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at), "reintroducing should unarchive")
    check(row.source == "authored", "expected source 'authored', got " .. tostring(row.source))
    check(close_enough(tonumber(row.raw_strength), 1.45), "raw_strength should survive reintroduction, not reset to 1.0 -- got " .. tostring(row.raw_strength))
    os.remove(db_path)
end

function test_upsert_link_heals_a_dangling_row()
    print("Testing document.upsert_link resolves a previously-dangling to_document_id")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source) VALUES (1, NULL, 'Onboarding', 'authored');")
    document.upsert_link(db_path, 1, 9, "Onboarding", "co-retrieval")
    row = link_row(db_path, 1, "Onboarding")
    check(tonumber(row.to_document_id) == 9, "expected the dangling row to heal to to_document_id=9, got " .. tostring(row.to_document_id))
    check(row.source == "authored,co-retrieval", "expected merged source, got " .. tostring(row.source))
    os.remove(db_path)
end

function test_sync_links_archives_instead_of_deleting_when_removed_from_text()
    print("Testing sync_links archives an authored link with no other provenance, instead of deleting it")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    document.sync_links(db_path, 1, "See [[Doc Two]].")
    row = link_row(db_path, 1, "Doc Two")
    check(row != nil, "link should exist after the first save")
    db.exec(db_path, string.format("UPDATE document_link SET raw_strength = 1.45 WHERE from_document_id = 1 AND link_text = %s;", db.quote("Doc Two")))

    document.sync_links(db_path, 1, "No links here anymore.")
    row = link_row(db_path, 1, "Doc Two")
    check(row != nil, "row should still exist (archived), not be deleted")
    check(is_sql_null(row.archived_at) == false, "row should be archived once its only source tag is gone")
    check(row.source == "", "source set should be empty once 'authored' is removed")
    check(close_enough(tonumber(row.raw_strength), 1.45), "raw_strength should survive archiving -- got " .. tostring(row.raw_strength))
    os.remove(db_path)
end

function test_sync_links_leaves_a_co_retrieval_backed_row_active_when_authored_text_is_removed()
    print("Testing sync_links only drops the 'authored' tag, leaving a co-retrieval-backed row active")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source) VALUES (1, 2, 'Doc Two', 'authored,co-retrieval');")

    document.sync_links(db_path, 1, "No links here anymore.")
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at), "a link retrieval still vouches for should stay active")
    check(row.source == "co-retrieval", "expected only 'co-retrieval' left, got " .. tostring(row.source))
    os.remove(db_path)
end

function test_sync_links_reintroduces_an_archived_link_at_its_old_strength()
    print("Testing sync_links unarchives and preserves raw_strength when the author retypes a deleted [[link]]")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source, raw_strength, archived_at) VALUES (1, 2, 'Doc Two', '', 1.45, '2026-01-01 00:00:00');")

    document.sync_links(db_path, 1, "See [[Doc Two]] again.")
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at), "retyping the link should unarchive it")
    check(row.source == "authored", "expected source 'authored', got " .. tostring(row.source))
    check(close_enough(tonumber(row.raw_strength), 1.45), "raw_strength should survive reintroduction -- got " .. tostring(row.raw_strength))
    os.remove(db_path)
end

test_reinforce_adds_exactly_the_configured_delta()
test_reinforce_matches_the_row_regardless_of_which_direction_it_was_authored_in()
test_racing_reinforcements_of_the_same_edge_never_lose_a_delta()
test_reinforce_is_a_no_op_for_a_pair_with_no_existing_link()
test_reinforce_unarchives_and_adds_the_co_retrieval_tag()
test_source_set_add_dedupes_and_sorts()
test_source_set_remove_can_empty_the_set()
test_upsert_link_inserts_a_fresh_row()
test_upsert_link_reintroduces_an_archived_row_at_its_old_strength()
test_upsert_link_heals_a_dangling_row()
test_sync_links_archives_instead_of_deleting_when_removed_from_text()
test_sync_links_leaves_a_co_retrieval_backed_row_active_when_authored_text_is_removed()
test_sync_links_reintroduces_an_archived_link_at_its_old_strength()
test_link_context_quotes_the_sentence_around_the_link()
test_link_context_strips_list_markup_and_keeps_dotted_tokens_together()
test_link_context_falls_back_to_the_nearest_heading_for_a_bare_link()
test_link_context_is_nil_for_a_bare_link_with_no_heading()
test_truncate_note_trims_blanks_and_never_splits_a_utf8_character()
test_note_replaces_respects_priority()
test_upsert_link_writes_note_and_created_at_on_insert()
test_sync_links_keeps_a_human_note_across_saves()
test_context_note_replaces_an_earlier_model_note()
test_set_link_note_clears_and_rejects_unknown_links()
test_parse_link_judgment_is_lenient_about_format()
test_an_overlong_link_is_skipped_not_fatal()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All document_link.lua tests passed")
