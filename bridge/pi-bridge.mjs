#!/usr/bin/env node
// One-shot stdin/stdout JSON bridge between agent.lua and
// @earendil-works/pi-ai -- the real "harness in between the model and
// the platform" this project's own chat agent needed. Invoked as a
// fresh subprocess per turn (mirroring agent_provider_vertex.lua's own
// curl-shell-out pattern -- no daemon, no persistent state, matching
// platform-wip's per-request CGI architecture), reads one JSON request
// object from stdin, writes one JSON response object to stdout, exits.
//
// Request shape (a near-direct rendering of pi-ai's own Context):
//   {
//     "provider": "google-vertex",   // any pi-ai KnownProvider id
//     "model": "gemini-2.5-flash",
//     "systemPrompt": "...",          // optional
//     "messages": [
//       {"role": "user", "content": "..."},
//       {"role": "assistant", "content": [{"type":"text","text":"..."}]},
//       {"role": "assistant", "content": [{"type":"toolCall","id":"...","name":"...","arguments":{...}}]},
//       {"role": "toolResult", "toolCallId": "...", "toolName": "...", "content": [{"type":"text","text":"..."}], "isError": false}
//     ],
//     "tools": [{"name": "...", "description": "...", "parameters": {...JSON-Schema...}}]
//   }
//
// Response shape (mirrors pi-ai's own AssistantMessage):
//   {"content": [{"type":"text","text":"..."} | {"type":"toolCall",...} |
//                {"type":"thinking","thinking":"...","thinkingSignature":"..."}],
//    "stopReason": "stop" | "toolUse" | "length" | "error" | "aborted",
//    "errorMessage": "..." (only on stopReason "error"/"aborted"),
//    "usage": {"input":N, "output":N, "totalTokens":N}}
// A "thinking" block (Gemini 2.5's own thought-summary output, requested
// via google-vertex's own `thinking.enabled` option below) is real model
// output, not a wrapper convention -- note its text field is `thinking`,
// not `text`, matching pi-ai's own ThinkingContent type exactly.
//
// Never throws on a normal request failure (auth, rate limit, etc.) --
// pi-ai itself surfaces those as stopReason "error"/"aborted" on the
// returned message rather than an exception (confirmed directly against
// its own README's "Error Handling" section); this script mirrors that
// same contract, only exiting non-zero for a genuine bridge-level bug
// (malformed input, an uncaught exception), so agent_provider_pi.lua
// can treat "valid JSON came back" and "the call itself succeeded" as
// two separate, both-real possibilities.

// Narrow provider registration, not providers/all -- pulling in every
// built-in provider drags in every provider's own SDK dependency
// (Mistral, OpenAI, AWS/Bedrock, etc.) even though only Vertex is
// actually used today. Register providers here as real usage grows;
// this is the one place that changes to add another.
import { createModels } from "@earendil-works/pi-ai";
import { googleVertexProvider } from "@earendil-works/pi-ai/providers/google-vertex";

function buildModels() {
    const models = createModels();
    models.setProvider(googleVertexProvider());
    return models;
}

const now = () => Date.now();

function readStdin() {
    return new Promise((resolve, reject) => {
        let data = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", (chunk) => { data += chunk; });
        process.stdin.on("end", () => resolve(data));
        process.stdin.on("error", reject);
    });
}

// Rebuilds pi-ai's own Context.messages shape from the bridge request's
// (slightly simplified -- no timestamps required from the Lua side)
// message list, filling in the timestamp/isError/id fields pi-ai's own
// types require but agent.lua has no reason to track itself.
function toContextMessages(messages) {
    return (messages || []).map((m) => {
        if (m.role === "user") {
            return { role: "user", content: m.content, timestamp: now() };
        }
        if (m.role === "assistant") {
            return { role: "assistant", content: m.content, timestamp: now() };
        }
        if (m.role === "toolResult") {
            return {
                role: "toolResult",
                toolCallId: m.toolCallId,
                toolName: m.toolName,
                content: m.content,
                isError: m.isError === true,
                timestamp: now(),
            };
        }
        throw new Error(`unknown message role: ${m.role}`);
    });
}

function toResponsePayload(assistantMessage) {
    return {
        content: assistantMessage.content,
        stopReason: assistantMessage.stopReason,
        errorMessage: assistantMessage.errorMessage,
        usage: assistantMessage.usage
            ? {
                  input: assistantMessage.usage.input,
                  output: assistantMessage.usage.output,
                  totalTokens: assistantMessage.usage.totalTokens,
              }
            : undefined,
    };
}

async function main() {
    const raw = await readStdin();
    let request;
    try {
        request = JSON.parse(raw);
    } catch (e) {
        process.stdout.write(JSON.stringify({ content: [], stopReason: "error", errorMessage: `bridge: invalid JSON request: ${e.message}` }));
        process.exit(1);
    }

    const models = buildModels();
    const model = models.getModel(request.provider, request.model);
    if (!model) {
        process.stdout.write(JSON.stringify({ content: [], stopReason: "error", errorMessage: `bridge: unknown provider/model ${request.provider}/${request.model}` }));
        process.exit(1);
    }

    const context = {
        systemPrompt: request.systemPrompt || undefined,
        messages: toContextMessages(request.messages),
        tools: request.tools || [],
    };

    // Gemini 2.5's thought-summary feature (task: chat agent thinking
    // visibility) -- google-vertex-specific (GoogleVertexOptions.thinking,
    // confirmed against pi-ai's own source), so only passed for that
    // provider. No level/budgetTokens set: leaves the actual thinking
    // budget to Vertex's own default rather than picking one ourselves.
    // Response content then includes real {type:"thinking", thinking:
    // "..."} blocks alongside text/toolCall ones -- see
    // agent.lua's own extract_thinking_text/display_blocks.
    const completeOptions = request.provider === "google-vertex" ? { thinking: { enabled: true } } : undefined;

    let response;
    try {
        response = await models.complete(model, context, completeOptions);
    } catch (e) {
        // Should be rare (pi-ai's own contract keeps normal failures out
        // of exceptions -- see the header comment) but not impossible,
        // e.g. a genuinely malformed tool schema. Surfaced the same way
        // as any other error so the Lua side has one shape to handle.
        process.stdout.write(JSON.stringify({ content: [], stopReason: "error", errorMessage: `bridge: uncaught exception: ${e.message}` }));
        process.exit(1);
    }

    process.stdout.write(JSON.stringify(toResponsePayload(response)));
}

main();
