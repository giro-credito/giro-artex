#!/usr/bin/env node
// Local MCP server so Cursor can list and create ARTEX tasks.
// ARTEX has no MCP endpoint. This process calls the HTTP API with the
// login JWT from ARTEX_TOKEN. The panel is only reachable on Twingate.

const base = (process.env.ARTEX_URL || "https://artex.girocredito.com").replace(/\/$/, "");
const token = (process.env.ARTEX_TOKEN || "").trim();

function send(msg) {
  const body = Buffer.from(JSON.stringify(msg), "utf8");
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}

function reply(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function fail(id, message) {
  send({ jsonrpc: "2.0", id, error: { code: -32000, message } });
}

async function api(method, path, body) {
  if (!token || token.startsWith("<")) {
    throw new Error("ARTEX_TOKEN is empty. Paste the artex_token value from the browser into ~/.cursor/mcp.json.");
  }
  const res = await fetch(`${base}/api${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = text;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    /* leave text */
  }
  if (!res.ok) {
    const message = data && data.error ? data.error : text || res.statusText;
    throw new Error(`${res.status} ${message}`);
  }
  return data;
}

const tools = [
  {
    name: "list_tasks",
    description: "List ARTEX tasks.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "list_llm_profiles",
    description: "List ARTEX LLM profiles, including which one is active.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "create_task",
    description: "Create an ARTEX task. The goal must name a host or URL and be at least 80 characters.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string" },
        description: { type: "string" },
        goal: { type: "string" },
        timeout_minutes: { type: "integer" },
        llm_profile_ids: { type: "array", items: { type: "integer" } },
        intercept_rules: { type: "array", items: { type: "object" } },
        seed_first_intent: { type: "boolean" },
      },
      required: ["description", "goal"],
    },
  },
  {
    name: "pause_task",
    description: "Pause a running ARTEX task by id.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" } },
      required: ["id"],
    },
  },
];

async function callTool(name, args) {
  if (name === "list_tasks") return api("GET", "/tasks");
  if (name === "list_llm_profiles") return api("GET", "/llm/profiles");
  if (name === "pause_task") return api("POST", `/tasks/${encodeURIComponent(args.id)}/control`, { action: "pause" });
  if (name === "create_task") {
    return api("POST", "/tasks", {
      name: args.name || "",
      description: args.description,
      goal: args.goal,
      llm_profile_ids: args.llm_profile_ids || [],
      timeout_seconds: Math.max(0, Number(args.timeout_minutes) || 0) * 60,
      seed_first_intent: Boolean(args.seed_first_intent),
      intercept_rules: args.intercept_rules || [],
      credentials: [],
    });
  }
  throw new Error(`Unknown tool ${name}`);
}

async function handle(msg) {
  if (!msg || msg.jsonrpc !== "2.0") return;
  if (msg.id === undefined) return;
  if (msg.method === "initialize") {
    reply(msg.id, {
      protocolVersion: "2024-11-05",
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "artex", version: "0.1.0" },
    });
    return;
  }
  if (msg.method === "tools/list") {
    reply(msg.id, { tools });
    return;
  }
  if (msg.method === "tools/call") {
    try {
      const result = await callTool(msg.params?.name, msg.params?.arguments || {});
      reply(msg.id, {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      });
    } catch (err) {
      reply(msg.id, {
        content: [{ type: "text", text: String(err.message || err) }],
        isError: true,
      });
    }
    return;
  }
  if (msg.method === "ping") {
    reply(msg.id, {});
    return;
  }
  fail(msg.id, `Method not found: ${msg.method}`);
}

let buf = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  for (;;) {
    const headerEnd = buf.indexOf("\r\n\r\n");
    if (headerEnd === -1) return;
    const header = buf.slice(0, headerEnd).toString("utf8");
    const match = header.match(/Content-Length:\s*(\d+)/i);
    if (!match) {
      buf = buf.slice(headerEnd + 4);
      continue;
    }
    const len = Number(match[1]);
    const start = headerEnd + 4;
    if (buf.length < start + len) return;
    const raw = buf.slice(start, start + len).toString("utf8");
    buf = buf.slice(start + len);
    try {
      handle(JSON.parse(raw));
    } catch (err) {
      send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: String(err.message || err) } });
    }
  }
});
