-- `daat repair <name> [args]` -- rebuilds of state daat derives from its
-- own source-of-truth tables, kept out of the everyday command groups so
-- they don't crowd the CLI surface however many get added.
--
-- What belongs here: deterministic, idempotent, free to rerun at any
-- time, correct for any deployment -- the platform's own REINDEX. Every
-- write path already keeps this state current (entity.create/update's
-- document hooks), so a repair is only for recovery: a raw SQL insert, a
-- restored backup, a provider outage that dropped a best-effort
-- embedding. What doesn't: one-off migrations of a specific deployment's
-- data, or anything involving a model's judgment that should be reviewed
-- before it's written -- those live with the deployment, not here.
--
-- A new repair is one REPAIRS entry; `daat repair` with no name lists
-- them all.

document = require("document")
tag = require("tag")
tag_upkeep = require("tag_upkeep")
reference = require("reference")

repair = {}

function repair_links(cmd_args, db_path)
    entity_id = tonumber(cmd_args[2])
    if entity_id != nil then
        ok, err = document.resync_links(db_path, entity_id)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Resynced links for document #" .. tostring(entity_id))
        return
    end
    resynced, unchanged = document.resync_all_links(db_path, cmd_args[2] == "--all")
    print(string.format("Resynced links for %d document(s), %d unchanged", resynced, unchanged))
end

function repair_embeddings(cmd_args, db_path)
    entity_id = tonumber(cmd_args[2])
    if entity_id != nil then
        ok, err = document.reindex_embedding(db_path, entity_id)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Reindexed embedding for document #" .. tostring(entity_id))
        return
    end
    reindexed, failed, unchanged = document.reindex_all_embeddings(db_path, entity_id == nil and cmd_args[2] == "--all")
    print(string.format("Reindexed %d document(s), %d failed, %d unchanged", reindexed, failed, unchanged))
end

function repair_embeddings_packed(cmd_args, db_path)
    packed = document.repack_all_embeddings(db_path)
    print(string.format("Packed %d embedding(s)", packed))
end

function repair_pool_count(cmd_args, db_path)
    count = document.resync_pool_count(db_path)
    print("document_count resynced to " .. tostring(count))
end

-- With a document id, re-places that one document by nearest tag;
-- without, rebuilds every tag's centre from its memberships (after
-- `repair embeddings`, a raw SQL write, or a change of tag_dims).
function repair_tags(cmd_args, db_path)
    entity_id = tonumber(cmd_args[2])
    if entity_id != nil then
        chosen = tag.place_document(db_path, entity_id)
        if #chosen == 0 then
            print("Document #" .. tostring(entity_id) .. " not placed: no embedding, or no tags with a centre")
            return
        end
        names = {}
        for _, tag_id in ipairs(chosen) do
            table.insert(names, "#" .. tostring(tag_id))
        end
        print("Document #" .. tostring(entity_id) .. " is in tag " .. table.concat(names, ", "))
        return
    end
    flags = {}
    pairs_above = nil
    for i = 2, #cmd_args do
        flags[cmd_args[i]] = true
        if cmd_args[i] == "--pairs-above" then
            pairs_above = tonumber(cmd_args[i + 1])
        end
    end
    if flags["--restructure"] == true then
        -- --dry-run: proposals only; --judge with it: the agent's
        -- verdicts too; neither: judge and apply (doc/tag-ontology.md).
        -- --pairs-above C: every pair of tags above cosine C as a merge,
        -- a review only.
        dry_run = flags["--dry-run"] == true
        if flags["--pairs-above"] == true and pairs_above == nil then
            print("Usage: daat repair tags --restructure --dry-run --judge --pairs-above <cosine>")
            return
        end
        report = tag_upkeep.run(db_path, {judge = (not dry_run) or flags["--judge"] == true, apply = not dry_run,
            pairs_above = pairs_above})
        if #report == 0 then
            print("Nothing to restructure")
        end
        for _, line in ipairs(report) do
            print(line)
        end
        return
    end
    tags, members = tag.rebuild_centres(db_path)
    tag_upkeep.record_baselines(db_path)
    print(string.format("Rebuilt %d tag centre(s) from %d membership(s)", tags, members))
end

function repair_knowledge(cmd_args, db_path)
    dry_run = cmd_args[2] == "--dry-run"
    for _, result in ipairs(document.prune_derived(db_path, dry_run)) do
        action = result.action
        if dry_run and action != "left" then
            action = "would be " .. action
        end
        print(string.format("%6d %s: %s", result.count, result.label, action))
    end
end

function repair_tag_evidence(cmd_args, db_path)
    written = tag.refresh_evidence(db_path)
    print(string.format("Refreshed core tag evidence: %d row(s) written", written))
end

function repair_references(cmd_args, db_path)
    names = reference.rebuild_names(db_path)
    documents = reference.resync_all_documents(db_path)
    print(string.format("Indexed %d entity name(s); re-read references in %d document(s)", names, documents))
end

function repair_duplicates(cmd_args, db_path)
    duplicate = require("duplicate")
    for _, line in ipairs(duplicate.repair(db_path, cmd_args[2] == "--dry-run")) do
        print(line)
    end
end

function repair_curate(cmd_args, db_path)
    curate = require("curate")
    limit = nil
    dry_run = false
    recheck = false
    i = 2
    while i <= #cmd_args do
        if cmd_args[i] == "--dry-run" then
            dry_run = true
        elseif cmd_args[i] == "--recheck" then
            recheck = true
        elseif cmd_args[i] == "--limit" then
            limit = tonumber(cmd_args[i + 1])
            i = i + 1
        end
        i = i + 1
    end
    for _, line in ipairs(curate.repair(db_path, limit, dry_run, "system", recheck)) do
        print(line)
    end
end

function repair_synthesize(cmd_args, db_path)
    synthesize = require("synthesize")
    limit = nil
    dry_run = false
    recheck = false
    i = 2
    while i <= #cmd_args do
        if cmd_args[i] == "--dry-run" then
            dry_run = true
        elseif cmd_args[i] == "--recheck" then
            recheck = true
        elseif cmd_args[i] == "--limit" then
            limit = tonumber(cmd_args[i + 1])
            i = i + 1
        end
        i = i + 1
    end
    for _, line in ipairs(synthesize.repair(db_path, limit, dry_run, "system", recheck)) do
        print(line)
    end
end

function repair_distill(cmd_args, db_path)
    distill = require("distill")
    limit = nil
    dry_run = false
    recheck = false
    i = 2
    while i <= #cmd_args do
        if cmd_args[i] == "--dry-run" then
            dry_run = true
        elseif cmd_args[i] == "--recheck" then
            recheck = true
        elseif cmd_args[i] == "--limit" then
            limit = tonumber(cmd_args[i + 1])
            i = i + 1
        end
        i = i + 1
    end
    for _, line in ipairs(distill.repair(db_path, limit, dry_run, "system", recheck)) do
        print(line)
    end
end

function repair_connections(cmd_args, db_path)
    knowledge = require("knowledge")
    flags = {}
    for i = 2, #cmd_args do
        flags[cmd_args[i]] = true
    end
    for _, line in ipairs(knowledge.repair_connections(db_path, flags["--dry-run"] == true, flags["--all"] == true)) do
        print(line)
    end
end

-- Ordered (a list, not a map) so `daat repair`'s listing is stable.
REPAIRS = {
    {name = "links", usage = "links [document_id | --all]", run = repair_links,
     description = "Re-parse [[...]] links from document content into document_link, for documents whose content changed since their links were last synced (--all: every document)."},
    {name = "embeddings", usage = "embeddings [document_id | --all]", run = repair_embeddings,
     description = "Embed documents whose embedding is missing, from another model, or of changed text (--all: every document; one provider call each)."},
    {name = "embeddings-packed", usage = "embeddings-packed", run = repair_embeddings_packed,
     description = "Pack stored embeddings into the binary form search reads (no provider calls)."},
    {name = "tags", usage = "tags [document_id | --restructure [--dry-run [--judge] [--pairs-above C]]]", run = repair_tags,
     description = "Rebuild tag centres from memberships (and the upkeep baselines), re-place one document by nearest tag, or split/merge/re-check tags with the agent's judgment."},
    {name = "tag-evidence", usage = "tag-evidence", run = repair_tag_evidence,
     description = "Recompute core tag evidence (link, connection) from links and memberships."},
    {name = "references", usage = "references", run = repair_references,
     description = "Re-index entity names, then re-read every document's references to them."},
    {name = "knowledge", usage = "knowledge [--dry-run]", run = repair_knowledge,
     description = "Remove rows derived from archived documents or tags (embeddings, references; links archived); counts embeddings from another model."},
    {name = "connections", usage = "connections [--all] [--dry-run]", run = repair_connections,
     description = "Put every connection document (A ↔ B) through the pipeline a new pair goes through: archive one whose two documents' most similar passages score below link_passage_gate (comparing every passage, no model call); ask the agent again about one the gate can't measure, one whose reason doesn't say what both share, or (--all) every one, rewriting it with a real reason or archiving it; archive one connecting another connection document (--dry-run: list them, with scores and passages; no model calls)."},
    {name = "duplicates", usage = "duplicates [--dry-run]", run = repair_duplicates,
     description = "Fold copies of the same synced file (same text past the sync header, or the same title and most of the text) into one copy (the lowest id with a real title): links move to it, the copies are archived as its duplicates (--dry-run: list them)."},
    {name = "curate", usage = "curate [--limit N] [--dry-run] [--recheck]", run = repair_curate,
     description = "Curate the sources already in use (retrieved twice or more), most used first, into checked tier-1 notes -- one model call to write and one to check each (--dry-run: list them, no model calls; --recheck: try again the sources that came to nothing, were rejected or failed)."},
    {name = "synthesize", usage = "synthesize [--limit N] [--dry-run] [--recheck]", run = repair_synthesize,
     description = "Write a tier-2 reference for each tag holding three or more curated notes, from those notes -- one model call to write and one to check each; rewritten in place when the notes change (--dry-run: list the tags, no model calls; --recheck: try again the tags that came to nothing, were rejected or failed)."},
    {name = "distill", usage = "distill [--limit N] [--dry-run] [--recheck]", run = repair_distill,
     description = "Split each tier-2 reference into tier-3 records -- single claims citing their notes -- deduplicated by embedding against existing records and legacy distilled facts (an agent judges near matches; a covered legacy fact is archived into its record); one call to extract, one to check, one per near match (--dry-run: list the references, no model calls; --recheck: try again the ones that came to nothing or failed)."},
    {name = "pool-count", usage = "pool-count", run = repair_pool_count,
     description = "Recount active documents into knowledge_pool_state.document_count."},
}

function repair.do_repair(cmd_args, db_path)
    name = cmd_args[1]
    for _, entry in ipairs(REPAIRS) do
        if entry.name == name then
            entry.run(cmd_args, db_path)
            return
        end
    end
    if name != nil then
        print("'" .. tostring(name) .. "' is not a repair")
    end
    print("Usage: daat repair <name> [args]")
    for _, entry in ipairs(REPAIRS) do
        print(string.format("  %-26s %s", entry.usage, entry.description))
    end
end

return repair
