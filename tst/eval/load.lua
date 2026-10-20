-- Builds a demo-lab deployment in the current directory
-- (doc/agent-eval.md, "Loader"). Run from an empty directory that
-- already holds platform.lua and schemas/ -- bld/eval-env.sh does that
-- and caches the result.
--
--   luam tst/eval/load.lua <repo_root> [seed]
--
-- Writes the usual .store/ plus facts.json: the generator's facts with
-- every record key resolved to the id the database actually gave it.

json = require("dkjson")
db = require("database")
config = require("config")
init = require("init")
schema = require("schema")
entity = require("entity")
auth = require("auth")
document = require("document")
knowledge = require("knowledge")
agent = require("agent")

EVAL_USER = "eval"

repo_root = arg[1]
seed = tonumber(arg[2])
if repo_root == nil then
    print("Usage: luam tst/eval/load.lua <repo_root> [seed]")
    os.exit(2)
end

generator = dofile(repo_root .. "/tst/eval/demo-lab/generate.lua")
lab = generator.generate({seed = seed})

-- Run quietly: init and schema print progress meant for a person.
real_print = _G.print
_G.print = function(...) end
init.do_init({}, ".")
db_path = config.db_path(".")
schema.sync_all(db_path, ".")
_G.print = real_print

ok, err = auth.create_user(db_path, EVAL_USER, "eval-password", "ia")
if ok == nil then
    error("could not create the eval user: " .. tostring(err))
end

ids = {}

function resolve(value)
    if type(value) == "string" and string.sub(value, 1, 1) == "@" then
        id = ids[string.sub(value, 2)]
        if id == nil then
            error("unresolved key " .. value)
        end
        return id
    end
    if type(value) == "table" and value.ref != nil then
        return value.type .. ":" .. tostring(resolve(value.ref))
    end
    if type(value) == "table" then
        resolved = {}
        for i, item in ipairs(value) do
            resolved[i] = resolve(item)
        end
        return resolved
    end
    return value
end

function issues_text(issues)
    parts = {}
    if issues == nil then
        return ""
    end
    for _, issue in ipairs(issues) do
        table.insert(parts, tostring(issue.field) .. ": " .. tostring(issue.message))
    end
    return table.concat(parts, "; ")
end

for _, rec in ipairs(lab.records) do
    values = {}
    for field, value in pairs(rec.values) do
        values[field] = resolve(value)
    end
    id, issues = entity.create(db_path, rec.type, values, EVAL_USER)
    if id == nil then
        error("could not create " .. rec.key .. ": " .. issues_text(issues))
    end
    ids[rec.key] = id
    if rec.archive == true then
        archived, archive_err = entity.archive(db_path, rec.type, id, EVAL_USER, nil, "superseded by a repeat run")
        if archived == nil then
            error("could not archive " .. rec.key .. ": " .. tostring(archive_err))
        end
    end
end

for _, doc in ipairs(lab.documents) do
    id, issues = document.create_page(db_path, EVAL_USER, doc.title, nil, doc.content, nil)
    if id == nil then
        error("could not create document " .. doc.key .. ": " .. issues_text(issues))
    end
    ids[doc.key] = id
end

document.embed_pending(db_path)
embedded = db.query(db_path, "SELECT COUNT(*) AS n FROM document_embedding;")[1].n

-- A document without an embedding is invisible to semantic search, so
-- a half-embedded lab would quietly score retrieval wrong: refuse it.
if tonumber(embedded) < #lab.documents then
    error(string.format("only %d of %d documents were embedded -- check the provider's credentials",
        tonumber(embedded), #lab.documents))
end

lab.facts.ids = ids
lab.facts.user = EVAL_USER
file = io.open("facts.json", "w")
io.write(file, json.encode(lab.facts, {indent = true}))
io.close(file)

print(string.format("demo lab: %d records, %d documents, %d embedded",
    #lab.records, #lab.documents, tonumber(embedded)))
