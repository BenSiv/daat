# 006. Separate Vocabularies for Trusted Pages, Extension Canvas & Document Templates

- **Date:** 2026-11-27
- **Status:** Accepted

## Context & Real Need

`daat` renders three kinds of structured layouts without an external template language ([why-luam.md](../why-luam.md)): first-party application pages (`src/page.lua`), deployment-authored Extension pages at `/ext/<name>` (`ui.validate_canvas` / `ui.render_canvas` in `src/ui/common.lua`), and reusable Document starter layouts at `/templates` (`src/template.lua`). All three follow the same mechanical pattern — validate a typed Luam table, then dispatch by element `type` to a string renderer.

Unifying them into one shared component vocabulary creates an immediate security and scope trap: first-party pages require arbitrary `<form action=... method=...>`, `password`/`file`/`hidden` inputs, `secret_reveal` banners, inline `style` overrides (`actions.style`), and pre-rendered `html_fragment` table cells (for `/sql` reference popovers). Handing any of those capabilities to untrusted deployment Extensions would defeat the `/ext/<name>` XSS/CSRF containment boundary, whereas restricting core pages to the Extension canvas's 5 safe primitives would cripple first-party UI development.

## Decision

1. **Three deliberately separate modules and closed vocabularies ([templating.md](../templating.md)):**
   - **`src/page.lua` (trusted first-party HTML sections):** Covers recurring server-rendered page structure (`subheading`, `message`, `secret_reveal`, `form` with `fields` + `groups`, `table` nesting plain strings/`form`/`html_fragment`, `actions` with escaped `data-*` attributes, and `status_placeholder`) rendered via `luam/lib/render.lua` (`{{ }}` escaped, `{{{ }}}` raw). Because only first-party `src/ui/*.lua` code calls `page.lua`, validation errors represent programmer bugs and call `error()` immediately.
   - **`ui.validate_canvas` / `ui.render_canvas` (`src/ui/common.lua`, untrusted Extension trust boundary):** Restricts `capabilities.ui` `/ext/<name>` pages to 5 inert element types (`heading`, `text`, `table` of escaped strings, `button` emitting `data-action` + JSON `data-args` posted by `src/ui/canvas.js`, and text `input` emitting `data-input-name`). Extensions can never emit raw HTML, inline scripts, arbitrary form URLs, or event attributes; validation failures return `nil, err` and render inside an escaped error banner.
   - **`src/template.lua` (inert Document Markdown snippets):** Loads `templates/<name>.lua` inside `sandbox.data_env()` and renders 4 Markdown section types (`heading`, `text`, `registration_table`, `lookup_view`) into plain copyable Markdown text. Because templates perform zero database writes and emit no raw HTML, they require no `system_approval` workflow.
2. **Client interactivity via standalone `.rodata` assets & JSON boot islands (`src/ui/*`):** Live client behavior (Toast UI Document editing, `/knowledge-graph` canvas physics, `/data` SVG relation diagram, floating `chat_widget`, batch `/register` grid) lives in pure `.js`/`.css`/`.html` files loaded via literal `asset.read("ui/...")` (compiled into `_bundled_assets` at build time and checked by `node --check` in `./bld/test.sh`). Server state crosses to JS exclusively through `html.json_for_script`-escaped `<script type="application/json">` boot tags or `data-*` attributes — never string-interpolated JS source.

## Deliberate Tradeoffs & Not in Scope

- **Accepted cost:** Three small `validate` + `render` dispatchers exist in parallel rather than one shared renderer, and Extension `/ext/<name>` UIs are intentionally limited to simple data tables, text inputs, and action triggers.
- **Not in scope:** Sharing or aliasing element types across `page.lua`, `ui.render_canvas`, and `template.lua`; allowing raw HTML/JS or custom CSS in Extension `capabilities.ui`; forcing one-off client-rendered widgets (`chat_widget`, `knowledge_graph`, `/register`'s JS-built grid body) into `page.lua`; introducing an external JS bundler/transpiler.
- **Revisit trigger:** Add a new section/element type to *one* of the three modules only when a real page/Extension/template in that exact trust tier has a recurring structural shape (never speculatively, and never because one of the other two modules added it).

## Verification

- `./bld/test.sh` (`tst/unit/page.lua`, `tst/unit/template.lua`, `tst/integration/extension.bats`, and `node --check` across `src/**/*.js`)
- Conventions & gotchas: [templating.md](../templating.md)
