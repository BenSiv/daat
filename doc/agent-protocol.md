# The Agent Provider Protocol

The chat agent's tool-calling logic (`agent.lua`'s `run_turn`, destructive-action
pause/resume, history building, tool dispatch) is written against one
neutral, internal protocol -- not any one model vendor's wire format.
`agent_provider_<name>.lua` implementations (`vertex`, `claude`, `test`, and
any added later) are equal, symmetric translators between this protocol and
their own vendor's real API. None of them defines the protocol; `agent.lua`
does, and no provider adapter gets to be "home" while others are guests
translating into its shape.

This wasn't always true. `AGENT_TOOLS`' tool-parameter schemas used to be
authored directly in Vertex/Gemini's own uppercase proto-enum convention
(`"OBJECT"`/`"STRING"`/`"INTEGER"`), with zero translation layer in
`agent_provider_vertex.lua` -- Vertex was silently privileged, and adding a
second provider meant either duplicating that dialect or reverse-engineering
which parts of the "shared" shape were actually vendor-specific. Fixed by
making the schema convention genuinely neutral (see below) and giving Vertex
its own explicit translation step, the same as every other provider.

## The provider interface

```lua
provider.generate(model, system_prompt, prompt) -> (text, err)
provider.converse(model, system_prompt, messages, tools) -> (response, err, usage)
provider.embeddings(model, text) -> (vector, err)  -- optional
```

Loaded dynamically by name (`config.platform_config().agent_provider`,
default `"vertex"`) via `agent_provider.lua`, so switching providers -- or
swapping in the deterministic `test` provider for repeatable, cost-free test
runs -- is a config change, not a code change.

## Messages

`messages` passed to `.converse()` is a list of `{role, content}` entries,
built by `agent.lua`'s own `build_history_messages`:

| `role` | `content` |
|---|---|
| `user` | a plain string |
| `assistant` | a list of content blocks (below) |
| `toolResult` | a single-element list, `{text = ..., }`, plus `toolCallId`/`toolName`/`isError` on the message itself |

## Content blocks

A `.converse()` response is `{content = [...blocks...], stopReason, errorMessage}`.
Each block is one of:

| `type` | shape | meaning |
|---|---|---|
| `text` | `{type="text", text=...}` | ordinary reply text |
| `toolCall` | `{type="toolCall", id=..., name=..., arguments=...}` | the model wants to call `name` (a dotted `"tool.method"` string matching an `AGENT_TOOLS` entry) with `arguments` |
| `thinking` | `{type="thinking", thinking=..., thinking_signature=...}` | reasoning content, shown inline in `/chat` and fed into the Knowledge Pool reasoning-document pipeline (`thinking_signature` is optional, provider-specific continuity data round-tripped opaquely, never inspected by `agent.lua`) |

`id` on a `toolCall` block only needs to be unique within one turn/response
for `agent.lua`'s own tool-result correlation -- a provider whose wire
protocol has no real call-id concept (Vertex) synthesizes one; a provider
whose wire protocol already has a real, stable id (Claude's `toolu_...`)
should use it directly rather than inventing a second one.

## `stopReason`

| value | meaning |
|---|---|
| `stop` | a complete, final answer |
| `toolUse` | one or more `toolCall` blocks need dispatching |
| `length` | cut off by a token/length limit -- treated as a proposed answer, same as `stop` |
| `error` | a real response came back, but not a usable completed turn (safety refusal, empty content, an unrecognized stop condition) -- `errorMessage` explains why |
| `aborted` | the call was cancelled before completing |

`nil, err` (not a `response` table at all) is reserved for a genuine
connectivity/auth-level failure -- the call itself couldn't be completed, so
there's nothing structured to return.

## Tool parameter schema

`AGENT_TOOLS`' `parameters` (`agent.lua`) is plain, standard JSON Schema --
lowercase `type` (`"object"`/`"string"`/`"integer"`/`"number"`/`"boolean"`/`"array"`),
standard `properties`/`required`/`items`. This is the real, vendor-neutral
spec, not any one vendor's dialect -- picked because it already exists as an
independent standard, and because it happens to need zero translation for
some providers (Claude's own `input_schema` is already exactly this) while
needing an explicit, visible translation step for others (Vertex's real API
requires the uppercase proto enum instead -- see
`agent_provider_vertex.lua`'s own `vertex_schema_from_canonical`).

A provider whose native schema convention differs from this is expected to
translate in its own file, the same way `vertex_schema_from_canonical`/
`vertex_tools_from_canonical` do -- `agent.lua` never learns any vendor's
convention, and no provider adapter mutates or reads another's translation
code.

## Server-executed ("built-in") tools are deliberately out of scope

Some vendors offer tools they execute themselves (Anthropic's `web_search`,
`code_execution`, etc.) -- these run before the provider adapter (or
`agent.lua`) ever sees them, which means they can't be gated by the
pending-approval flow every destructive `AGENT_TOOLS` entry already goes
through (`agent.create_pending_action`). A capability like web search, if
added, belongs in `AGENT_TOOLS` as an ordinary custom tool backed by our own
API call inside `agent.execute_tool` -- going through the same approval gate
as `entity.create`/`document.create` -- not as a vendor's server-executed
tool. No provider adapter should declare one of these on the wire.

## Adding a new provider

1. Write `agent_provider_<name>.lua` implementing `.generate`/`.converse`
   (and `.embeddings` if the vendor has one).
2. Translate `messages`/`tools` from the canonical shape above into the
   vendor's real wire format, and the vendor's response back into canonical
   blocks/`stopReason` -- entirely within that one file.
3. No changes needed to `agent.lua`, `cgi.lua`, or the existing test suite
   (`agent_provider_test.lua`'s scripted fixtures already use this canonical
   shape directly).
4. Set `config.platform_config().agent_provider` to `"<name>"` to switch.
