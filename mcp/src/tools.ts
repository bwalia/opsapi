/**
 * Every MCP tool lives here, once. Both transports call createServer(api)
 * with a client bound to one caller's key.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { OpsApi, parseMetadata } from "./opsapi.js";

export const VERSION = "0.2.0";

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

type Result = {
  content: { type: "text"; text: string }[];
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
};

const ok = (text: string, structuredContent?: Record<string, unknown>): Result => ({
  content: [{ type: "text", text }],
  ...(structuredContent && { structuredContent }),
});
const fail = (text: string): Result => ({ content: [{ type: "text", text }], isError: true });
const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

// Turn any thrown error into an MCP tool error the agent can read and act on.
const safe =
  <A>(fn: (args: A) => Promise<Result>) =>
  async (args: A): Promise<Result> => {
    try {
      return await fn(args);
    } catch (e) {
      return fail(message(e));
    }
  };

export function createServer(api: OpsApi): McpServer {
  const server = new McpServer({ name: "opsapi", version: VERSION });

  // Read-modify-write: the task update REPLACES metadata wholesale, so we must
  // fetch, merge, and put back the whole object to avoid dropping other keys.
  async function mergeMetadata(task_uuid: string, patch: Record<string, unknown>) {
    const cur = await api.request<KanbanTask>("GET", `/api/v2/kanban/tasks/${task_uuid}`);
    return { ...parseMetadata(cur.data?.metadata), ...patch };
  }

  server.registerTool(
    "list_my_tasks",
    {
      title: "List my tasks",
      description:
        "List the open kanban tasks assigned to the current employee (the owner of the configured API key). Use this to answer 'what are my tasks?'. Returns each task's uuid (needed for the other tools), number, title, status, priority, project and due date.",
      inputSchema: {
        limit: z.number().int().min(1).max(100).optional().describe("Max tasks to return (default 25)."),
      },
    },
    safe(async ({ limit }) => {
      const r = await api.request<KanbanTask[]>("GET", `/api/v2/kanban/my-tasks?perPage=${limit ?? 25}`);
      const tasks = r.data ?? [];
      if (tasks.length === 0) return ok("You have no open assigned tasks.");
      const lines = tasks.map((t) => {
        const due = t.due_date ? ` · due ${String(t.due_date).slice(0, 10)}` : "";
        const proj = t.project_name ? ` · ${t.project_name}` : "";
        return `- #${t.task_number ?? "?"} ${t.title ?? "(untitled)"} [${t.status ?? "?"}/${t.priority ?? "?"}]${proj}${due}\n  uuid: ${t.uuid}`;
      });
      return ok(`You have ${tasks.length} open task(s):\n\n${lines.join("\n")}`);
    })
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
    safe(async ({ task_uuid }) => {
      const r = await api.request<KanbanTask>("GET", `/api/v2/kanban/tasks/${task_uuid}`);
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
    })
  );

  server.registerTool(
    "log_time",
    {
      title: "Log time on a task",
      description:
        "Record time the employee spent on a task (a timesheet entry). Attributed to the employee who owns the API key.",
      inputSchema: {
        task_uuid: z.string().describe("The task's uuid."),
        minutes: z.number().int().min(1).max(1440).describe("Minutes spent (1–1440)."),
        description: z.string().optional().describe("What was done (optional)."),
        billable: z.boolean().optional().describe("Whether the time is billable (default true)."),
      },
    },
    safe(async ({ task_uuid, minutes, description, billable }) => {
      await api.request("POST", `/api/v2/kanban/tasks/${task_uuid}/time-entries`, {
        duration_minutes: minutes,
        description,
        is_billable: billable ?? true,
      });
      const h = Math.floor(minutes / 60);
      const m = minutes % 60;
      return ok(`Logged ${h ? `${h}h ${m}m` : `${m}m`} on task ${task_uuid}.`);
    })
  );

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
    safe(async ({ task_uuid, pr_url }) => {
      const metadata = await mergeMetadata(task_uuid, { pr_url });
      await api.request("PUT", `/api/v2/kanban/tasks/${task_uuid}`, { metadata });
      return ok(`Attached PR to task ${task_uuid}: ${pr_url}`);
    })
  );

  server.registerTool(
    "complete_task",
    {
      title: "Complete a task",
      description:
        "Finish a task in one step: optionally log the time spent, attach the PR link, and set the task's status to completed. This is the natural 'I'm done with this task' action.",
      inputSchema: {
        task_uuid: z.string().describe("The task's uuid."),
        pr_url: z.string().url().optional().describe("The pull-request URL that closed the task (optional)."),
        minutes: z
          .number()
          .int()
          .min(1)
          .max(1440)
          .optional()
          .describe("Time spent to log alongside completion (optional)."),
        note: z.string().optional().describe("Description for the logged time entry (optional)."),
      },
    },
    async ({ task_uuid, pr_url, minutes, note }) => {
      const steps: string[] = [];
      try {
        // Status/PR first (these need editor rights): doing them before logging
        // time means a permission failure can't leave an orphaned time entry that
        // a retry would then double-log.
        const body: Record<string, unknown> = { status: "completed" };
        if (pr_url) body.metadata = await mergeMetadata(task_uuid, { pr_url });
        await api.request("PUT", `/api/v2/kanban/tasks/${task_uuid}`, body);
        steps.push("marked completed");
        if (pr_url) steps.push("attached PR");
        if (minutes) {
          await api.request("POST", `/api/v2/kanban/tasks/${task_uuid}/time-entries`, {
            duration_minutes: minutes,
            description: note,
            is_billable: true,
          });
          steps.push(`logged ${minutes}m`);
        }
        return ok(`Task ${task_uuid}: ${steps.join(", ")}.`);
      } catch (e) {
        // Name what already succeeded so the agent doesn't blindly re-run it.
        const done = steps.length ? ` (already done: ${steps.join(", ")})` : "";
        return fail(`${message(e)}${done}`);
      }
    }
  );

  server.registerTool(
    "add_comment",
    {
      title: "Comment on a task",
      description: "Add a comment to a task (e.g. a status update or a note for the manager).",
      inputSchema: {
        task_uuid: z.string().describe("The task's uuid."),
        content: z.string().min(1).describe("The comment text."),
      },
    },
    safe(async ({ task_uuid, content }) => {
      await api.request("POST", `/api/v2/kanban/tasks/${task_uuid}/comments`, { content });
      return ok(`Comment added to task ${task_uuid}.`);
    })
  );

  return server;
}
