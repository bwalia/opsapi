#!/usr/bin/env node
/**
 * OpsAPI Kanban — MCP server
 * ==========================
 *
 * Exposes an employee's OpsAPI kanban work to Claude Code / any MCP-compatible
 * agent, so the agent can:
 *   - read the tasks assigned to that employee ("what are my tasks today?"),
 *   - log the time spent on a task (builds a per-task timesheet), and
 *   - attach the PR link to a task and mark it complete.
 *
 * Auth: a **user-scoped OpsAPI API key** (a "personal access token" bound to the
 * employee — see the repo's routes/api-keys.lua). The key both authenticates AND
 * identifies the employee, so `list_my_tasks` returns THEIR tasks and logged time
 * is attributed to THEM. Configure via env:
 *
 *   OPSAPI_URL        e.g. https://int-opsapi.workstation.co.uk   (required)
 *   OPSAPI_API_KEY    the opsk_... personal key                    (required)
 *   OPSAPI_NAMESPACE  namespace id / uuid / slug                   (optional;
 *                     the key is already namespace-bound, so this is only needed
 *                     if your deployment requires an explicit X-Namespace-* header)
 *
 * The key's scopes must include "kanban" (to reach the routes) and
 * "projects":["read"] (for my-tasks). Writes (log time, set PR, complete) also
 * require the employee to be an editor on the project.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const BASE_URL = (process.env.OPSAPI_URL || "").replace(/\/+$/, "");
const API_KEY = process.env.OPSAPI_API_KEY || "";
const NAMESPACE = process.env.OPSAPI_NAMESPACE || "";

if (!BASE_URL || !API_KEY) {
  // Fail loudly on stderr — stdout is the MCP transport and must stay clean.
  console.error(
    "[opsapi-kanban-mcp] Missing config: set OPSAPI_URL and OPSAPI_API_KEY environment variables."
  );
  process.exit(1);
}

// ── OpsAPI client ──────────────────────────────────────────────────────────

interface HouseResponse<T = unknown> {
  success?: boolean;
  data?: T;
  meta?: Record<string, unknown>;
  error?: string;
}

// OpsAPI routes parse bodies as application/x-www-form-urlencoded first (the
// dashboard sends the same), and nested values (like the jsonb `metadata`) go
// as JSON strings. Sending JSON instead is mis-parsed on PUT, so we mirror the
// dashboard and form-encode every write.
function encodeForm(body: Record<string, unknown>): string {
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(body)) {
    if (v === undefined || v === null) continue;
    params.set(k, typeof v === "object" ? JSON.stringify(v) : String(v));
  }
  return params.toString();
}

async function api<T = unknown>(
  method: string,
  path: string,
  body?: Record<string, unknown>
): Promise<HouseResponse<T>> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${API_KEY}`,
    Accept: "application/json",
  };
  if (NAMESPACE) headers["X-Namespace-Id"] = NAMESPACE;
  let payload: string | undefined;
  if (body !== undefined) {
    headers["Content-Type"] = "application/x-www-form-urlencoded";
    payload = encodeForm(body);
  }

  const res = await fetch(`${BASE_URL}${path}`, {
    method,
    headers,
    body: payload,
  });

  const text = await res.text();
  let json: HouseResponse<T> | string;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = text;
  }

  if (!res.ok) {
    const detail =
      typeof json === "string"
        ? json
        : json.error || JSON.stringify(json);
    throw new Error(`OpsAPI ${res.status} on ${method} ${path}: ${detail}`);
  }
  return (typeof json === "string" ? { data: json as unknown as T } : json);
}

// kanban_tasks.metadata is JSONB; the API may hand it back as an object or a
// JSON string. Normalise to an object so we can merge without clobbering.
function parseMetadata(raw: unknown): Record<string, unknown> {
  if (!raw) return {};
  if (typeof raw === "object") return raw as Record<string, unknown>;
  if (typeof raw === "string") {
    try {
      const o = JSON.parse(raw);
      return o && typeof o === "object" ? o : {};
    } catch {
      return {};
    }
  }
  return {};
}

interface KanbanTask {
  uuid: string;
  task_number?: number;
  title?: string;
  status?: string;
  priority?: string;
  due_date?: string | null;
  description?: string | null;
  project_name?: string;
  project_uuid?: string;
  board_name?: string;
  metadata?: unknown;
}

const ok = (text: string) => ({ content: [{ type: "text" as const, text }] });
const fail = (text: string) => ({
  content: [{ type: "text" as const, text }],
  isError: true,
});

// ── Server + tools ─────────────────────────────────────────────────────────

const server = new McpServer({
  name: "opsapi-kanban",
  version: "0.1.0",
});

server.registerTool(
  "list_my_tasks",
  {
    title: "List my tasks",
    description:
      "List the open kanban tasks assigned to the current employee (the owner of the configured API key). Use this to answer 'what are my tasks?'. Returns each task's uuid (needed for the other tools), number, title, status, priority, project and due date.",
    inputSchema: {
      limit: z
        .number()
        .int()
        .min(1)
        .max(100)
        .optional()
        .describe("Max tasks to return (default 25)."),
    },
  },
  async ({ limit }) => {
    try {
      const r = await api<KanbanTask[]>(
        "GET",
        `/api/v2/kanban/my-tasks?perPage=${limit ?? 25}`
      );
      const tasks = r.data ?? [];
      if (tasks.length === 0) return ok("You have no open assigned tasks.");
      const lines = tasks.map((t) => {
        const due = t.due_date ? ` · due ${String(t.due_date).slice(0, 10)}` : "";
        const proj = t.project_name ? ` · ${t.project_name}` : "";
        return `- #${t.task_number ?? "?"} ${t.title ?? "(untitled)"} [${t.status ?? "?"}/${t.priority ?? "?"}]${proj}${due}\n  uuid: ${t.uuid}`;
      });
      return ok(`You have ${tasks.length} open task(s):\n\n${lines.join("\n")}`);
    } catch (e) {
      return fail(String(e instanceof Error ? e.message : e));
    }
  }
);

server.registerTool(
  "get_task",
  {
    title: "Get task details",
    description:
      "Fetch one kanban task by its uuid — title, status, priority, description, project/board, and its metadata (including any pr_url already attached).",
    inputSchema: {
      task_uuid: z.string().describe("The task's uuid (from list_my_tasks)."),
    },
  },
  async ({ task_uuid }) => {
    try {
      const r = await api<KanbanTask>("GET", `/api/v2/kanban/tasks/${task_uuid}`);
      const t = r.data;
      if (!t) return fail("Task not found.");
      const meta = parseMetadata(t.metadata);
      const pr = meta.pr_url ? `\nPR: ${meta.pr_url}` : "";
      return ok(
        `#${t.task_number ?? "?"} ${t.title ?? "(untitled)"}\n` +
          `Status: ${t.status ?? "?"} · Priority: ${t.priority ?? "?"}` +
          (t.project_name ? ` · Project: ${t.project_name}` : "") +
          (t.due_date ? `\nDue: ${String(t.due_date).slice(0, 10)}` : "") +
          (t.description ? `\n\n${t.description}` : "") +
          pr +
          `\n\nuuid: ${t.uuid}`
      );
    } catch (e) {
      return fail(String(e instanceof Error ? e.message : e));
    }
  }
);

server.registerTool(
  "log_time",
  {
    title: "Log time on a task",
    description:
      "Record time the employee spent on a task (a timesheet entry). Attributed to the employee who owns the API key.",
    inputSchema: {
      task_uuid: z.string().describe("The task's uuid."),
      minutes: z
        .number()
        .int()
        .min(1)
        .max(1440)
        .describe("Minutes spent (1–1440)."),
      description: z
        .string()
        .optional()
        .describe("What was done (optional)."),
      billable: z
        .boolean()
        .optional()
        .describe("Whether the time is billable (default true)."),
    },
  },
  async ({ task_uuid, minutes, description, billable }) => {
    try {
      await api("POST", `/api/v2/kanban/tasks/${task_uuid}/time-entries`, {
        duration_minutes: minutes,
        description,
        is_billable: billable ?? true,
      });
      const h = Math.floor(minutes / 60);
      const m = minutes % 60;
      const pretty = h ? `${h}h ${m}m` : `${m}m`;
      return ok(`Logged ${pretty} on task ${task_uuid}.`);
    } catch (e) {
      return fail(String(e instanceof Error ? e.message : e));
    }
  }
);

// Read-modify-write: the task update REPLACES metadata wholesale, so we must
// fetch, merge, and put back the whole object to avoid dropping other keys.
async function mergeMetadata(
  task_uuid: string,
  patch: Record<string, unknown>
): Promise<Record<string, unknown>> {
  const cur = await api<KanbanTask>("GET", `/api/v2/kanban/tasks/${task_uuid}`);
  const meta = parseMetadata(cur.data?.metadata);
  return { ...meta, ...patch };
}

server.registerTool(
  "set_task_pr",
  {
    title: "Attach a PR link to a task",
    description:
      "Attach (or update) the pull-request URL on a task, stored in the task's metadata.pr_url. Preserves any other metadata.",
    inputSchema: {
      task_uuid: z.string().describe("The task's uuid."),
      pr_url: z.string().url().describe("The pull-request URL."),
    },
  },
  async ({ task_uuid, pr_url }) => {
    try {
      const metadata = await mergeMetadata(task_uuid, { pr_url });
      await api("PUT", `/api/v2/kanban/tasks/${task_uuid}`, { metadata });
      return ok(`Attached PR to task ${task_uuid}: ${pr_url}`);
    } catch (e) {
      return fail(String(e instanceof Error ? e.message : e));
    }
  }
);

server.registerTool(
  "complete_task",
  {
    title: "Complete a task",
    description:
      "Finish a task in one step: optionally log the time spent, attach the PR link, and set the task's status to completed. This is the natural 'I'm done with this task' action.",
    inputSchema: {
      task_uuid: z.string().describe("The task's uuid."),
      pr_url: z
        .string()
        .url()
        .optional()
        .describe("The pull-request URL that closed the task (optional)."),
      minutes: z
        .number()
        .int()
        .min(1)
        .max(1440)
        .optional()
        .describe("Time spent to log alongside completion (optional)."),
      note: z
        .string()
        .optional()
        .describe("Description for the logged time entry (optional)."),
    },
  },
  async ({ task_uuid, pr_url, minutes, note }) => {
    try {
      const steps: string[] = [];
      if (minutes) {
        await api("POST", `/api/v2/kanban/tasks/${task_uuid}/time-entries`, {
          duration_minutes: minutes,
          description: note,
          is_billable: true,
        });
        steps.push(`logged ${minutes}m`);
      }
      const body: Record<string, unknown> = { status: "completed" };
      if (pr_url) {
        body.metadata = await mergeMetadata(task_uuid, { pr_url });
        steps.push(`attached PR`);
      }
      await api("PUT", `/api/v2/kanban/tasks/${task_uuid}`, body);
      steps.push("marked completed");
      return ok(`Task ${task_uuid}: ${steps.join(", ")}.`);
    } catch (e) {
      return fail(String(e instanceof Error ? e.message : e));
    }
  }
);

server.registerTool(
  "add_comment",
  {
    title: "Comment on a task",
    description:
      "Add a comment to a task (e.g. a status update or a note for the manager).",
    inputSchema: {
      task_uuid: z.string().describe("The task's uuid."),
      content: z.string().min(1).describe("The comment text."),
    },
  },
  async ({ task_uuid, content }) => {
    try {
      await api("POST", `/api/v2/kanban/tasks/${task_uuid}/comments`, { content });
      return ok(`Comment added to task ${task_uuid}.`);
    } catch (e) {
      return fail(String(e instanceof Error ? e.message : e));
    }
  }
);

// ── Start (stdio transport) ──────────────────────────────────────────────────

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("[opsapi-kanban-mcp] ready");
}

main().catch((err) => {
  console.error("[opsapi-kanban-mcp] fatal:", err);
  process.exit(1);
});
