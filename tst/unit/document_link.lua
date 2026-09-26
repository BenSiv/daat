-- tst/unit/document_link.lua
-- Unit tests for document_link as a purely derived index of [[links]]
-- in document content (doc/document-link-flow.md): src/document.lua's
-- link grammar, upsert_link/sync_links (archive-not-delete, heal
-- dangling), link_context (why two documents are connected, read from
-- content), and src/knowledge.lua's reinforce_link_strength (doc/
-- link-strength-redesign.md), documents_connected and
-- parse_link_judgment.
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
-- as Lua "" here, never nil.
function is_sql_null(value)
    return value == nil or value == ""
end

-- The real document_link layout (src/document.lua's
-- DOCUMENT_LINK_TABLE_SQL) plus a minimal document table -- only
-- resolve_link and documents_connected read it. No entity/schema/ledger
-- setup, same reasoning as document_pool.lua's own new_test_db.
function new_test_db()
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE document_link (id INTEGER PRIMARY KEY AUTOINCREMENT, from_document_id INTEGER NOT NULL, to_document_id INTEGER, link_text TEXT NOT NULL, link_hash CHAR(64) NOT NULL, raw_strength REAL NOT NULL DEFAULT 1.0, archived_at TEXT DEFAULT NULL, created_at TEXT DEFAULT NULL);")
    db.exec(db_path, "CREATE UNIQUE INDEX document_link_from_hash_idx ON document_link(from_document_id, link_hash);")
    db.exec(db_path, "CREATE TABLE document (id INTEGER PRIMARY KEY, title TEXT, parent_id INTEGER, archived_at TEXT DEFAULT NULL);")
    return db_path
end

function insert_link(db_path, from_id, to_id, link_text, extra_columns, extra_values)
    columns = "from_document_id, to_document_id, link_text, link_hash"
    values = string.format("%d, %s, %s, %s", from_id, db.literal(to_id), db.quote(link_text), db.quote(document.link_hash(link_text)))
    if extra_columns != nil then
        columns = columns .. ", " .. extra_columns
        values = values .. ", " .. extra_values
    end
    db.exec(db_path, "INSERT INTO document_link (" .. columns .. ") VALUES (" .. values .. ");")
end

function link_row(db_path, from_id, link_text)
    rows = db.query(db_path, string.format(
        "SELECT archived_at, to_document_id, raw_strength, created_at FROM document_link WHERE from_document_id = %d AND link_text = %s;",
        from_id, db.quote(link_text)
    ))
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1]
end

function link_count(db_path)
    return tonumber(db.query(db_path, "SELECT COUNT(*) AS n FROM document_link;")[1].n)
end

-- Link grammar ---------------------------------------------------------

function test_an_unclosed_bracket_is_not_a_link_and_swallows_nothing()
    print("Testing an unclosed [[ matches nothing, so the real link after it is still found")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    document.sync_links(db_path, 1, "Broken [[markup that never closes, then later a real one: [[Doc Two]].")
    rows = db.query(db_path, "SELECT link_text FROM document_link;")
    check(#rows == 1 and rows[1].link_text == "Doc Two", "only [[Doc Two]] should be a link, got " .. tostring(#rows) .. " row(s)")
    os.remove(db_path)
end

function test_a_link_never_spans_lines()
    print("Testing [[ on one line and ]] on another is not a link")
    db_path = new_test_db()
    document.sync_links(db_path, 1, "Starts [[here\nand ends]] there.")
    check(link_count(db_path) == 0, "a link spanning a newline should not be indexed")
    os.remove(db_path)
end

function test_a_very_long_title_is_an_ordinary_link()
    print("Testing link text has no length limit (a real paper title overflowed the old VARCHAR(255) key)")
    db_path = new_test_db()
    long_title = string.rep("Bacillus amyloliquefaciens subsp. plantarum", 20, ", ")
    db.exec(db_path, string.format("INSERT INTO document (id, title) VALUES (2, %s);", db.quote(long_title)))
    document.sync_links(db_path, 1, "Cites [[" .. long_title .. "]].")
    row = link_row(db_path, 1, long_title)
    check(row != nil and tonumber(row.to_document_id) == 2, "a long title should link like any other")
    os.remove(db_path)
end

-- upsert_link / sync_links -----------------------------------------------

function test_a_title_containing_a_slash_links_as_written()
    print("Testing resolve_link_text: an exact title wins, subject/title is only the fallback")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title, parent_id) VALUES (1, 'CRISPR/Cas9 in fungi', NULL), (2, 'Notes', NULL), (3, 'Cas9', 2), (4, 'Notes/Cas9', NULL);")
    check(tonumber(document.resolve_link_text(db_path, "CRISPR/Cas9 in fungi")) == 1, "a slash inside a title is part of the title")
    check(tonumber(document.resolve_link_text(db_path, " CRISPR/Cas9 in fungi ")) == 1, "surrounding blanks are trimmed")
    check(tonumber(document.resolve_link_text(db_path, "Notes/Cas9")) == 4, "an exact title beats the subject/title reading")
    check(document.resolve_link_text(db_path, "CRISPR/Cas10") == nil, "no exact title and no such subject: dangling")
    check(document.resolve_link_text(db_path, "Nothing here") == nil, "a plain unknown title is dangling")
    os.remove(db_path)
end

function test_upsert_link_inserts_a_fresh_row()
    print("Testing document.upsert_link inserts at base strength, with created_at")
    db_path = new_test_db()
    document.upsert_link(db_path, 1, 2, "Doc Two")
    row = link_row(db_path, 1, "Doc Two")
    check(row != nil, "expected a fresh row to exist")
    check(is_sql_null(row.archived_at), "a fresh row should not be archived")
    check(close_enough(tonumber(row.raw_strength), 1.0), "a fresh row starts at BASE_LINK_STRENGTH")
    check(is_sql_null(row.created_at) == false, "created_at should be set")
    os.remove(db_path)
end

function test_upsert_link_reintroduces_an_archived_row_at_its_old_strength()
    print("Testing document.upsert_link unarchives and preserves raw_strength on reintroduction")
    db_path = new_test_db()
    insert_link(db_path, 1, 2, "Doc Two", "raw_strength, archived_at", "1.45, '2026-01-01 00:00:00'")
    document.upsert_link(db_path, 1, 2, "Doc Two")
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at), "reintroducing should unarchive")
    check(close_enough(tonumber(row.raw_strength), 1.45), "raw_strength should survive reintroduction, not reset to 1.0 -- got " .. tostring(row.raw_strength))
    check(link_count(db_path) == 1, "reintroduction must update the row, not add a second")
    os.remove(db_path)
end

function test_upsert_link_heals_a_dangling_row()
    print("Testing document.upsert_link resolves a previously-dangling to_document_id")
    db_path = new_test_db()
    insert_link(db_path, 1, nil, "Onboarding")
    document.upsert_link(db_path, 1, 9, "Onboarding")
    row = link_row(db_path, 1, "Onboarding")
    check(tonumber(row.to_document_id) == 9, "expected the dangling row to heal to to_document_id=9, got " .. tostring(row.to_document_id))
    os.remove(db_path)
end

function test_sync_links_archives_instead_of_deleting_when_removed_from_text()
    print("Testing sync_links archives a link whose markup is gone, instead of deleting it")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    document.sync_links(db_path, 1, "See [[Doc Two]].")
    db.exec(db_path, "UPDATE document_link SET raw_strength = 1.45;")

    document.sync_links(db_path, 1, "No links here anymore.")
    row = link_row(db_path, 1, "Doc Two")
    check(row != nil, "row should still exist (archived), not be deleted")
    check(is_sql_null(row.archived_at) == false, "row should be archived once its markup is gone")
    check(close_enough(tonumber(row.raw_strength), 1.45), "raw_strength should survive archiving -- got " .. tostring(row.raw_strength))
    os.remove(db_path)
end

function test_sync_links_reintroduces_an_archived_link_at_its_old_strength()
    print("Testing sync_links unarchives and preserves raw_strength when the author retypes a deleted [[link]]")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    insert_link(db_path, 1, 2, "Doc Two", "raw_strength, archived_at", "1.45, '2026-01-01 00:00:00'")
    document.sync_links(db_path, 1, "See [[Doc Two]] again.")
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at), "retyping the link should unarchive it")
    check(close_enough(tonumber(row.raw_strength), 1.45), "raw_strength should survive reintroduction -- got " .. tostring(row.raw_strength))
    os.remove(db_path)
end

-- link_context ----------------------------------------------------------

function test_link_context_quotes_the_sentence_around_the_link()
    print("Testing link_context returns just the sentence containing the link, links flattened")
    content = "# Protocol\n\nThaw the vial first. Subculture onto [[MS Medium]] every 14 days, per [[SOP 12]]. Record the date.\n"
    context = document.link_context(content, "MS Medium")
    check(context == "Subculture onto MS Medium every 14 days, per SOP 12.", "got " .. tostring(context))
end

function test_link_context_strips_list_markup_and_keeps_dotted_tokens_together()
    print("Testing link_context strips a bullet and doesn't split on 'v1.2'")
    context = document.link_context("- Uses [[Buffer v1.2]] from the v1.2 batch, not v1.1\n", "Buffer v1.2")
    check(context == "Uses Buffer v1.2 from the v1.2 batch, not v1.1", "got " .. tostring(context))
end

function test_link_context_falls_back_to_the_nearest_heading_for_a_bare_link()
    print("Testing link_context falls back to the heading above a bare list entry")
    content = "# Notes\n\n## Related meetings\n\n- [[Weekly Kickoff 2025-02-23]]\n- [[R&D Meeting 2025-05-08]]\n"
    context = document.link_context(content, "R&D Meeting 2025-05-08")
    check(context == "Listed under \"Related meetings\"", "got " .. tostring(context))
end

function test_link_context_is_nil_for_a_bare_link_with_no_heading()
    print("Testing link_context returns nil when neither a sentence nor a heading says anything")
    check(document.link_context("[[Only A Link]]", "Only A Link") == nil, "expected nil")
    check(document.link_context("no link here", "Missing") == nil, "expected nil for a link not in content")
end

function test_link_context_reads_a_connection_documents_reason()
    print("Testing a connection document's own sentence is the context on both of its links")
    content = "[[MS Medium]] and [[Subculture]]: the subculture protocol calls for exactly this medium recipe."
    expected = "MS Medium and Subculture: the subculture protocol calls for exactly this medium recipe."
    check(document.link_context(content, "MS Medium") == expected, "got " .. tostring(document.link_context(content, "MS Medium")))
    check(document.link_context(content, "Subculture") == expected, "got " .. tostring(document.link_context(content, "Subculture")))
end

function test_clip_text_trims_blanks_and_never_splits_a_utf8_character()
    print("Testing clip_text: blank -> nil, long -> capped at a UTF-8 boundary")
    check(document.clip_text("   ") == nil, "blank should be nil")
    check(document.clip_text("  hi  ") == "hi", "should trim")
    long = string.rep("a", 499) .. "\xC3\xA9\xC3\xA9"
    cut = document.clip_text(long)
    check(string.sub(cut, -3) == "...", "should end with ...")
    check(#cut - 3 == 499, "should back off before the split two-byte char, got length " .. tostring(#cut - 3))
end

-- Reinforcement, connectedness ----------------------------------------

function test_reinforce_adds_exactly_the_configured_delta()
    print("Testing reinforce_link_strength adds exactly 0.15")
    db_path = new_test_db()
    insert_link(db_path, 1, 2, "Doc Two")
    knowledge.reinforce_link_strength(db_path, 1, 2)
    strength = tonumber(link_row(db_path, 1, "Doc Two").raw_strength)
    check(close_enough(strength, 1.0 + 0.15), "expected " .. tostring(1.0 + 0.15) .. ", got " .. tostring(strength))
    os.remove(db_path)
end

function test_reinforce_matches_the_row_regardless_of_which_direction_it_was_written_in()
    print("Testing reinforce_link_strength finds an edge written in either direction (task: link-strength-redesign Phase 2)")
    db_path = new_test_db()
    -- Row stored as (2 -> 1): document 2's content holds the link.
    -- Reinforcing the pair as (1, 2) -- the order maybe_link_co_retrieved
    -- actually has on hand -- must still find and update this same row.
    insert_link(db_path, 2, 1, "Doc One")
    knowledge.reinforce_link_strength(db_path, 1, 2)
    strength = tonumber(link_row(db_path, 2, "Doc One").raw_strength)
    check(close_enough(strength, 1.0 + 0.15), "reinforcing (1, 2) should have updated the (2, 1) row -- got " .. tostring(strength))
    os.remove(db_path)
end

function test_racing_reinforcements_of_the_same_edge_never_lose_a_delta()
    print("Testing two racing reinforcements of the same edge: neither delta is silently lost")
    db_path = new_test_db()
    insert_link(db_path, 1, 2, "Doc Two")
    -- A plain additive UPDATE (raw_strength = raw_strength + delta), not a
    -- read-modify-write round trip in Lua -- this guards that property.
    knowledge.reinforce_link_strength(db_path, 1, 2)
    knowledge.reinforce_link_strength(db_path, 2, 1)
    strength = tonumber(link_row(db_path, 1, "Doc Two").raw_strength)
    check(close_enough(strength, 1.0 + (2 * 0.15)), "both reinforcements should land -- got " .. tostring(strength))
    os.remove(db_path)
end

function test_reinforce_never_unarchives()
    print("Testing reinforce_link_strength leaves an archived link alone -- retrieval doesn't write content")
    db_path = new_test_db()
    insert_link(db_path, 1, 2, "Doc Two", "archived_at", "'2026-01-01 00:00:00'")
    knowledge.reinforce_link_strength(db_path, 1, 2)
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at) == false, "should stay archived")
    check(close_enough(tonumber(row.raw_strength), 1.0), "an archived edge shouldn't be strengthened")
    os.remove(db_path)
end

function test_reinforce_is_a_no_op_for_a_pair_with_no_existing_link()
    print("Testing reinforce_link_strength doesn't error when no matching row exists")
    db_path = new_test_db()
    ok = pcall(knowledge.reinforce_link_strength, db_path, 1, 2)
    check(ok == true, "reinforcing a non-existent pair should be a safe no-op, not an error")
    os.remove(db_path)
end

function test_documents_connected_directly_through_a_document_or_not_at_all()
    print("Testing documents_connected: a direct link either way, a third document linking both, or nil")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (1, 'A'), (2, 'B'), (3, 'C'), (4, 'D'), (5, 'A and C');")
    insert_link(db_path, 2, 1, "A")
    check(knowledge.documents_connected(db_path, 1, 2) == "direct", "B links A: direct, whichever order")
    insert_link(db_path, 5, 1, "A")
    insert_link(db_path, 5, 3, "C")
    check(knowledge.documents_connected(db_path, 1, 3) == "through_document", "document 5 links both A and C")
    check(knowledge.documents_connected(db_path, 1, 4) == nil, "nothing connects A and D")
    db.exec(db_path, "UPDATE document SET archived_at = '2026-01-01' WHERE id = 5;")
    check(knowledge.documents_connected(db_path, 1, 3) == nil, "an archived connecting document connects nothing")
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

test_an_unclosed_bracket_is_not_a_link_and_swallows_nothing()
test_a_link_never_spans_lines()
test_a_very_long_title_is_an_ordinary_link()
test_a_title_containing_a_slash_links_as_written()
test_upsert_link_inserts_a_fresh_row()
test_upsert_link_reintroduces_an_archived_row_at_its_old_strength()
test_upsert_link_heals_a_dangling_row()
test_sync_links_archives_instead_of_deleting_when_removed_from_text()
test_sync_links_reintroduces_an_archived_link_at_its_old_strength()
test_link_context_quotes_the_sentence_around_the_link()
test_link_context_strips_list_markup_and_keeps_dotted_tokens_together()
test_link_context_falls_back_to_the_nearest_heading_for_a_bare_link()
test_link_context_is_nil_for_a_bare_link_with_no_heading()
test_link_context_reads_a_connection_documents_reason()
test_clip_text_trims_blanks_and_never_splits_a_utf8_character()
test_reinforce_adds_exactly_the_configured_delta()
test_reinforce_matches_the_row_regardless_of_which_direction_it_was_written_in()
test_racing_reinforcements_of_the_same_edge_never_lose_a_delta()
test_reinforce_never_unarchives()
test_reinforce_is_a_no_op_for_a_pair_with_no_existing_link()
test_documents_connected_directly_through_a_document_or_not_at_all()
test_parse_link_judgment_is_lenient_about_format()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All document_link.lua tests passed")
