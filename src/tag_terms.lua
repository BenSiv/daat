-- Distinctive words per tag (doc/tag-ontology.md, decision log
-- 2026-10-30): class-based TF-IDF, as in BERTopic -- a word scores by how
-- much of a tag's text it is, weighted by how rare it is across all tags
-- -- so a tag's words are the ones that set it apart from the others, not
-- the ones every tag shares ("culture", "cocoa"). They go to the agent
-- next to the tag's central documents when it names a tag: central
-- documents say what a tag is about, distinctive words how it differs
-- from its neighbours.

db = require("database")
document = require("document")

tag_terms = {}

-- How much of each document is read: its title and the start of its own
-- text (past any sync header).
TERMS_CHARS_PER_DOCUMENT = 4000
-- A word must appear in this many of a tag's documents to count, so one
-- long document can't fill a tag's list.
TERMS_MIN_DOCUMENTS = 2
TERMS_PER_TAG = 12

-- Common English filler beyond search's stopwords.
TERMS_STOPWORDS = {}
for _, word in ipairs({
    "has", "have", "had", "can", "could", "will", "would", "should", "may", "might", "also", "such",
    "use", "used", "using", "each", "other", "between", "after", "before", "during", "while", "both",
    "more", "most", "less", "than", "only", "some", "same", "per", "via", "within", "without", "over",
    "under", "here", "they", "them", "his", "her", "she", "him", "one", "two", "three", "new", "see",
}) do
    TERMS_STOPWORDS[word] = true
end

function terms_words(text, out)
    for word in string.gmatch(string.lower(text), "%a+") do
        if string.len(word) >= 3 and document.search_stopwords[word] == nil and TERMS_STOPWORDS[word] == nil then
            out[word] = true
        end
    end
end

-- {key -> {document id, ...}} -> {key -> {word, ...}}, most distinctive
-- first. Keys are whatever the caller groups by (a tag id, a planned
-- tag's number).
function tag_terms.distinctive(db_path, groups, per_tag)
    if per_tag == nil then
        per_tag = TERMS_PER_TAG
    end
    -- Each document's set of words, read once.
    wanted, ids = {}, {}
    for _, docs in pairs(groups) do
        for _, id in ipairs(docs) do
            key = tostring(tonumber(id))
            if wanted[key] == nil then
                wanted[key] = true
                table.insert(ids, key)
            end
        end
    end
    words_of = {}
    for start = 1, #ids, 500 do
        chunk = {}
        for i = start, math.min(start + 499, #ids) do
            table.insert(chunk, ids[i])
        end
        rows = db.query(db_path, string.format(
            "SELECT id, title, SUBSTR(COALESCE(content, ''), 1, %d) AS head FROM document WHERE id IN (%s);",
            TERMS_CHARS_PER_DOCUMENT * 2, table.concat(chunk, ", ")))
        if rows != nil then
            for _, row in ipairs(rows) do
                text = tostring(row.head)
                text = string.sub(text, document.preamble_end(text), document.preamble_end(text) + TERMS_CHARS_PER_DOCUMENT)
                set = {}
                terms_words(tostring(row.title) .. " " .. text, set)
                words_of[tostring(tonumber(row.id))] = set
            end
        end
    end
    -- Per group: in how many of its documents each word appears.
    counts, totals = {}, {}
    across = {}
    -- In how many groups a word appears: one in more than half of them
    -- says nothing about any one group ("cocoa" in a cocoa lab).
    groups_with = {}
    total_all, group_count = 0, 0
    for key, docs in pairs(groups) do
        c, total = {}, 0
        for _, id in ipairs(docs) do
            set = words_of[tostring(tonumber(id))]
            if set != nil then
                for word, _ in pairs(set) do
                    if c[word] == nil then
                        c[word] = 0
                    end
                    c[word] = c[word] + 1
                    total = total + 1
                end
            end
        end
        counts[key], totals[key] = c, total
        for word, n in pairs(c) do
            if across[word] == nil then
                across[word] = 0
                groups_with[word] = 0
            end
            across[word] = across[word] + n
            groups_with[word] = groups_with[word] + 1
        end
        total_all = total_all + total
        group_count = group_count + 1
    end
    average = 1
    if group_count > 0 and total_all > 0 then
        average = total_all / group_count
    end
    out = {}
    for key, c in pairs(counts) do
        scored = {}
        for word, n in pairs(c) do
            shared = group_count >= 2 and groups_with[word] > group_count / 2
            if n >= TERMS_MIN_DOCUMENTS and totals[key] > 0 and not shared then
                score = (n / totals[key]) * math.log(1 + average / across[word])
                table.insert(scored, {word = word, score = score})
            end
        end
        table.sort(scored, function(a, b)
            if a.score == b.score then
                return a.word < b.word
            end
            return a.score > b.score
        end)
        words = {}
        for i = 1, math.min(per_tag, #scored) do
            table.insert(words, scored[i].word)
        end
        out[key] = words
    end
    return out
end

return tag_terms
