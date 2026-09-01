# A more comprehensive plugin system: decided direction

Originated as research against brex task 737181736, prompted by a real gap hit while building brex #53 (chat attachments): the extension system had no hook for what that feature needed, so it landed as a config-gated core feature instead. That research laid out three options; the decision is now made:

**Build it.** Two real precedents (below) are treated as sufficient signal -- more are expected, not fewer -- and the direction covers both halves: a UI plugin surface (routes + sidebar nav) and an agent-tools plugin surface, both built the same way daat builds everything modular, as a first-class extension capability rather than one-off config flags. Multi-tenancy is explicitly out of scope: a daat deployment is one org's own install, not several tenants sharing one instance, so "which plugins are enabled" is just deployment config, nothing more.

## Current state: entity-lifecycle hooks only

`doc/extensibility.md` documents the shape precisely: an extension is `manifest.lua` + `main.lua` under `extensions/<name>/`, declaring `events` (`entity.before_create`/`before_update`/`after_create`/`after_update`/`after_archive`), `entity_types`, and `capabilities` (`read`/`write` scoped to `entity`, plus `net = "outbound"`). It needs explicit admin approval before any hook runs, and a capability change invalidates that approval until re-reviewed.

The sandboxing mechanism (`sandbox.lua`, shared infrastructure in `../luam/lib/`) is genuinely minimal: `loadstring` + `setfenv` against a restricted environment (`pairs`/`ipairs`/`string`/`table`/`math`/`pcall`/`error` -- no `io`, no `os`, no `require` unless a capability explicitly adds one, e.g. `socket` for `net=outbound`). The real trust boundary isn't the sandbox's own restrictions so much as `entity.lua`'s `build_ctx` (`src/entity.lua:45-99`): a plain table of closures (`ctx.query`, `ctx.create_entity`, `ctx.update_entity`), each checking the manifest's declared capability before ever touching the real, trusted `entity.create`/`entity.update`/`db.query`. A hook body only ever sees `ctx`, never the real functions directly.

## The gap, and it's not hypothetical -- two real cases, more expected

**#53 (chat attachments)** needed a new route (`/api/chat-widget-attach`) and a new capability (shelling out to `pdftotext`/`pandoc`). Neither fits any existing hook. It landed as `config.platform_config().chat_attachments_enabled` (default off) -- the same pattern `agent_provider`/`db_backend` already use.

**`web_search.lua`** is a second case: a single hardcoded Google Custom Search integration, with its own header comment stating "There's exactly one search backend today, so this is a plain module, not a swappable-provider abstraction." A deployment wanting Bing, or an internal search API, has no seam to plug into -- forking `web_search.lua` is the only option today. *(Update: this exact gap was closed by generalizing `agent_provider.lua`'s own facade pattern into a named third tier -- see doc/architecture.md's "Providers" section -- and migrating search onto it as `search_provider.lua` + `src/provider/search_google_cse.lua`. Read as historical -- the gap described here motivated fixing itself.)*

Both are the same shape: a capability a specific deployment wants, not universal enough for core, with no extension point to land in. The decision here is that this pattern will keep recurring -- worth building the seam once, properly, rather than adding a fourth and fifth config flag later.

## Two plugin surfaces, built the same way

### UI plugins: canvas, not raw HTML

The original sketch of this (a `ctx.render(template, data)` using `render.lua`'s auto-escaping templater) is **superseded** by a stricter, better idea: no plugin ever passes HTML/a template string at all. Instead, a plugin's UI is a plain Lua table describing a page as a tree of *predefined elements* -- a fixed, curated vocabulary daat itself defines and renders, the same relationship Benchling's own Canvas apps have to Benchling's UI (an app declares blocks from Benchling's own catalog; Benchling's frontend renders them; the app never ships its own markup/CSS/JS).

**This pattern already exists in this codebase**, just aimed at Markdown instead of live HTML: `template.lua`'s entry templates. `template.validate` (`src/template.lua:65-90`) checks each `section.type` against a known vocabulary (`heading`, `text`, `registration_table`, `lookup_view`) and that type's required fields; `template.render` (`:152-165`) dispatches per type to a dedicated render function (`render_registration_table`, `render_lookup_view`). A template file is loaded through `sandbox.run(source, path, sandbox.data_env())` -- pure declarative data, not executable hook logic, so it needs no capability grants at all today.

"daat canvas" is the same pattern, aimed at a live page instead of a pasteable snippet:

- A plugin's route hook returns a plain Lua table -- `{elements = {{type="heading", text="..."}, {type="table", columns={...}, rows={...}}, {type="button", label="Run", action="my_plugin.do_thing"}, ...}}` -- never a string of markup.
- A new, trusted `html.render_canvas(elements)` (living in `html.lua` alongside its other `render_*` functions, not sandboxed code) is the only thing that turns element tables into real HTML, the same way `template.render`/`render_registration_table`/`render_lookup_view` are the only things that turn template sections into Markdown today. `html.validate_canvas`-style checking on load mirrors `template.validate`.
- Initial element vocabulary should stay small and demand-driven, not try to be a general UI framework: heading, text, a data table (real rows, not just a link), a list, a form/input set, a button tied to a named action. Grow it when a real plugin needs a new element, the same way `template.lua`'s own vocabulary grew by four types over time, not by speculatively covering every conceivable widget up front.
- **Actions round-trip through the same capability-gated path entity hooks already use.** A button's `action` is a name, not code -- clicking it posts back to a dispatch endpoint that loads the plugin's approved manifest, builds a `ctx` scoped to its declared capabilities (exactly `build_ctx`'s existing shape), and calls the named handler. The plugin never gets a live event loop or arbitrary client-side code, only "this named, capability-checked thing happened."
- **Nav integration is nearly free.** `html.page_shell`'s `nav_items` (`src/html.lua:955-975`) is already exactly the shape a plugin nav entry needs: a plain ordered array of `{key, href, label, icon}`, built once per request from a few `if` checks. Appending approved-extension-declared entries to that same array, in the same loop that already renders it, is a small addition. This overlaps directly with brex 683042859 (configurable nav order/visibility) -- both want "the nav rail is an ordered, filterable list from more than one source," so the same underlying mechanism serves both.

### Agent tools: a plugin-contributed tools library

Same shape as the UI surface, different catalog: a manifest declares `tools = {{name = "...", description = "...", parameters = <JSON Schema>, capability = ...}}`. The tool's handler is sandboxed Lua, invoked through the same `ctx` pattern -- when the model calls the tool, `agent.execute_tool`'s dispatch (`src/agent.lua`) resolves it against approved extensions' declared tools the same way it resolves `AGENT_TOOLS`' own built-in entries today, and the handler body only ever sees a capability-checked `ctx`, never `agent.lua`'s internals directly. This is exactly what #53 could have been instead of a core route: a `document.extract_attachment_text`-shaped capability, contributed by an extension, not hardcoded into `agent.lua`'s own tool table.

Both surfaces (UI and tools) share one underlying idea -- a new, narrow capability type per surface, approved and sandboxed the same way `read.entity`/`write.entity` already are -- and neither depends on the other; they can land in either order.

## What's still open

- **Approval UX for something riskier than an entity hook.** A route serving a real page, or a tool the agent can call mid-conversation, is a bigger surface than "check a capability before touching one table." The existing approval/re-approval-on-capability-change flow is a reasonable starting point but may need a stronger review step once a plugin can put a canvas page or a tool in front of every user, not just mutate rows an admin already scoped by entity type.
- **Canvas element vocabulary v1.** Needs an actual first cut (heading/text/table/list/form/button feels like the right minimal set by analogy to `template.lua`'s own four section types, but hasn't been scoped against a real first plugin yet).
- **Dispatch/storage details** for both surfaces (where plugin-declared routes get matched in `cgi.lua`'s dispatch chain, how a tool-call's `ctx` differs from an entity-hook's `ctx`, how approval scopes to "this route" / "this tool" versus the whole extension) -- real implementation work, not yet designed here.

## References

- `doc/extensibility.md` -- current extension model, capabilities, "what extensions cannot do today."
- `doc/architecture.md` -- overall system shape, single-deployment model.
- `../luam/lib/sandbox.lua` -- the actual sandboxing mechanism (`base_env`, `sandbox.extension_env`, `sandbox.load`/`sandbox.run`).
- `src/entity.lua:45-99` (`build_ctx`) -- the capability-checked-closure pattern any new `ctx.*` addition should follow.
- `src/template.lua:65-165` -- the existing typed-section-table -> trusted-renderer pattern the UI canvas is modeled directly on.
- `src/html.lua:955-994` -- `nav_items`, the existing ordered-list shape a plugin nav entry would extend.
- brex `566638009`/#53 (chat attachments) and its own commit (daat `197806d`) -- the concrete gap that prompted this.
- brex `683042859` (nav bar configurability) -- the sibling task this overlaps with on the nav-integration side.
