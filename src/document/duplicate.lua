-- Exact-body and PDF word-5-gram duplicate detection and folding for externally
-- synced documents (`daat repair duplicates`); user-authored documents are never folded.
-- See doc/duplicate-papers.md and doc/decisions/007-usage-driven-knowledge-pool-and-curation-ladder.md.

const document = require("document")
const entity = require("entity")
const db = require("database")
const hmac = require("hmac")
const config = require("config")

const duplicate = {}

const DUPLICATE_MIN_BODY = 2000
const DUPLICATE_MIN_SHARED = 0.8
const DUPLICATE_MIN_LENGTH_RATIO = 0.8
const DUPLICATE_SHINGLE_WORDS = 5
const DUPLICATE_BATCH = 100

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

function duplicate.poor_title(title)
    if title == nil then
        return true
    end
    lowered = string.lower(title)
    if string.find(lowered, "copy", 1, true) != nil or string.find(lowered, "%(%d+%)%s*$") != nil then
        return true
    end
    -- Strip ASCII non-letters rather than matching %a so UTF-8 multibyte letters count.
    letters = string.gsub(lowered, "[%c%p%d%s]", "")
    return string.len(letters) < 4
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

function escape_like_prefix(prefix)
    escaped = string.gsub(prefix, "\\", "\\\\")
    escaped = string.gsub(escaped, "%%", "\\%%")
    escaped = string.gsub(escaped, "_", "\\_")
    return db.quote(escaped .. "%") .. " ESCAPE " .. db.quote("\\")
end

function duplicate_external_where()
    prefixes = config.load().duplicate_external_prefixes
    if prefixes == nil or #prefixes == 0 then
        return "external_id LIKE '%:%'"
    end
    clauses = {}
    for _, prefix in ipairs(prefixes) do
        table.insert(clauses, "external_id LIKE " .. escape_like_prefix(prefix))
    end
    return "(" .. table.concat(clauses, " OR ") .. ")"
end

function duplicate_candidates(db_path)
    return duplicate_rows(db_path, string.format("""
        SELECT id, title FROM document
        WHERE (archived_at IS NULL OR archived_at = '')
          AND merged_into IS NULL
          AND %s
        ORDER BY id;""", duplicate_external_where()))
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
    if root_b < root_a then
        root_a, root_b = root_b, root_a
    end
    parents[root_b] = root_a
    if reasons[math.max(a, b)] == nil then
        reasons[math.max(a, b)] = reason
    end
end

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

    members_by_root = {}
    roots = {}
    for id, _ in pairs(parents) do
        root = duplicate_root(parents, id)
        if members_by_root[root] == nil then
            members_by_root[root] = {}
            table.insert(roots, root)
        end
        table.insert(members_by_root[root], id)
    end
    table.sort(roots)
    groups = {}
    for _, root in ipairs(roots) do
        members = members_by_root[root]
        if #members > 1 then
            table.sort(members)
            keep = members[1]
            for _, id in ipairs(members) do
                if not duplicate.poor_title(titles[id]) then
                    keep = id
                    break
                end
            end
            group = {keep = keep, title = titles[keep], copies = {}}
            for _, id in ipairs(members) do
                if id != keep then
                    reason = reasons[id]
                    if reason == nil and id == root then
                        reason = reasons[keep]
                    end
                    if reason == nil then
                        reason = "a copy of another copy"
                    end
                    table.insert(group.copies, {id = id, title = titles[id], reason = reason})
                end
            end
            table.insert(groups, group)
        end
    end
    return groups
end

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
    return moved
end

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
