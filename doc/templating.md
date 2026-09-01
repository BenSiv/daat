# Templating in html.lua

`html.lua` builds CSS/markup as literal string fragments -- no external template engine, per `doc/why-luam.md`'s "one language" reasoning (Lua itself, building strings with `table.concat`/`..`, already does loops/conditionals; a template language doesn't need to). Two small first-party mechanisms exist for the parts that recur often enough to be worth naming, and this doc is the convention for using them, not a proposal to replace either.

## `{{ }}` vs `{{{ }}}` (`render.lua`)

`render.render(template_str, ctx)` does `{{ expr }}` (HTML-escaped) / `{{{ expr }}}` (raw) interpolation against a context table, with dotted-path lookup (`{{{ layout.gutter }}}` reads `ctx.layout.gutter`). No loops or conditionals -- that's deliberate, see its own header.

- Use `{{ }}` for anything that could contain user-authored text ending up in HTML content -- it's the auto-escape that makes "forgot to call `html.html_escape`" impossible by construction instead of convention-dependent.
- Use `{{{ }}}` for trusted, code-controlled values that are never user text -- numeric layout constants, CSS/markup fragments you're deliberately composing raw. HTML-escaping a pixel count is harmless but pointless; HTML-escaping an already-rendered partial (see below) would double-escape it, which is why composition uses `{{{ }}}` deliberately, not `{{ }}` by default.
- **Migrating a `string.format`-built block**: any literal `%%` that existed only to survive `string.format`'s own escaping (e.g. `calc(100%% - ...)`) must become a single `%` once the block moves to `render.render` -- `string.gsub`-based interpolation has no `%%` escaping convention of its own. Check this in both the CSS itself and any `/* ... */` comment text inside the same string -- a comment sitting inside a converted block goes through `render.render` too.

## Shared layout tokens (`PLATFORM_LAYOUT`)

Numeric constants used by more than one CSS-building function (nav width, gutter, ...) live in one table, `PLATFORM_LAYOUT`, passed as `render.render`'s context (`{layout = PLATFORM_LAYOUT}`) rather than threaded as positional `string.format` arguments. The bug class this replaces: a shared value threaded into a multi-argument `string.format` call by *position* is one transposition away from silently rendering the wrong number, with no error -- named placeholders make that mistake structurally harder (each one says which value it wants) instead of relying on a human counting argument order correctly. A derived value used verbatim in the template (e.g. `gutter_x2 = PLATFORM_GUTTER * 2`) should be precomputed as its own field on the context table, not written as repeated arithmetic in the template string, so migrating a block stays an exact, verifiable byte-for-byte refactor of its rendered output.

**Ordering gotcha, real and already hit once:** `PLATFORM_LAYOUT` (and the raw constants it reads) must be defined *before*, textually, every function that closes over it. Luam's implicit-local assignment (`x = ...` at chunk scope, no `local` keyword needed) still follows real Lua scoping: a local's scope begins strictly after its own declaration. A function defined earlier in the same file that references a name assigned later doesn't see a forward reference to that later local -- it silently resolves to an unset global instead, so the table it builds looks fine at a glance but its fields are `nil`, and the failure only surfaces at render time (`render: "layout.gutter" not found in context`), not at parse/build time. Define constants and any table built from them in one place, before the functions that use them, not interleaved.

## Composing partials

Render an inner fragment to a string first, then embed the *result* into an outer template as a raw `{{{ }}}` value -- this already works with no changes needed, it's just a convention worth naming: it's how a "layout" and the pieces inside it stay two separate, independently-testable `render.render` calls instead of one large one.

## What this doesn't cover (yet)

Business-logic-heavy page content (entity tables, forms) still builds its markup by direct string concatenation, not `render.render` -- migrating that is a separate, larger effort (see the brex backlog), deliberately out of scope for the first slice this doc describes (the shared shell/CSS layer: `platform_container_css`, `platform_nav_css`, `platform_chat_widget_css`), which existed specifically to fix a proven, repeated drift bug in that one cluster.
