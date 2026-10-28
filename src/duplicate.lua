-- Duplicate papers: the same file synced from SharePoint into several
-- folders arrives as several documents, one per SharePoint item, each
-- with its own folder header and sometimes its own text extraction.
-- Every copy is searched, judged, distilled and linked on its own, so
-- the same facts get distilled twice and links to one paper are split
-- across its copies (2026-10-28: 310 groups of identical texts, 458
-- extra copies, in production).
--
-- find_groups pairs copies two ways, with no model call:
-- * same text: the same body once the sync header (document.
--   preamble_end) is cut off and whitespace is collapsed;
-- * same paper: two PDFs with the same title once case, punctuation
--   and a leading year are dropped, and most of the body's word 5-grams
--   shared (DUPLICATE_MIN_SHARED) -- two extractions of one paper. Only
--   PDFs: two spreadsheets or protocols with the same title and most of
--   the text in common are usually two versions whose differences
--   matter (2026-10-28 in production: "EXPERIMENT 42 DATA" x3, 89%).
-- Only synced files are considered (external_id "sharepoint:..."):
-- a page someone wrote is never folded into another, the same rule
-- knowledge.duplication_status keeps.
--
-- fold keeps the copy with the lowest id (the one a [[Title]] link
-- already resolves to), points links to the other copies at it, and
-- archives them, recording duplicate_of/merged_into. Archiving is what
-- takes a copy out of the pool: its heat goes back to the pool, its
-- vector leaves its tags' centres, its embedding and outgoing links go
-- (document.on_entity_archived). A later sync updates the archived row
-- in place and doesn't bring it back.

document = require("document")
entity = require("entity")
db = require("database")
hmac = require("hmac")

duplicate = {}

-- A body shorter than this is a stub (a folder page, a file whose text
-- didn't extract): stubs look alike without being the same paper.
DUPLICATE_MIN_BODY = 2000
-- Share of word 5-grams two extractions of the same paper must have in
-- common (of the smaller set), and the least their word counts may
-- differ by (shorter / longer).
DUPLICATE_MIN_SHARED = 0.8
DUPLICATE_MIN_LENGTH_RATIO = 0.8
DUPLICATE_SHINGLE_WORDS = 5
DUPLICATE_BATCH = 100

function duplicate.body(content)
    if content == nil then
        return ""
    end
    body = string.sub(content, document.preamble_end(content))
    body = string.gsub(body, "%s+", " ")
    body = string.gsub(body, "^ ", "")
    body = string.gsub(body, " $", "")
    return body
end

-- The file type of a synced file, from its sync header's link
-- ("> **SharePoint:** [folder/name.pdf](...)"), lower case, or nil.
function duplicate.file_type(content)
    if content == nil then
        return nil
    end
    name = string.match(string.sub(content, 1, document.preamble_end(content)), "%[([^%]\n]*)%]%(")
    if name == nil then
        return nil
    end
    extension = string.match(name, "%.(%w+)%s*$")
    if extension == nil then
        return nil
    end
    return string.lower(extension)
end

function duplicate.title_key(title)
    if title == nil then
        title = ""
    end
    key = string.lower(tostring(title))
    key = string.gsub(key, "^%s*%d%d%d%d[%s%-_]+", "")
    key = string.gsub(key, "[^%w]+", " ")
    key = string.gsub(key, "^ ", "")
    key = string.gsub(key, " $", "")
    return key
end

-- Word 5-grams of a body, as a set, and how many words it has.
function duplicate.shingles(body)
    words = {}
    for word in string.gmatch(string.lower(body), "%w+") do
        table.insert(words, word)
    end
    set = {}
    count = 0
    for i = 1, #words - DUPLICATE_SHINGLE_WORDS + 1 do
        shingle = table.concat(words, " ", i, i + DUPLICATE_SHINGLE_WORDS - 1)
        if set[shingle] == nil then
            set[shingle] = true
            count = count + 1
        end
    end
    return set, count, #words
end

-- Share of the smaller shingle set found in the larger one.
function duplicate.shared(a, a_count, b, b_count)
    if a_count == 0 or b_count == 0 then
        return 0
    end
    small, small_count, large = a, a_count, b
    if b_count < a_count then
        small, small_count, large = b, b_count, a
    end
    common = 0
    for shingle, _ in pairs(small) do
        if large[shingle] != nil then
            common = common + 1
        end
    end
    return common / small_count
end

function duplicate_rows(db_path, sql)
    rows = db.query(db_path, sql)
    if rows == nil then
        return {}
    end
    return rows
end

function duplicate_issue(issues)
    if issues == nil or issues[1] == nil then
        return "unknown error"
    end
    return tostring(issues[1].message)
end

function duplicate_candidates(db_path)
    return duplicate_rows(db_path, """
        SELECT id, title FROM document
        WHERE (archived_at IS NULL OR archived_at = '')
          AND (merged_into IS NULL OR merged_into = '')
          AND external_id LIKE 'sharepoint:%'
        ORDER BY id;""")
end

function duplicate_root(parents, id)
    while parents[id] != id do
        parents[id] = parents[parents[id]]
        id = parents[id]
    end
    return id
end

function duplicate_join(parents, reasons, a, b, reason)
    root_a = duplicate_root(parents, a)
    root_b = duplicate_root(parents, b)
    if root_a == root_b then
        return
    end
    -- The lower id stays the root: it's the copy that's kept.
    if root_b < root_a then
        root_a, root_b = root_b, root_a
    end
    parents[root_b] = root_a
    if reasons[math.max(a, b)] == nil then
        reasons[math.max(a, b)] = reason
    end
end

-- Groups of copies of the same paper: a list of {keep = id, title =
-- title, copies = {{id, title, reason}, ...}}, ordered by the kept id.
function duplicate.find_groups(db_path)
    rows = duplicate_candidates(db_path)
    titles = {}
    title_counts = {}
    for _, row in ipairs(rows) do
        id = tonumber(row.id)
        titles[id] = row.title
        key = duplicate.title_key(row.title)
        if key != "" then
            if title_counts[key] == nil then
                title_counts[key] = 0
            end
            title_counts[key] = title_counts[key] + 1
        end
    end

    parents = {}
    reasons = {}
    first_by_hash = {}
    by_title = {}
    for i = 1, #rows, DUPLICATE_BATCH do
        ids = {}
        for j = i, math.min(i + DUPLICATE_BATCH - 1, #rows) do
            table.insert(ids, tostring(tonumber(rows[j].id)))
        end
        batch = duplicate_rows(db_path, "SELECT id, content FROM document WHERE id IN (" .. table.concat(ids, ",") .. ");")
        for _, row in ipairs(batch) do
            id = tonumber(row.id)
            body = duplicate.body(row.content)
            if string.len(body) >= DUPLICATE_MIN_BODY then
                parents[id] = id
                hash = hmac.sha256("document_body", body)
                if first_by_hash[hash] == nil then
                    first_by_hash[hash] = id
                else
                    duplicate_join(parents, reasons, first_by_hash[hash], id, "same text")
                end
                key = duplicate.title_key(titles[id])
                if key != "" and title_counts[key] > 1 and duplicate.file_type(row.content) == "pdf" then
                    set, count, words = duplicate.shingles(body)
                    if by_title[key] == nil then
                        by_title[key] = {}
                    end
                    table.insert(by_title[key], {id = id, set = set, count = count, words = words})
                end
            end
        end
    end

    for _, entries in pairs(by_title) do
        for a = 1, #entries do
            for b = a + 1, #entries do
                x, y = entries[a], entries[b]
                if duplicate_root(parents, x.id) != duplicate_root(parents, y.id)
                        and math.min(x.words, y.words) / math.max(x.words, y.words) >= DUPLICATE_MIN_LENGTH_RATIO then
                    share = duplicate.shared(x.set, x.count, y.set, y.count)
                    if share >= DUPLICATE_MIN_SHARED then
                        duplicate_join(parents, reasons, x.id, y.id, string.format("same title, %d%% of the text shared", math.floor(share * 100)))
                    end
                end
            end
        end
    end

    groups_by_root = {}
    roots = {}
    for id, _ in pairs(parents) do
        root = duplicate_root(parents, id)
        if root != id then
            if groups_by_root[root] == nil then
                groups_by_root[root] = {keep = root, title = titles[root], copies = {}}
                table.insert(roots, root)
            end
            reason = reasons[id]
            if reason == nil then
                reason = "a copy of another copy"
            end
            table.insert(groups_by_root[root].copies, {id = id, title = titles[id], reason = reason})
        end
    end
    table.sort(roots)
    groups = {}
    for _, root in ipairs(roots) do
        table.sort(groups_by_root[root].copies, function(a, b) return a.id < b.id end)
        table.insert(groups, groups_by_root[root])
    end
    return groups
end

-- Folds one copy into the kept document: links to the copy point at the
-- kept one (a link from the kept one to its own copy is archived), the
-- copy records where it went, and it's archived like any document
-- leaving the pool. Returns the number of links re-pointed.
function duplicate.fold(db_path, copy_id, keep_id)
    copy_id = tonumber(copy_id)
    keep_id = tonumber(keep_id)
    db.exec(db_path, string.format(
        "UPDATE document_link SET archived_at = %s WHERE to_document_id = %d AND from_document_id = %d AND (archived_at IS NULL OR archived_at = '');",
        db.now_expr(db_path), copy_id, keep_id))
    rows = db.query(db_path, string.format(
        "SELECT COUNT(*) AS n FROM document_link WHERE to_document_id = %d AND (archived_at IS NULL OR archived_at = '');", copy_id))
    moved = tonumber(rows[1].n)
    db.exec(db_path, string.format(
        "UPDATE document_link SET to_document_id = %d WHERE to_document_id = %d AND (archived_at IS NULL OR archived_at = '');",
        keep_id, copy_id))
    db.exec(db_path, string.format(
        "UPDATE document SET duplicate_of = %d, merged_into = %d WHERE id = %d;", keep_id, keep_id, copy_id))
    archived_id, issues = entity.archive(db_path, "document", copy_id, "system", nil, "duplicate of #" .. tostring(keep_id))
    if archived_id == nil then
        return nil, issues
    end
    document.on_entity_archived(db_path, "document", archived_id)
    return moved
end

-- A connection document (A ↔ B) left linking one paper to itself once
-- its copies are folded says nothing; it's archived too.
function duplicate_self_connections(db_path, keep_ids)
    found = {}
    for _, keep_id in ipairs(keep_ids) do
        rows = duplicate_rows(db_path, string.format("""
            SELECT d.id, d.title FROM document d
            JOIN document_link l ON l.from_document_id = d.id AND (l.archived_at IS NULL OR l.archived_at = '')
            WHERE (d.archived_at IS NULL OR d.archived_at = '')
            GROUP BY d.id, d.title
            HAVING COUNT(*) >= 2 AND MIN(l.to_document_id) = %d AND MAX(l.to_document_id) = %d;""", keep_id, keep_id))
        for _, row in ipairs(rows) do
            if document.is_connection_title(row.title) then
                table.insert(found, {id = tonumber(row.id), title = row.title})
            end
        end
    end
    return found
end

-- `daat repair duplicates [--dry-run]`: report lines, ending with counts.
function duplicate.repair(db_path, dry_run)
    lines = {}
    groups = duplicate.find_groups(db_path)
    copies = 0
    moved = 0
    keep_ids = {}
    for _, group in ipairs(groups) do
        table.insert(keep_ids, group.keep)
        for _, copy in ipairs(group.copies) do
            copies = copies + 1
            if dry_run then
                table.insert(lines, string.format("would fold #%d %s into #%d %s (%s)",
                    copy.id, tostring(copy.title), group.keep, tostring(group.title), copy.reason))
            else
                n, issues = duplicate.fold(db_path, copy.id, group.keep)
                if n == nil then
                    table.insert(lines, string.format("could not fold #%d: %s", copy.id, duplicate_issue(issues)))
                else
                    moved = moved + n
                    table.insert(lines, string.format("folded #%d %s into #%d %s (%s)",
                        copy.id, tostring(copy.title), group.keep, tostring(group.title), copy.reason))
                end
            end
        end
    end
    revoked = 0
    if not dry_run then
        for _, connection in ipairs(duplicate_self_connections(db_path, keep_ids)) do
            archived_id = entity.archive(db_path, "document", connection.id, "system", nil, "connects a paper to its own copy")
            if archived_id != nil then
                document.on_entity_archived(db_path, "document", archived_id)
                revoked = revoked + 1
                table.insert(lines, string.format("archived #%d %s (connects a paper to its own copy)", connection.id, tostring(connection.title)))
            end
        end
    end
    if dry_run then
        table.insert(lines, string.format("%d paper(s) with copies, %d copy(ies) would be folded", #groups, copies))
    else
        table.insert(lines, string.format("%d paper(s) with copies, %d copy(ies) folded, %d link(s) re-pointed, %d self-connection(s) archived",
            #groups, copies, moved, revoked))
    end
    return lines
end

return duplicate
