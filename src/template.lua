-- Loads sandboxed templates/<name>.lua definitions and renders inert Markdown snippets.
-- Needs no admin approval; see doc/decisions/006-trusted-page-sections-vs-extension-canvas.md and doc/templating.md.

const paths = require("paths")
const lfs = require("lfs")
const sandbox = require("sandbox")
const schema = require("schema")

const template = {}

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
    if not schema.valid_resource_name(name) then
        return nil, "invalid template name: " .. tostring(name)
    end
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

-- Root-relative href so snippets work regardless of where they are pasted.
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

-- Emits an inert {{view:...:EXPERIMENT_ID}} placeholder for manual substitution.
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
