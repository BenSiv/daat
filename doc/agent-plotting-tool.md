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

**No new `AGENT_TOOLS` entry.** `document.create`/`document.update` already let the agent write a fence directly into a document, and a chat reply is just generated text run through the same `render_markdown` path -- there's no separate "create a diagram" capability needed beyond the model knowing the fence syntax (from the system prompt) and the rendering hook existing.

## Known limitation

Covers real data plots only (line/scatter/bar), not conceptual diagrams (flowcharts, ER diagrams, sequence diagrams) -- Mermaid would have covered both; this doesn't. Deliberate, matching the explicit "at least for now, we'll see if we need more later" scoping this was built to. See [doc/agent-mermaid-diagrams.md](agent-mermaid-diagrams.md) for where to pick that back up if a real diagramming need shows up.

`type: "bar"` renders via gnuplot's plain `with boxes` -- no fill styling (`set style fill solid`/`boxwidth`), since `gnuplot.lua`'s `generate_code` has no escape hatch for extra `set` commands today and this is a visual-polish gap, not a functional one. Bars render as unfilled outlines rather than solid blocks.

## Verification

- Unit tests (`tst/unit/document.lua`): `document.html_unescape` (including the ordering-dependent case -- a literal `&amp;lt;` must reverse to the literal text `&lt;`, not `<`), `document.gnuplot_safe_string`, and `document.plot_spec_to_gnuplot_cfg` (valid specs, the `type`-to-`with` mapping, label sanitization, and every rejection path: missing series, mismatched x/y lengths, non-numeric values, a non-table spec).
- Integration test (`tst/integration/document.bats`): a real `/api/document-preview` round-trip with a ` ```plot ` fence, asserting the served HTML contains real `<svg` markup (hits the actual `gnuplot` shell-out, not a mock) and that a malformed spec renders a visible `platform-plot-error` instead of a 500.
- `gnuplot-nox` installed locally before running `./bld/test.sh`, so the integration test exercises the real binary the way the Dockerfile will.
