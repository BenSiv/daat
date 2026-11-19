-- Document text, query tokenization, connection-title, and embedding-text
-- helpers shared across document, passage, aspect, and tag without creating
-- circular module dependencies.

const db = require("database")
const entity = require("entity")
const config = require("config")

const document_text = {}

const CONNECTION_TITLE_SEPARATOR = " ↔ "
document_text.CONNECTION_TITLE_SEPARATOR = CONNECTION_TITLE_SEPARATOR

function document_text.is_connection_title(title)
    if title == nil then
        return false
    end
    return string.find(title, CONNECTION_TITLE_SEPARATOR, 1, true) != nil
end

function document_text.connection_title_count(title)
    if title == nil then
        return 0
    end
    count = 0
    start = 1
    while true do
        found = string.find(title, CONNECTION_TITLE_SEPARATOR, start, true)
        if found == nil then
            return count
        end
        count = count + 1
        start = found + 1
    end
end

const SEARCH_STOPWORDS = {}
for _, word in ipairs({
    "a", "an", "and", "or", "not", "the", "of", "in", "on", "at", "to", "for", "from", "by", "with",
    "into", "about", "as", "is", "are", "was", "were", "be", "been", "it", "its", "this", "that",
    "these", "those", "what", "which", "who", "how", "when", "where", "why", "do", "does", "did",
    "we", "our", "you", "your", "any", "all", "there", "their", "than", "then", "vs",
}) do
    SEARCH_STOPWORDS[word] = true
end
document_text.SEARCH_STOPWORDS = SEARCH_STOPWORDS

const SEARCH_MAX_TERMS = 8
document_text.SEARCH_MAX_TERMS = SEARCH_MAX_TERMS

function document_text.query_terms(query_text)
    terms = {}
    if query_text == nil then
        return terms
    end
    seen = {}
    for word in string.gmatch(string.lower(query_text), "%S+") do
        word = string.gsub(word, "^[%p]+", "")
        word = string.gsub(word, "[%p]+$", "")
        if string.len(word) > 1 and SEARCH_STOPWORDS[word] == nil and seen[word] == nil and #terms < SEARCH_MAX_TERMS then
            seen[word] = true
            table.insert(terms, word)
        end
    end
    return terms
end

function document_text.preamble_end(content)
    position = 1
    while string.sub(content, position, position) == ">" or string.sub(content, position, position) == "\n" do
        line_end = string.find(content, "\n", position, true)
        if line_end == nil then
            break
        end
        position = line_end + 1
    end
    rule_end = string.match(content, "^%-%-%-+\n+()", position)
    if position > 1 and rule_end != nil then
        return rule_end
    end
    return 1
end

function document_text.legacy_embedding_text(doc)
    text = doc.title
    if doc.content != nil and doc.content != "" then
        text = text .. "\n" .. doc.content
    end
    return text
end

function sql_non_empty(v)
    if v == nil or v == "" then
        return nil
    end
    return v
end

function document_text.transcript_conversation(db_path, document_id)
    rows = db.query(db_path, string.format(
        "SELECT source_type, source_ref FROM document WHERE id = %d;", tonumber(document_id)))
    if rows == nil or rows[1] == nil or rows[1].source_type != "chat_session" or sql_non_empty(rows[1].source_ref) == nil then
        return nil
    end
    agent_mod = require("agent")
    parts = {}
    for _, msg in ipairs(agent_mod.all_messages(db_path, rows[1].source_ref, false)) do
        if (msg.role == "user" or msg.role == "assistant") and msg.content != nil and msg.content != "" then
            label = "User"
            if msg.role == "assistant" then
                label = "Assistant"
            end
            table.insert(parts, label .. ": " .. msg.content)
        end
    end
    return table.concat(parts, "\n\n")
end

function document_text.compute_embedding_text(db_path, doc)
    body = document_text.transcript_conversation(db_path, doc.id)
    if body == nil then
        body = doc.content
    end
    if body == nil then
        body = ""
    end
    patterns = config.platform_config().embedding_skip
    if patterns != nil and #patterns > 0 then
        kept = {}
        for line in string.gmatch(body .. "\n", "(.-)\n") do
            skip = false
            for _, pattern in ipairs(patterns) do
                if string.find(line, pattern) != nil then
                    skip = true
                    break
                end
            end
            if skip == false then
                table.insert(kept, line)
            end
        end
        body = table.concat(kept, "\n")
    end
    body = string.gsub(body, "^%s+", "")
    body = string.gsub(body, "%s+$", "")
    if body == "" then
        return doc.title, 0
    end
    return doc.title .. "\n" .. body, string.len(body)
end

function document_text.embedding_text(db_path, document_id)
    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil
    end
    text, _ = document_text.compute_embedding_text(db_path, doc)
    return text
end

return document_text
