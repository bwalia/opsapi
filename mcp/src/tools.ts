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
  board_uuid?: string;
  column_name?: string;
  overdue?: boolean;
  url?: string;
  metadata?: unknown;
  assignees?: unknown[];
}
interface Project {
  uuid: string;
  name?: string;
  slug?: string;
  member_role?: string;
  task_count?: number | string;
}
interface Column {
  id: number;
  name: string;
  is_done_column?: boolean;
}
interface Board {
  uuid: string;
  name: string;
  is_default?: boolean;
  columns?: Column[];
}
interface Member {
  user_uuid: string;
  email?: string;
  first_name?: string;
  last_name?: string;
  username?: string;
  role?: string;
}

const PRIORITIES = ["critical", "high", "medium", "low", "none"] as const;
const OPEN_STATUSES = ["open", "in_progress", "blocked", "review"] as const;
const STATUSES = [...OPEN_STATUSES, "completed", "cancelled"] as const;
const DUE = ["today", "overdue", "today_and_overdue", "week", "upcoming", "none"] as const;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ymd = () => z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "use YYYY-MM-DD");
// Ids typed by the agent go into URL paths: only a uuid gets through, never "../", "?" or "#".
// (Project, board, column and people given by name are matched against OpsAPI's own lists.)
const uuid = () => z.string().trim().regex(UUID_RE, "must be a uuid");
const httpsUrl = () => z.string().url().regex(/^https:\/\//i, "must be an https:// URL");

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

/** Today on the machine running this server, as YYYY-MM-DD. */
export function localDate(d = new Date()): string {
  return new Date(d.getTime() - d.getTimezoneOffset() * 60_000).toISOString().slice(0, 10);
}

/**
 * Resolve what the agent typed (an id/uuid or a name) to exactly one item:
 * exact id, then exact name, then — unless `exact` — a unique partial name.
 * Ambiguity and no-match are errors that name the candidates, so the agent
 * can ask the user or retry with the id.
 */
export function pick<T>(
  items: T[],
  ref: string,
  kind: string,
  id: (t: T) => string,
  names: (t: T) => (string | undefined)[],
  exact = false
): T {
  const q = ref.trim().toLowerCase();
  const ns = (t: T) => names(t).filter((n): n is string => !!n).map((n) => n.toLowerCase());
  const label = (t: T) => `${names(t).find(Boolean) ?? "?"} (${id(t)})`;
  const byId = items.find((t) => id(t).toLowerCase() === q);
  if (byId) return byId;
  let hits = items.filter((t) => ns(t).includes(q));
  if (!hits.length && !exact) hits = items.filter((t) => ns(t).some((n) => n.includes(q)));
  if (hits.length === 1) return hits[0];
  if (hits.length > 1) {
    throw new Error(
      `"${ref}" matches ${hits.length} ${kind}s: ${hits.slice(0, 10).map(label).join(", ")}. Be more specific or pass the id.`
    );
  }
  const avail = items.slice(0, 20).map(label).join(", ") || "none";
  throw new Error(`No ${kind} matches "${ref}". Available: ${avail}.`);
}

const fullName = (m: Member) => [m.first_name, m.last_name].filter(Boolean).join(" ") || undefined;
const day = (d?: string | null) => (d ? String(d).slice(0, 10) : undefined);

export function createServer(api: OpsApi): McpServer {
  const server = new McpServer({ name: "opsapi", version: VERSION });

  // ── lookups ──────────────────────────────────────────────────────────────

  // The list route ignores ?search (KanbanProjectQueries.getByUser), so we
  // fetch the caller's projects (max page) and match names here.
  const listProjects = async () =>
    (await api.get<Project[]>("/api/v2/kanban/projects", { perPage: 200 })).data ?? [];

  async function resolveProject(ref: string): Promise<Project> {
    if (UUID_RE.test(ref.trim())) return { uuid: ref.trim() };
    return pick(await listProjects(), ref, "project", (p) => p.uuid, (p) => [p.name, p.slug]);
  }

  const listBoards = async (projectUuid: string) =>
    (await api.get<Board[]>(`/api/v2/kanban/projects/${projectUuid}/boards`)).data ?? [];

  // GET /boards/:uuid returns the board with its columns (numeric ids), without
  // the tasks that /full would add.
  async function getBoard(boardUuid: string): Promise<Board> {
    const b = (await api.get<Board>(`/api/v2/kanban/boards/${boardUuid}`)).data;
    if (!b) throw new Error(`Board ${boardUuid} not found.`);
    return b;
  }

  async function resolveBoard(projectUuid: string, ref?: string): Promise<Board> {
    const boards = await listBoards(projectUuid);
    if (ref) return pick(boards, ref, "board", (b) => b.uuid, (b) => [b.name]);
    const b = boards.find((x) => x.is_default) ?? boards[0];
    if (!b) throw new Error("This project has no boards.");
    return b;
  }

  const resolveColumn = (board: Board, ref: string | number) =>
    pick(board.columns ?? [], String(ref), "column", (c) => String(c.id), (c) => [c.name]);

  // People are matched exactly (uuid, email, full name or username): a partial
  // match could silently assign the wrong person.
  async function resolveAssignees(projectUuid: string, refs: string[]): Promise<Member[]> {
    const members =
      (await api.get<Member[]>(`/api/v2/kanban/projects/${projectUuid}/members`, { perPage: 200 })).data ?? [];
    return refs.map((ref) =>
      pick(members, ref, "project member", (m) => m.user_uuid, (m) => [m.email, fullName(m), m.username], true)
    );
  }

  // Read-modify-write: the task update REPLACES metadata wholesale, so we must
  // fetch, merge, and put back the whole object to avoid dropping other keys.
  async function mergeMetadata(task_uuid: string, patch: Record<string, unknown>) {
    const cur = await api.request<KanbanTask>("GET", `/api/v2/kanban/tasks/${task_uuid}`);
    const merged: Record<string, unknown> = { ...parseMetadata(cur.data?.metadata), ...patch };
    for (const [k, v] of Object.entries(patch)) if (v === null) delete merged[k];
    return merged;
  }

  // ── formatting ───────────────────────────────────────────────────────────

  function taskUrl(t: KanbanTask, projectUuid?: string): string | undefined {
    const p = t.project_uuid ?? projectUuid;
    const path = t.url ?? (p ? `/dashboard/projects/${p}/tasks/${t.uuid}` : undefined);
    return path && api.link(path);
  }

  function summary(t: KanbanTask, projectUuid?: string) {
    return {
      uuid: t.uuid,
      task_number: t.task_number,
      title: t.title,
      status: t.status,
      priority: t.priority,
      due_date: day(t.due_date),
      overdue: t.overdue,
      project: t.project_name,
      project_uuid: t.project_uuid ?? projectUuid,
      board: t.board_name,
      column: t.column_name,
      url: taskUrl(t, projectUuid),
    };
  }

  function line(t: KanbanTask, projectUuid?: string): string {
    const bits = [`#${t.task_number ?? "?"} ${t.title ?? "(untitled)"} [${t.status ?? "?"}/${t.priority ?? "?"}]`];
    if (t.project_name) bits.push(t.board_name ? `${t.project_name} / ${t.board_name}` : t.project_name);
    if (t.due_date) bits.push(`due ${day(t.due_date)}${t.overdue ? " (OVERDUE)" : ""}`);
    const url = taskUrl(t, projectUuid);
    return `- ${bits.join(" · ")}\n  uuid: ${t.uuid}${url ? `\n  url: ${url}` : ""}`;
  }

  // ── tools ────────────────────────────────────────────────────────────────

  server.registerTool(
    "list_my_tasks",
    {
      title: "List my tasks",
      description:
        "List the open kanban tasks assigned to the current user (the owner of the API key), most urgent first. " +
        "Use it for 'what are my tasks today?' (due=today_and_overdue) or 'what's due this week?' (due=week). " +
        "Returns each task's uuid (needed by the other tools), number, title, status, priority, project, due date, " +
        "an overdue flag and a dashboard link. All filters are optional and combine with AND.",
      inputSchema: {
        limit: z.number().int().min(1).max(100).optional().describe("Max tasks to return (default 25)."),
        due: z
          .enum(DUE)
          .optional()
          .describe(
            "Due-date filter: today, overdue, today_and_overdue, week, upcoming, or none (tasks without a due date). Omit for all."
          ),
        date: ymd()
          .optional()
          .describe("The user's local 'today' (YYYY-MM-DD) for `due` and the overdue flag. Default: this machine's date."),
        priority: z.array(z.enum(PRIORITIES)).optional().describe("Only these priorities, e.g. [\"critical\",\"high\"]."),
        status: z.array(z.enum(OPEN_STATUSES)).optional().describe("Only these statuses."),
        project: z.string().optional().describe("Only tasks in this project (uuid or name)."),
        search: z.string().optional().describe("Text to look for in the task title/description."),
      },
    },
    safe(async ({ limit, due, date, priority, status, project, search }) => {
      const project_uuid = project ? (await resolveProject(project)).uuid : undefined;
      const n = limit ?? 25;
      const r = await api.get<KanbanTask[]>("/api/v2/kanban/my-tasks", {
        due,
        date: date ?? localDate(),
        priority: priority?.join(","),
        status: status?.join(","),
        project_uuid,
        search,
        per_page: n,
        perPage: n, // what servers before the my-tasks filters read
      });
      const tasks = r.data ?? [];
      const filtered = !!(due || priority?.length || status?.length || project || search);
      const structured = { tasks: tasks.map((t) => summary(t)), total: r.meta?.total ?? tasks.length };
      if (tasks.length === 0) {
        return ok(filtered ? "No open tasks match these filters." : "You have no open assigned tasks.", structured);
      }
      // Servers without the my-tasks filters ignore them and omit `overdue`.
      const note =
        filtered && !tasks.some((t) => "overdue" in t)
          ? "\n\nNote: this OpsAPI server does not support my-tasks filters yet; the list above is unfiltered."
          : "";
      const total = Number(r.meta?.total ?? tasks.length);
      const head = total > tasks.length ? `${total} open task(s), showing ${tasks.length}` : `${tasks.length} open task(s)`;
      return ok(`${head}:\n\n${tasks.map((t) => line(t)).join("\n")}${note}`, structured);
    })
  );

  server.registerTool(
    "get_task",
    {
      title: "Get task details",
      description:
        "Fetch one kanban task by its uuid — title, status, priority, description, project/board/column, dashboard link, and its metadata (including any pr_url already attached).",
      inputSchema: {
        task_uuid: uuid().describe("The task's uuid (from list_my_tasks)."),
      },
    },
    safe(async ({ task_uuid }) => {
      const r = await api.request<KanbanTask>("GET", `/api/v2/kanban/tasks/${task_uuid}`);
      const t = r.data;
      if (!t) return fail("Task not found.");
      const meta = parseMetadata(t.metadata);
      const url = taskUrl(t);
      return ok(
        `#${t.task_number ?? "?"} ${t.title ?? "(untitled)"}\n` +
          `Status: ${t.status ?? "?"} · Priority: ${t.priority ?? "?"}` +
          (t.project_name ? ` · Project: ${t.project_name}` : "") +
          (t.board_name ? ` · Board: ${t.board_name}` : "") +
          (t.column_name ? ` · Column: ${t.column_name}` : "") +
          (t.due_date ? `\nDue: ${day(t.due_date)}` : "") +
          (t.description ? `\n\n${t.description}` : "") +
          (meta.pr_url ? `\nPR: ${meta.pr_url}` : "") +
          `\n\nuuid: ${t.uuid}` +
          (url ? `\nurl: ${url}` : ""),
        { task: { ...summary(t), description: t.description, metadata: meta } }
      );
    })
  );

  server.registerTool(
    "list_projects",
    {
      title: "List projects",
      description:
        "List the kanban projects the current user is a member of (name, uuid, the user's role, task count). Use it to find a project before creating or searching tasks.",
      inputSchema: {
        search: z.string().optional().describe("Only projects whose name contains this text."),
        limit: z.number().int().min(1).max(200).optional().describe("Max projects to return (default 50)."),
      },
    },
    safe(async ({ search, limit }) => {
      const q = search?.trim().toLowerCase();
      const projects = (await listProjects())
        .filter((p) => !q || [p.name, p.slug].some((n) => n?.toLowerCase().includes(q)))
        .slice(0, limit ?? 50);
      const structured = {
        projects: projects.map((p) => ({ uuid: p.uuid, name: p.name, role: p.member_role, task_count: Number(p.task_count ?? 0) })),
      };
      if (!projects.length) return ok(q ? `No project matches "${search}".` : "You are not a member of any project.", structured);
      const lines = projects.map(
        (p) => `- ${p.name ?? "(unnamed)"}${p.member_role ? ` · ${p.member_role}` : ""} · ${p.task_count ?? 0} tasks\n  uuid: ${p.uuid}`
      );
      return ok(`${projects.length} project(s):\n\n${lines.join("\n")}`, structured);
    })
  );

  server.registerTool(
    "list_boards",
    {
      title: "List a project's boards and columns",
      description:
        "List the boards of a project with their columns (name and numeric id). Use it to pick where to create or move a task.",
      inputSchema: {
        project: z.string().describe("Project uuid or name (a unique part of the name is enough)."),
      },
    },
    safe(async ({ project }) => {
      const p = await resolveProject(project);
      const boards = await Promise.all((await listBoards(p.uuid)).map(async (b) => ({ ...b, ...(await getBoard(b.uuid)) })));
      const structured = {
        project: { uuid: p.uuid, name: p.name },
        boards: boards.map((b) => ({
          uuid: b.uuid,
          name: b.name,
          is_default: !!b.is_default,
          columns: (b.columns ?? []).map((c) => ({ id: c.id, name: c.name, is_done_column: !!c.is_done_column })),
        })),
      };
      if (!boards.length) return ok(`Project ${p.name ?? p.uuid} has no boards.`, structured);
      const lines = boards.map((b) => {
        const cols = (b.columns ?? []).map((c) => `${c.name} (id ${c.id}${c.is_done_column ? ", done" : ""})`).join(", ");
        return `- ${b.name}${b.is_default ? " (default)" : ""}\n  uuid: ${b.uuid}\n  columns: ${cols || "none"}`;
      });
      return ok(`Boards of ${p.name ?? p.uuid}:\n\n${lines.join("\n")}`, structured);
    })
  );

  server.registerTool(
    "create_task",
    {
      title: "Create a task",
      description:
        "Create a kanban task in a project. Board defaults to the project's default board, column to the board's first column. " +
        "Assignees must be members of the project; if any of them can't be matched, nothing is created and the error lists the members. " +
        "Requires an editor role on the project. Returns the new task's uuid, number and dashboard link.",
      inputSchema: {
        project: z.string().describe("Project uuid or name."),
        title: z.string().min(1).describe("Task title."),
        description: z.string().optional().describe("Task description (markdown)."),
        board: z.string().optional().describe("Board uuid or name (default: the project's default board)."),
        column: z
          .union([z.string(), z.number()])
          .optional()
          .describe("Column name or numeric id from list_boards (default: the board's first column)."),
        priority: z.enum(PRIORITIES).optional().describe("Default medium."),
        due_date: ymd().optional().describe("Due date, YYYY-MM-DD."),
        assignees: z
          .array(z.string())
          .optional()
          .describe("People to assign: each a user uuid, email, full name or username of a project member."),
      },
    },
    safe(async ({ project, title, description, board, column, priority, due_date, assignees }) => {
      const p = await resolveProject(project);
      const b = await resolveBoard(p.uuid, board);
      const column_id = column === undefined ? undefined : resolveColumn(await getBoard(b.uuid), column).id;
      const people = assignees?.length ? await resolveAssignees(p.uuid, assignees) : [];
      const r = await api.request<KanbanTask>("POST", `/api/v2/kanban/boards/${b.uuid}/tasks`, {
        title,
        description,
        priority,
        due_date,
        column_id,
        assignee_uuids: people.length ? people.map((m) => m.user_uuid) : undefined,
      });
      const t = r.data;
      if (!t?.uuid) throw new Error("OpsAPI did not return the created task.");
      // The server assigns best-effort and skips failures silently; say so.
      const got = Array.isArray(t.assignees) ? t.assignees.length : people.length;
      const warn = got < people.length ? `\nWarning: only ${got} of ${people.length} assignee(s) were added.` : "";
      const url = taskUrl(t, p.uuid);
      return ok(
        `Created #${t.task_number ?? "?"} "${t.title ?? title}" in ${p.name ?? p.uuid} / ${b.name}.` +
          (people.length ? `\nAssigned: ${people.map((m) => m.email ?? fullName(m) ?? m.user_uuid).join(", ")}` : "") +
          `\nuuid: ${t.uuid}${url ? `\nurl: ${url}` : ""}${warn}`,
        { task: summary({ ...t, project_name: p.name, board_name: b.name }, p.uuid) }
      );
    })
  );

  server.registerTool(
    "update_task",
    {
      title: "Update a task",
      description:
        "Change a task's status, priority, title, description or due date, and/or set keys in its metadata. " +
        "Metadata is MERGED into what the task already has (other keys are kept); set a key to null to remove it. " +
        "Requires an editor role on the project.",
      inputSchema: {
        task_uuid: uuid().describe("The task's uuid."),
        status: z.enum(STATUSES).optional(),
        priority: z.enum(PRIORITIES).optional(),
        title: z.string().min(1).optional(),
        description: z.string().optional(),
        due_date: ymd().optional().describe("YYYY-MM-DD."),
        metadata: z.record(z.unknown()).optional().describe("Keys to set (merged), e.g. {\"branch\":\"feat/x\"}."),
      },
    },
    safe(async ({ task_uuid, metadata, ...fields }) => {
      const changed = Object.entries(fields).filter(([, v]) => v !== undefined);
      if (!changed.length && !metadata) return fail("Nothing to update: pass at least one field.");
      const body: Record<string, unknown> = Object.fromEntries(changed);
      if (metadata) body.metadata = await mergeMetadata(task_uuid, metadata);
      const t = (await api.request<KanbanTask>("PUT", `/api/v2/kanban/tasks/${task_uuid}`, body)).data;
      const what = changed.map(([k, v]) => (k === "description" ? "description" : `${k} → ${v}`));
      if (metadata) what.push(`metadata (${Object.keys(metadata).join(", ")})`);
      return ok(`Updated task #${t?.task_number ?? "?"} (${task_uuid}): ${what.join(", ")}.`, {
        task: t ? { ...summary(t), metadata: parseMetadata(t.metadata) } : { uuid: task_uuid },
      });
    })
  );

  server.registerTool(
    "move_task",
    {
      title: "Move a task to another column",
      description:
        "Move a task to a column of its own board, by column name or numeric id (see list_boards). Moving into a 'done' column may complete the task.",
      inputSchema: {
        task_uuid: uuid().describe("The task's uuid."),
        column: z.union([z.string(), z.number()]).describe("Target column name or numeric id."),
        position: z.number().int().min(0).optional().describe("Position in the column (0 = top, the default)."),
      },
    },
    safe(async ({ task_uuid, column, position }) => {
      const t = (await api.request<KanbanTask>("GET", `/api/v2/kanban/tasks/${task_uuid}`)).data;
      if (!t?.board_uuid) throw new Error("Task not found.");
      const col = resolveColumn(await getBoard(t.board_uuid), column);
      const moved = (
        await api.request<KanbanTask>("PUT", `/api/v2/kanban/tasks/${task_uuid}/move`, { column_id: col.id, position })
      ).data;
      return ok(
        `Moved #${t.task_number ?? "?"} "${t.title ?? ""}" to ${col.name}` +
          (moved?.status && moved.status !== t.status ? ` (status is now ${moved.status})` : "") +
          ".",
        { task_uuid, column: { id: col.id, name: col.name }, status: moved?.status ?? t.status }
      );
    })
  );

  server.registerTool(
    "search_tasks",
    {
      title: "Search tasks",
      description:
        "Full-text search for tasks (any status, any assignee) across all of the user's projects, or within one project. " +
        "Matches whole words of the title and description. For only the user's own open tasks use list_my_tasks.",
      inputSchema: {
        query: z.string().min(1).describe("Words to search for."),
        project: z.string().optional().describe("Limit to this project (uuid or name)."),
        limit: z.number().int().min(1).max(100).optional().describe("Max tasks to return (default 25)."),
      },
    },
    safe(async ({ query, project, limit }) => {
      const n = limit ?? 25;
      const projects = project ? [await resolveProject(project)] : await listProjects();
      // ponytail: fans out one call per project + one per board (in parallel).
      // Fine for tens of boards; add a cross-project search endpoint to OpsAPI
      // if workspaces grow beyond that.
      const found = await Promise.all(
        projects.map(async (p) =>
          Promise.all(
            (await listBoards(p.uuid)).map(async (b) => {
              const r = await api.get<KanbanTask[]>(`/api/v2/kanban/boards/${b.uuid}/tasks`, { search: query, perPage: n });
              return (r.data ?? []).map((t) => ({
                ...t,
                project_name: t.project_name ?? p.name,
                project_uuid: t.project_uuid ?? p.uuid,
                board_name: t.board_name ?? b.name,
              }));
            })
          )
        )
      );
      const tasks = found.flat(2).slice(0, n);
      const structured = { tasks: tasks.map((t) => summary(t)) };
      if (!tasks.length) return ok(`No tasks match "${query}".`, structured);
      return ok(`${tasks.length} task(s) match "${query}":\n\n${tasks.map((t) => line(t)).join("\n")}`, structured);
    })
  );

  server.registerTool(
    "log_time",
    {
      title: "Log time on a task",
      description:
        "Record time the employee spent on a task (a timesheet entry). Attributed to the employee who owns the API key.",
      inputSchema: {
        task_uuid: uuid().describe("The task's uuid."),
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
        task_uuid: uuid().describe("The task's uuid."),
        pr_url: httpsUrl().describe("The pull-request URL."),
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
        task_uuid: uuid().describe("The task's uuid."),
        pr_url: httpsUrl().optional().describe("The pull-request URL that closed the task (optional)."),
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
        task_uuid: uuid().describe("The task's uuid."),
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
