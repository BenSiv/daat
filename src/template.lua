-- Entry templates: reusable document layouts (a Luam table file,
-- version-controlled alongside schemas/extensions/views -- see
-- doc/schema.md's conventions), rendered into a plain Markdown snippet
-- the user copies into a new document they create themselves.
--
-- Deliberately a snippet generator, not a live wiki-write: platform's own
-- sandboxed request-handling has no path to invoke Fossil's own
-- wiki-create machinery (that's a `fossil` CLI operation, done outside
-- platform entirely -- see e.g. convert_entries_to_wiki.py, a standalone
-- script, not a platform extension). A template only ever produces inert
-- text, so unlike views (raw SQL) or extensions (sandboxed code), it
-- carries no execution risk and needs no admin-approval registry.
--
-- Shape:
--   return {
--       name = "bioreactor_experiment",  -- must match the filename
--       label = "Bioreactor Experiment",
--       description = "...",
--       default_path = "Notebook/Bioreactor Experiment",  -- optional, see below
--       sections = {
--           {type = "heading", text = "Objective"},
--           {type = "text", text = "..."},
--           {type = "registration_table", entity_type = "experiment",
--               label = "Experiment", columns = {"number", "title"}},
--           {type = "lookup_view", view_name = "samples_by_experiment",
--               label = "Samples for this experiment"},  -- an inert
--               -- {{view:...:EXPERIMENT_ID}} marker (see html.lua's
--               -- expand_inline_views) -- EXPERIMENT_ID is a literal
--               -- placeholder the user replaces by hand once pasted
--               -- into a real document, same as registration_table's own
--               -- generic, un-filled-in link above.
--       },
--   }
--
-- default_path is optional: it's the title value html.render_template
-- prefills the new document's Title field with (html.lua's own
-- render_template falls back to `label` if absent) -- a deployment's own
-- document-naming convention (e.g. a folder-path prefix) belongs here, in
-- a deployment's own template files, never hardcoded into platform itself.

paths = require("paths")
lfs = require("lfs")
sandbox = require("sandbox")

template = {}

function template.names(templates_dir)
    names = {}
    attr = lfs.attributes(templates_dir)
    if attr == nil or attr.mode != "directory" then
        return names
    end
    for dir_name in lfs.dir(templates_dir) do
        if dir_name != "." and dir_name != ".." then
            if string.match(dir_name, "%.lua$") != nil then
                name = string.gsub(dir_name, "%.lua$", "")
                table.insert(names, name)
            end
        end
    end
    return names
end

function template.validate(def)
    if type(def.name) != "string" or def.name == "" then
        return "template must have a non-empty string 'name'"
    end
    if type(def.sections) != "table" or #def.sections == 0 then
        return "template '" .. tostring(def.name) .. "' must have a non-empty 'sections' list"
    end
    for i, section in ipairs(def.sections) do
        if section.type == "heading" or section.type == "text" then
            if type(section.text) != "string" or section.text == "" then
                return string.format("template '%s' section #%d (%s): missing 'text'", def.name, i, section.type)
            end
        elseif section.type == "registration_table" then
            if type(section.entity_type) != "string" or section.entity_type == "" then
                return string.format("template '%s' section #%d: missing 'entity_type'", def.name, i)
            end
        elseif section.type == "lookup_view" then
            if type(section.view_name) != "string" or section.view_name == "" then
                return string.format("template '%s' section #%d: missing 'view_name'", def.name, i)
            end
        else
            return string.format("template '%s' section #%d: invalid type '%s'", def.name, i, tostring(section.type))
        end
    end
    return nil
end

function template.load(templates_dir, name)
    path = paths.joinpath(templates_dir, name .. ".lua")
    source = paths.read_file(path)
    if source == nil then
        return nil, "cannot open template: " .. path
    end
    ok, result = sandbox.run(source, path, sandbox.data_env())
    if ok == false or type(result) != "table" then
        return nil, "error loading template " .. path .. ": " .. tostring(result)
    end
    err = template.validate(result)
    if err != nil then
        return nil, err
    end
    return result
end

function template.all(templates_dir)
    result = {}
    for _, name in ipairs(template.names(templates_dir)) do
        def, err = template.load(templates_dir, name)
        table.insert(result, {name = name, def = def, err = err})
    end
    return result
end

-- Builds the registration-table link for a rendered template snippet.
-- Root-relative (assumes the app is mounted at "/") since this
-- Markdown is meant to be copied out and pasted somewhere else
-- entirely (a document, a message) -- unlike every other link this
-- app renders for its own pages, there's no "current page" to resolve
-- a relative reference against here.
function render_registration_table(section)
    label = section.label
    if label == nil then
        label = section.entity_type
    end
    href = "/register?type=" .. section.entity_type
    if section.columns != nil and #section.columns > 0 then
        href = href .. "&columns=" .. table.concat(section.columns, ",")
    end
    return "**" .. label .. "** -- [Open registration table ->](" .. href .. ")"
end

-- An inert `{{view:...}}` marker for a template snippet -- a template
-- is reusable across many future documents, so it has no experiment id
-- of its own to bind (unlike convert_entries_to_pages.py, which already
-- knows the real experiment_id at content-generation time). The
-- EXPERIMENT_ID placeholder is meant to be replaced by hand after
-- pasting the snippet into a real document, same philosophy as
-- render_registration_table's own generic, un-filled-in link.
function render_lookup_view(section)
    label = section.label
    if label == nil then
        label = section.view_name
    end
    return "**" .. label .. "** -- {{view:" .. section.view_name ..
        ":EXPERIMENT_ID}} _(replace EXPERIMENT_ID with this document's real experiment id)_"
end

function template.render(def)
    parts = {}
    for _, section in ipairs(def.sections) do
        if section.type == "heading" then
            table.insert(parts, "## " .. section.text)
        elseif section.type == "text" then
            table.insert(parts, section.text)
        elseif section.type == "registration_table" then
            table.insert(parts, render_registration_table(section))
        elseif section.type == "lookup_view" then
            table.insert(parts, render_lookup_view(section))
        end
    end
    return table.concat(parts, "\n\n")
end

return template
