# Agent tool: plotting via gnuplot -- DONE

Lets the chat agent (and anyone hand-writing a document) render real charts -- line, scatter, bar -- from numeric data, in both documents and chat, without vendoring any client-side library.

## Design

**A deployment dependency, not a vendored one.** `gnuplot-nox` is installed via apt in `lims/Dockerfile`, right alongside `cmark-gfm` -- a real system binary shelled out to at render time, never checked into git. `-nox` since this is a headless server with no need for gnuplot's X11 GUI terminals. This was an explicit redirect away from an earlier plan to vendor `mermaid.js` (see [doc/agent-mermaid-diagrams.md](agent-mermaid-diagrams.md)): no new git weight, no client-side JS/rescan-timing complexity.

**Reuses `gnuplot.lua`, doesn't reimplement it.** A wrapper around the `gnuplot` CLI already existed in luam's shared `lib/gnuplot.lua`, bundled into the daat binary as a side effect of luam's build but never `require`d by any daat source file until now -- `src/document.lua` requires it directly (`gnuplot = require("gnuplot")`), no file-copying needed since it's already in the same flat build namespace. `gnuplot.create(cfg)` / `gnuplot.savefig(plot, output_path)` handles the actual shell-out (via `utils.exec_command`, not raw `os.execute`) and SVG generation.

**The agent never writes raw gnuplot script.** gnuplot's own scripting language can shell out (`system(...)`, `load`) -- letting model-generated text reach a real `gnuplot` process as literal script would be a real RCE surface. Instead, a fenced ` ```plot ` block holds a small, constrained JSON data spec:

```json
{
  "type": "line",
  "title": "Cacao suspension growth",
  "xlabel": "Day",
  "ylabel": "Biomass (g/L)",
  "series": [
    {"name": "Run A", "x": [1, 2, 3, 4, 5], "y": [0.5, 1.1, 2.3, 3.8, 5.2]}
  ]
}
```

`type` is `"line"` (default), `"scatter"`, or `"bar"` -- mapped to gnuplot's `with linespoints`/`points`/`boxes`. `series` is required, at least one entry, each needing `x`/`y` number arrays of equal length (no strings, no dates, no nulls -- rejected outright if not). `title`/`xlabel`/`ylabel`/series `name` are optional. `agent.default_system_prompt` (`src/agent.lua`) documents this exact shape, since there's no tool-call JSON Schema to teach the model the format the way `AGENT_TOOLS` entries normally would -- this is the only place it's learned.

`document.plot_spec_to_gnuplot_cfg` (`src/document.lua`, pure, no I/O) is the only code that turns spec JSON into a `gnuplot.create(cfg)` table. Every string that ends up interpolated into a generated `set title "..."`/`t "..."` gnuplot command goes through `document.gnuplot_safe_string` first -- `gnuplot.lua`'s own `generate_code` does naive, unescaped `"`-quoting, so an attacker-controlled title containing a literal `"` could otherwise break out of the string literal and inject arbitrary gnuplot commands (including a `system()` call). `gnuplot_safe_string` strips `"` and `\` and collapses newlines, closing that off without needing to touch the shared luam wrapper.

**One shared rendering hook.** Both documents (`document.render_html`) and chat (`chat_widget_state`) bottom out in `document.render_markdown` (`src/document.lua`). `document.render_plot_fences` post-processes cmark-gfm's own output there: it regex-matches the exact `<pre><code class="language-plot">...</code></pre>` shape cmark-gfm emits for a fenced ```` ```plot ```` block, HTML-unescapes the captured text (`document.html_unescape`, the reverse of cmark's own entity escaping), JSON-decodes it, translates and renders via `document.render_plot`, and swaps in a `<div class="platform-plot">` holding the raw SVG. Any failure along the way (bad JSON, a rejected spec, a gnuplot error, no output produced) renders a plain, visible `<div class="platform-plot-error">` message in place instead of throwing and taking down the rest of the page.

**CSS**: `.platform-plot { overflow-x: auto; }` (`html.plot_css()`, shared by the document view and the chat widget's own stylesheet) -- a plot is a fixed-size SVG (gnuplot's own `width`/`height`, 640x400 by default), and the narrowest surface it can render into is the ~280px chat panel, so an oversized plot scrolls in its own box rather than the page or panel scrolling sideways.

**Hand-written fences need no `AGENT_TOOLS` entry.** `document.create`/`document.update` already let the agent write a fence directly into a document, and a chat reply is just generated text run through the same `render_markdown` path -- no separate "create a diagram" capability is needed beyond the model knowing the fence syntax (from the system prompt) and the rendering hook existing. `plot.from_query` (below) is the one exception, added for a different reason than capability -- reliability.

## `plot.from_query`: closing the transcription-error failure mode

Confirmed live (task: an "active samples over time" chart) that hand-written fences fail in a specific, repeatable way once the data comes from a query: the model calls `entity.query`, gets back a pipe-delimited text table, and has to visually parse that table and retype it into `x`/`y` arrays -- multi-row numeric transcription by eye, which LLMs are structurally unreliable at regardless of prompting. Two real failures on the same request: a miscounted array (`x`/`y` length mismatch, correctly rejected by `plot_spec_to_gnuplot_cfg`) and, on retry, an attempt to hand-compute day-offsets from date strings turn by turn.

`plot.from_query` (`src/agent.lua` `AGENT_TOOLS.plot.from_query`, non-destructive) removes the transcription step instead of asking the model to do it more carefully. It takes `{sql, x_column, y_column, series_name?, type?, title?, xlabel?, ylabel?}`, runs the query through `view.run_agent_query` (the same capped, read-only, registered-tables-only path `entity.query` already uses), and -- in trusted Lua, not the model -- walks the row objects straight into a `{"series":[{"x":[...],"y":[...]}]}` table. It validates through `document.plot_spec_to_gnuplot_cfg` (the same check the fence renderer runs at reply-render time) before returning, so a missing column or a non-numeric value comes back as a clear tool error the model can react to (try a different column, fix the query) rather than a broken chart the model only discovers after the reply is already sent. On success it `json.encode`s the spec and returns it as literal ` ```plot ` fence text -- the model's only remaining job is to paste that text into its reply verbatim.

Deliberately returns fence *text*, not a rendered SVG -- reuses `document.render_plot_fences` (the exact hook a hand-written fence already goes through) instead of adding a second rendering path. This also sidesteps a real constraint: tool-result messages are shown as escaped plain text, not run through `render_markdown` (`html.CHAT_MARKDOWN_ROLES` only covers `assistant`/`self_check`/`compaction_summary`), so a tool result could never render its own SVG directly even if it tried.

Scoped to one series per call deliberately -- every real request so far has been a single series from a single query; a `series_column`-style pivot into multiple series was left out rather than built ahead of a demonstrated need.

## Known limitation

Covers real data plots only (line/scatter/bar), not conceptual diagrams (flowcharts, ER diagrams, sequence diagrams) -- Mermaid would have covered both; this doesn't. Deliberate, matching the explicit "at least for now, we'll see if we need more later" scoping this was built to. See [doc/agent-mermaid-diagrams.md](agent-mermaid-diagrams.md) for where to pick that back up if a real diagramming need shows up.

`type: "bar"` renders via gnuplot's plain `with boxes` -- no fill styling (`set style fill solid`/`boxwidth`), since `gnuplot.lua`'s `generate_code` has no escape hatch for extra `set` commands today and this is a visual-polish gap, not a functional one. Bars render as unfilled outlines rather than solid blocks.

## Verification

- Unit tests (`tst/unit/document.lua`): `document.html_unescape` (including the ordering-dependent case -- a literal `&amp;lt;` must reverse to the literal text `&lt;`, not `<`), `document.gnuplot_safe_string`, and `document.plot_spec_to_gnuplot_cfg` (valid specs, the `type`-to-`with` mapping, label sanitization, and every rejection path: missing series, mismatched x/y lengths, non-numeric values, a non-table spec).
- Integration test (`tst/integration/document.bats`): a real `/api/document-preview` round-trip with a ` ```plot ` fence, asserting the served HTML contains real `<svg` markup (hits the actual `gnuplot` shell-out, not a mock) and that a malformed spec renders a visible `platform-plot-error` instead of a 500.
- `gnuplot-nox` installed locally before running `./bld/test.sh`, so the integration test exercises the real binary the way the Dockerfile will.
- Integration tests (`tst/integration/agent.bats`) for `plot.from_query`: a real query's rows turn into a correct fence (asserting `x`/`y` arrays and `title` independently, order-agnostic since `dkjson.encode` doesn't guarantee key order), plus the two rejection paths (unknown column, non-numeric column) both surface a clear `is_error:true` tool result.
