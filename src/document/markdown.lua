-- Markdown rendering via cmark-gfm, inline [[link]]/#tag chips,
-- chat attachment text extraction, and gnuplot SVG fence rendering.

const doc_links = require("document.links")
const external_tool = require("external_tool")
const gnuplot = require("gnuplot")
const json = require("dkjson")
const markdown_lib = require("markdown")
const tag = require("tag")

const doc_markdown = {}

const LINK_PATTERN = doc_links.LINK_PATTERN
const ATTACHMENT_TEXT_MAX_CHARS = 20000
const PLOT_TYPE_TO_WITH = {line = "linespoints", scatter = "points", bar = "boxes"}

const ALLOWED_SERIES_WITH = {
    lines = "lines",
    points = "points",
    linespoints = "linespoints",
    boxes = "boxes",
    impulses = "impulses",
    steps = "steps",
    line = "linespoints",
    scatter = "points",
    bar = "boxes",
}

function doc_markdown.inline_links_to_markdown(db_path, content)
    function replace_segment_links(segment)
        return (string.gsub(segment, LINK_PATTERN, function(raw_link)
            target_id = doc_links.resolve_link_text(db_path, raw_link)
            if target_id != nil then
                return "[" .. raw_link .. "](document?entity_id=" .. tostring(target_id) .. ")"
            end
            return "*" .. raw_link .. "* _(not created yet)_"
        end))
    end
    return doc_links.transform_outside_code(content, replace_segment_links)
end

function doc_markdown.html_unescape(s)
    if s == nil then
        return ""
    end
    s = string.gsub(s, "&lt;", "<")
    s = string.gsub(s, "&gt;", ">")
    s = string.gsub(s, "&quot;", "\"")
    s = string.gsub(s, "&#39;", "'")
    s = string.gsub(s, "&amp;", "&")
    return s
end

function doc_markdown.gnuplot_safe_string(s)
    if s == nil then
        return ""
    end
    s = tostring(s)
    s = string.gsub(s, "[\"\\]", "")
    s = string.gsub(s, "[\r\n]", " ")
    return s
end

function doc_markdown.plot_spec_to_gnuplot_cfg(spec)
    if spec == nil or type(spec) != "table" then
        return nil, "plot spec must be a JSON object"
    end
    if spec.series == nil or type(spec.series) != "table" or #spec.series == 0 then
        return nil, "plot spec needs a non-empty \"series\" array"
    end

    default_with = PLOT_TYPE_TO_WITH[spec.type]
    if default_with == nil then
        default_with = "linespoints"
    end

    data = {}
    for i, series in ipairs(spec.series) do
        if series.x == nil or type(series.x) != "table" or series.y == nil or type(series.y) != "table" then
            return nil, "series " .. tostring(i) .. " needs \"x\" and \"y\" arrays"
        end
        if #series.x != #series.y then
            return nil, "series " .. tostring(i) .. "'s \"x\" and \"y\" arrays must be the same length"
        end
        for j = 1, #series.x do
            if type(series.x[j]) != "number" or type(series.y[j]) != "number" then
                return nil, "series " .. tostring(i) .. "'s \"x\"/\"y\" values must all be numbers"
            end
        end

        series_with = default_with
        if series.with != nil then
            if type(series.with) != "string" or ALLOWED_SERIES_WITH[series.with] == nil then
                return nil, "series " .. tostring(i) .. " has unsupported \"with\" style (allowed: lines, points, linespoints, boxes, impulses, steps)"
            end
            series_with = ALLOWED_SERIES_WITH[series.with]
        end
        series_title = "series " .. tostring(i)
        if series.name != nil then
            series_title = doc_markdown.gnuplot_safe_string(series.name)
        end
        table.insert(data, {{series.x, series.y}, with = series_with, title = series_title})
    end

    cfg = {type = "svg", width = 640, height = 400, grid = true, data = data}
    if spec.title != nil then
        cfg.title = doc_markdown.gnuplot_safe_string(spec.title)
    end
    if spec.xlabel != nil then
        cfg.xlabel = doc_markdown.gnuplot_safe_string(spec.xlabel)
    end
    if spec.ylabel != nil then
        cfg.ylabel = doc_markdown.gnuplot_safe_string(spec.ylabel)
    end

    return cfg, nil
end

function doc_markdown.render_plot(spec_text)
    spec, _, decode_err = json.decode(spec_text)
    if spec == nil then
        return "<div class=\"platform-plot platform-plot-error\">Could not render plot: invalid JSON.</div>"
    end

    cfg, cfg_err = doc_markdown.plot_spec_to_gnuplot_cfg(spec)
    if cfg == nil then
        safe_err = string.gsub(tostring(cfg_err), "&", "&amp;")
        safe_err = string.gsub(safe_err, "<", "&lt;")
        safe_err = string.gsub(safe_err, ">", "&gt;")
        return "<div class=\"platform-plot platform-plot-error\">Could not render plot: " .. safe_err .. ".</div>"
    end

    plot = gnuplot.create(cfg)
    out_path = os.tmpname()
    ok, gnuplot_output, script_path = gnuplot.savefig(plot, out_path)
    if gnuplot.cleanup != nil then
        gnuplot.cleanup(plot)
    end
    if script_path != nil then
        os.remove(script_path)
    end
    if ok != true then
        os.remove(out_path)
        return "<div class=\"platform-plot platform-plot-error\">Could not render plot: gnuplot failed.</div>"
    end

    file = io.open(out_path, "r")
    if file == nil then
        os.remove(out_path)
        return "<div class=\"platform-plot platform-plot-error\">Could not render plot: no output produced.</div>"
    end
    svg = io.read(file, "*all")
    io.close(file)
    os.remove(out_path)
    if svg == nil or string.find(svg, "<svg", 1, true) == nil then
        return "<div class=\"platform-plot platform-plot-error\">Could not render plot: no output produced.</div>"
    end

    return "<div class=\"platform-plot\">" .. svg .. "</div>"
end

function doc_markdown.render_plot_fences(html)
    return (string.gsub(html, "<pre><code class=\"language%-plot\">(.-)</code></pre>", function(escaped_json)
        return doc_markdown.render_plot(doc_markdown.html_unescape(escaped_json))
    end))
end

function doc_markdown.render_markdown(content)
    if content == nil or content == "" then
        return ""
    end
    return doc_markdown.render_plot_fences(markdown_lib.render(content))
end

function doc_markdown.render_html(db_path, content)
    if content == nil or content == "" then
        return ""
    end
    html = doc_markdown.render_markdown(doc_markdown.inline_links_to_markdown(db_path, tag.inline_text_tags(db_path, content)))
    html, _ = string.gsub(html, "<a href=\"detail%?type=tag&amp;entity_id=", "<a class=\"platform-tag-chip\" href=\"detail?type=tag&amp;entity_id=")
    return html
end

function doc_markdown.extract_attachment_text(filename, data)
    if filename == nil then
        return nil, "No filename given."
    end
    extension_match = string.match(filename, "%.([^.]+)$")
    extension = ""
    if extension_match != nil then
        extension = string.lower(extension_match)
    end
    if extension != "pdf" and extension != "docx" then
        return nil, "Unsupported file type -- only PDF and .docx are supported right now."
    end

    binary = "pandoc"
    if extension == "pdf" then
        binary = "pdftotext"
    end
    if external_tool.available(binary) == false then
        return nil, binary .. " is not installed on this deployment."
    end

    text, _ = external_tool.with_temp_file(data, "wb", function(tmp_path)
        if extension == "pdf" then
            return external_tool.capture("pdftotext " .. external_tool.shell_quote(tmp_path) .. " - 2>/dev/null")
        end
        return external_tool.capture("pandoc -f docx -t plain " .. external_tool.shell_quote(tmp_path) .. " 2>/dev/null")
    end)

    if text == nil then
        return nil, "Could not extract text from this file."
    end
    if string.len(text) > ATTACHMENT_TEXT_MAX_CHARS then
        text = string.sub(text, 1, ATTACHMENT_TEXT_MAX_CHARS) ..
            "\n\n[...truncated, showing the first " .. tostring(ATTACHMENT_TEXT_MAX_CHARS) .. " characters...]"
    end
    return text
end

return doc_markdown
