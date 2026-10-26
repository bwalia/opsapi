/**
 * Every MCP tool lives here, once. Both transports call createServer(api)
 * with a client bound to one caller's key.
 */

import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { OpsApi, parseMetadata } from "./opsapi.js";

export const VERSION = "0.3.0";

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

// Website content (CMS): blog posts, pages, categories, tags.
interface CmsTerm {
  uuid: string;
  name: string;
  slug?: string;
  description?: string | null;
  post_count?: number | string;
}
interface CmsPost {
  uuid: string;
  title?: string;
  slug?: string;
  status?: string;
  visibility?: string;
  excerpt?: string | null;
  content_html?: string | null;
  featured_image_url?: string | null;
  author_name?: string | null;
  is_featured?: boolean;
  published_at?: string | null;
  scheduled_at?: string | null;
  updated_at?: string | null;
  categories?: CmsTerm[];
  tags?: CmsTerm[];
  seo_title?: string | null;
  seo_description?: string | null;
  seo_keywords?: string | null;
}
interface CmsPage {
  uuid: string;
  title?: string;
  slug?: string;
  status?: string;
  excerpt?: string | null;
  content_html?: string | null;
  featured_image_url?: string | null;
  template?: string | null;
  menu_order?: number;
  show_in_nav?: boolean;
  published_at?: string | null;
  updated_at?: string | null;
  seo_title?: string | null;
  seo_description?: string | null;
  seo_keywords?: string | null;
}
interface CmsWebhook {
  uuid: string;
  name?: string | null;
  url: string;
  active?: boolean;
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
const POST_STATUSES = ["draft", "published", "scheduled", "archived"] as const;
const PAGE_STATUSES = ["draft", "published", "archived"] as const;
const IMAGE_NAME = /\.(jpe?g|png|webp|gif|svg)$/i;

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

export interface ServerOptions {
  /** Let upload_image read files from this machine: stdio only, never the shared HTTP service. */
  localFiles?: boolean;
}

export function createServer(api: OpsApi, opts: ServerOptions = {}): McpServer {
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

  // ── website content (CMS) ────────────────────────────────────────────────
  // Writes go to the workspace the key belongs to; the public website reads
  // only published + public items (GET /api/v2/public/cms/<workspace-slug>/…).

  const listCategories = async () => (await api.get<CmsTerm[]>("/api/v2/cms/categories")).data ?? [];
  const listTags = async () => (await api.get<CmsTerm[]>("/api/v2/cms/tags")).data ?? [];

  // Categories must already exist (tags are created on the fly), and are matched
  // exactly: a partial match could file the post under the wrong category.
  async function resolveCategories(refs: string[]): Promise<string[]> {
    if (!refs.length) return [];
    const cats = await listCategories();
    return refs.map((r) => pick(cats, r, "category", (c) => c.uuid, (c) => [c.name, c.slug], true).uuid);
  }

  const seo = {
    seo_title: z.string().optional().describe("Title for search engines (default: the title)."),
    seo_description: z.string().optional().describe("Meta description for search engines (~160 characters)."),
    seo_keywords: z.string().optional().describe("Comma-separated keywords."),
  };
  const postFields = {
    content_html: z.string().optional().describe("The body as HTML (<p>, <h2>, <ul>, <img src>, <a href>…)."),
    excerpt: z.string().optional().describe("One or two sentences shown in lists and previews."),
    slug: z.string().optional().describe("URL part, e.g. 'spring-sale' (default: made from the title, kept unique)."),
    status: z
      .enum(POST_STATUSES)
      .optional()
      .describe(
        "draft (default on create) · published (live on the website) · scheduled (only records scheduled_at; NOT published automatically) · archived (taken off the website)."
      ),
    visibility: z.enum(["public", "private"]).optional().describe("private posts never show on the website (default public)."),
    featured: z.boolean().optional().describe("Mark as a featured post."),
    categories: z
      .array(z.string())
      .optional()
      .describe("Category names or uuids; they must exist (see list_categories_and_tags / create_category). Replaces the post's categories; [] clears them."),
    tags: z.array(z.string()).optional().describe("Tag names; new ones are created. Replaces the post's tags; [] clears them."),
    featured_image_url: z.string().optional().describe("Cover image URL (e.g. from upload_image)."),
    author_name: z.string().optional().describe("Shown author (default: the key's owner)."),
    scheduled_at: z.string().optional().describe("ISO date-time, with status=scheduled."),
    ...seo,
  };
  const pageFields = {
    content_html: z.string().optional().describe("The page body as HTML."),
    excerpt: z.string().optional().describe("Short summary."),
    slug: z.string().optional().describe("URL part, e.g. 'about' (default: made from the title)."),
    status: z.enum(PAGE_STATUSES).optional().describe("draft (default on create) · published (live) · archived (taken off)."),
    show_in_nav: z.boolean().optional().describe("List the page in the website's navigation (public /nav)."),
    menu_order: z.number().int().optional().describe("Position in the navigation, lowest first."),
    template: z.string().optional().describe("Layout template slug (default: the plain page)."),
    featured_image_url: z.string().optional().describe("Cover image URL."),
    ...seo,
  };
  type PostArgs = { [K in keyof typeof postFields]?: unknown } & { title?: string };

  async function postBody(a: PostArgs) {
    const { categories, featured, ...rest } = a;
    const body: Record<string, unknown> = { ...rest, is_featured: featured };
    if (categories) body.category_uuids = await resolveCategories(categories as string[]);
    return body;
  }
  const hasFields = (body: Record<string, unknown>) => Object.values(body).some((v) => v !== undefined);

  const postLink = (p: CmsPost) => api.link(`/dashboard/cms/posts/${p.uuid}`);
  const pageLink = (p: CmsPage) => api.link(`/dashboard/cms/pages/${p.uuid}`);
  const names = (ts?: CmsTerm[]) => (ts ?? []).map((t) => t.name).join(", ");
  const liveNote = (status?: string) =>
    status === "published" ? "" : " Not on the website until its status is published.";

  function postSummary(p: CmsPost) {
    return {
      uuid: p.uuid,
      title: p.title,
      slug: p.slug,
      status: p.status,
      visibility: p.visibility,
      featured: !!p.is_featured,
      published_at: p.published_at ?? null,
      categories: (p.categories ?? []).map((c) => c.name),
      tags: (p.tags ?? []).map((t) => t.name),
      url: postLink(p),
    };
  }
  function postLine(p: CmsPost) {
    const bits = [`${p.title ?? "(untitled)"} [${p.status ?? "?"}${p.visibility === "private" ? ", private" : ""}]`];
    if (p.published_at) bits.push(`published ${day(p.published_at)}`);
    if (p.categories?.length) bits.push(names(p.categories));
    if (p.tags?.length) bits.push(`#${(p.tags ?? []).map((t) => t.name).join(" #")}`);
    return `- ${bits.join(" · ")}\n  uuid: ${p.uuid} · slug: ${p.slug ?? "?"}`;
  }
  function postDetails(p: CmsPost) {
    return (
      `${p.title ?? "(untitled)"}\n` +
      `Status: ${p.status ?? "?"} · Visibility: ${p.visibility ?? "?"}${p.is_featured ? " · Featured" : ""}` +
      (p.published_at ? ` · Published: ${day(p.published_at)}` : "") +
      `\nSlug: ${p.slug ?? "?"}` +
      (p.categories?.length ? `\nCategories: ${names(p.categories)}` : "") +
      (p.tags?.length ? `\nTags: ${names(p.tags)}` : "") +
      (p.featured_image_url ? `\nImage: ${p.featured_image_url}` : "") +
      (p.excerpt ? `\nExcerpt: ${p.excerpt}` : "") +
      `\n\nuuid: ${p.uuid}\nurl: ${postLink(p)}`
    );
  }

  server.registerTool(
    "list_posts",
    {
      title: "List blog posts",
      description:
        "List the workspace's blog posts (drafts too), newest first: title, status, slug, uuid, categories and tags. " +
        "Use it to find a post before get_post / update_post.",
      inputSchema: {
        status: z.enum(POST_STATUSES).optional().describe("Only posts with this status."),
        search: z.string().optional().describe("Text in the title or excerpt."),
        category: z.string().optional().describe("Only posts in this category (name or uuid)."),
        tag: z.string().optional().describe("Only posts with this tag (name or slug)."),
        featured: z.boolean().optional().describe("Only featured posts."),
        page: z.number().int().min(1).optional().describe("Page number (default 1)."),
        limit: z.number().int().min(1).max(100).optional().describe("Posts per page (default 20)."),
      },
    },
    safe(async ({ status, search, category, tag, featured, page, limit }) => {
      const category_uuid = category ? (await resolveCategories([category]))[0] : undefined;
      const tag_slug = tag
        ? pick(await listTags(), tag, "tag", (t) => t.slug ?? t.uuid, (t) => [t.name], true).slug
        : undefined;
      const r = await api.get<CmsPost[]>("/api/v2/cms/posts", {
        status,
        search,
        category: category_uuid,
        tag: tag_slug,
        featured: featured ? "true" : undefined,
        page,
        perPage: limit ?? 20,
      });
      const posts = r.data ?? [];
      const total = Number(r.meta?.total ?? posts.length);
      const structured = { posts: posts.map(postSummary), total, page: Number(r.meta?.page ?? 1) };
      if (!posts.length) return ok("No posts match.", structured);
      const head = total > posts.length ? `${total} post(s), showing ${posts.length}` : `${posts.length} post(s)`;
      return ok(`${head}:\n\n${posts.map(postLine).join("\n")}`, structured);
    })
  );

  server.registerTool(
    "get_post",
    {
      title: "Get a blog post",
      description: "Fetch one blog post by uuid with its full HTML body, SEO fields, categories and tags.",
      inputSchema: { post_uuid: uuid().describe("The post's uuid (from list_posts).") },
    },
    safe(async ({ post_uuid }) => {
      const p = (await api.request<CmsPost>("GET", `/api/v2/cms/posts/${post_uuid}`)).data;
      if (!p) return fail("Post not found.");
      return ok(`${postDetails(p)}\n\n--- content_html ---\n${p.content_html ?? ""}`, { post: { ...postSummary(p), ...p } });
    })
  );

  server.registerTool(
    "create_post",
    {
      title: "Create a blog post",
      description:
        "Create a blog post in the workspace. It is a draft unless status=published. " +
        "Categories must exist (matched by exact name or uuid; if one doesn't, nothing is created and the error lists them). " +
        "Needs the key scope cms:create. Returns the uuid, slug and dashboard link.",
      inputSchema: { title: z.string().min(1).describe("Post title."), ...postFields },
    },
    safe(async (a) => {
      const p = (await api.request<CmsPost>("POST", "/api/v2/cms/posts", await postBody(a))).data;
      if (!p) return fail("OpsAPI did not return the new post.");
      return ok(`Created post "${p.title}" (${p.status}).${liveNote(p.status)}\n\n${postDetails(p)}`, { post: postSummary(p) });
    })
  );

  server.registerTool(
    "update_post",
    {
      title: "Update or publish a blog post",
      description:
        "Change a blog post: only the fields you pass change. Publish with status=published (the first publish stamps the date); " +
        "unpublish with status=draft or archived. categories/tags replace the current ones. Needs cms:update.",
      inputSchema: {
        post_uuid: uuid().describe("The post's uuid."),
        title: z.string().min(1).optional().describe("New title."),
        ...postFields,
      },
    },
    safe(async ({ post_uuid, ...a }) => {
      const body = await postBody(a);
      if (!hasFields(body)) return fail("Nothing to change: pass at least one field.");
      const p = (await api.request<CmsPost>("PUT", `/api/v2/cms/posts/${post_uuid}`, body)).data;
      if (!p) return fail("Post not found.");
      return ok(`Updated post "${p.title}" (${p.status}).${liveNote(p.status)}\n\n${postDetails(p)}`, { post: postSummary(p) });
    })
  );

  function pageSummary(p: CmsPage) {
    return {
      uuid: p.uuid,
      title: p.title,
      slug: p.slug,
      status: p.status,
      show_in_nav: !!p.show_in_nav,
      menu_order: p.menu_order,
      url: pageLink(p),
    };
  }
  const pageDetails = (p: CmsPage) =>
    `${p.title ?? "(untitled)"}\nStatus: ${p.status ?? "?"} · Slug: ${p.slug ?? "?"}` +
    (p.show_in_nav ? ` · In navigation (order ${p.menu_order ?? 0})` : "") +
    (p.template ? ` · Template: ${p.template}` : "") +
    `\n\nuuid: ${p.uuid}\nurl: ${pageLink(p)}`;

  server.registerTool(
    "list_pages",
    {
      title: "List website pages",
      description: "List the workspace's static website pages (About, Contact…), drafts too, in navigation order.",
      inputSchema: {
        status: z.enum(PAGE_STATUSES).optional().describe("Only pages with this status."),
        search: z.string().optional().describe("Text in the title."),
      },
    },
    safe(async ({ status, search }) => {
      const pages = (await api.get<CmsPage[]>("/api/v2/cms/pages", { status, search })).data ?? [];
      const structured = { pages: pages.map(pageSummary) };
      if (!pages.length) return ok("No pages match.", structured);
      const lines = pages.map(
        (p) => `- ${p.title ?? "(untitled)"} [${p.status ?? "?"}]${p.show_in_nav ? " · in nav" : ""}\n  uuid: ${p.uuid} · slug: ${p.slug ?? "?"}`
      );
      return ok(`${pages.length} page(s):\n\n${lines.join("\n")}`, structured);
    })
  );

  server.registerTool(
    "get_page",
    {
      title: "Get a website page",
      description: "Fetch one website page by uuid with its full HTML body and SEO fields.",
      inputSchema: { page_uuid: uuid().describe("The page's uuid (from list_pages).") },
    },
    safe(async ({ page_uuid }) => {
      const p = (await api.request<CmsPage>("GET", `/api/v2/cms/pages/${page_uuid}`)).data;
      if (!p) return fail("Page not found.");
      return ok(`${pageDetails(p)}\n\n--- content_html ---\n${p.content_html ?? ""}`, { page: { ...pageSummary(p), ...p } });
    })
  );

  server.registerTool(
    "create_page",
    {
      title: "Create a website page",
      description: "Create a static website page. It is a draft unless status=published. Needs cms:create.",
      inputSchema: { title: z.string().min(1).describe("Page title."), ...pageFields },
    },
    safe(async (a) => {
      const p = (await api.request<CmsPage>("POST", "/api/v2/cms/pages", a)).data;
      if (!p) return fail("OpsAPI did not return the new page.");
      return ok(`Created page "${p.title}" (${p.status}).${liveNote(p.status)}\n\n${pageDetails(p)}`, { page: pageSummary(p) });
    })
  );

  server.registerTool(
    "update_page",
    {
      title: "Update or publish a website page",
      description:
        "Change a website page: only the fields you pass change. Publish with status=published, unpublish with draft or archived. Needs cms:update.",
      inputSchema: {
        page_uuid: uuid().describe("The page's uuid."),
        title: z.string().min(1).optional().describe("New title."),
        ...pageFields,
      },
    },
    safe(async ({ page_uuid, ...a }) => {
      if (!hasFields(a)) return fail("Nothing to change: pass at least one field.");
      const p = (await api.request<CmsPage>("PUT", `/api/v2/cms/pages/${page_uuid}`, a)).data;
      if (!p) return fail("Page not found.");
      return ok(`Updated page "${p.title}" (${p.status}).${liveNote(p.status)}\n\n${pageDetails(p)}`, { page: pageSummary(p) });
    })
  );

  server.registerTool(
    "list_categories_and_tags",
    {
      title: "List blog categories and tags",
      description: "List the workspace's blog categories and tags (name, slug, uuid, number of posts).",
      inputSchema: {},
    },
    safe(async () => {
      const [cats, tags] = await Promise.all([listCategories(), listTags()]);
      const term = (t: CmsTerm) => ({ uuid: t.uuid, name: t.name, slug: t.slug, posts: Number(t.post_count ?? 0) });
      const fmt = (ts: CmsTerm[]) =>
        ts.map((t) => `- ${t.name} (slug ${t.slug ?? "?"}, ${t.post_count ?? 0} posts) · uuid: ${t.uuid}`).join("\n") || "none";
      return ok(`Categories:\n${fmt(cats)}\n\nTags:\n${fmt(tags)}`, { categories: cats.map(term), tags: tags.map(term) });
    })
  );

  server.registerTool(
    "create_category",
    {
      title: "Create a blog category",
      description: "Create a blog category (posts can then be filed under it by name). Needs cms:create.",
      inputSchema: {
        name: z.string().min(1).describe("Category name, e.g. 'News'."),
        description: z.string().optional().describe("Short description."),
        slug: z.string().optional().describe("URL part (default: made from the name)."),
      },
    },
    safe(async ({ name, description, slug }) => {
      const c = (await api.request<CmsTerm>("POST", "/api/v2/cms/categories", { name, description, slug })).data;
      if (!c) return fail("OpsAPI did not return the new category.");
      return ok(`Created category "${c.name}" (slug ${c.slug ?? "?"}, uuid ${c.uuid}).`, { category: c });
    })
  );

  server.registerTool(
    "upload_image",
    {
      title: "Upload an image for the website",
      description:
        "Upload a jpg/png/webp/gif/svg (max 8 MB) to the workspace's public website storage and get its public URL, " +
        "for a post's featured_image_url or an <img src> in content_html. Give file_path (only when this server runs on your machine) " +
        "or data_base64 + filename. With slug, the file is stored as img/blog/<slug>/<kind>.<ext> (the same name again replaces it). " +
        "Needs cms:update, and the server must have public media storage configured.",
      inputSchema: {
        file_path: z.string().optional().describe("Path of the image on this machine."),
        data_base64: z.string().optional().describe("The image bytes, base64-encoded (instead of file_path)."),
        filename: z.string().regex(IMAGE_NAME, "must end in .jpg .jpeg .png .webp .gif or .svg").optional()
          .describe("File name with its extension; required with data_base64."),
        slug: z.string().optional().describe("The post's slug, to store it next to that post."),
        kind: z.string().optional().describe("'cover' (default) for the featured image, or e.g. 'inline-1' for an image in the body."),
      },
    },
    safe(async ({ file_path, data_base64, filename, slug, kind }) => {
      if (!!file_path === !!data_base64) return fail("Give exactly one of file_path or data_base64.");
      let bytes: Buffer;
      let name: string;
      if (file_path) {
        if (!opts.localFiles) {
          return fail("file_path only works when the MCP server runs on your machine (stdio). Send data_base64 + filename instead.");
        }
        name = filename ?? basename(file_path);
        if (!IMAGE_NAME.test(name)) return fail("Only .jpg .jpeg .png .webp .gif or .svg images can be uploaded.");
        bytes = await readFile(file_path);
      } else {
        if (!filename) return fail("filename is required with data_base64 (its extension sets the image type).");
        name = filename;
        bytes = Buffer.from(data_base64 as string, "base64");
      }
      const form = new FormData();
      form.append("file", new Blob([new Uint8Array(bytes)]), name);
      if (slug) form.append("slug", slug);
      if (kind) form.append("kind", kind);
      const r = (await api.request<{ url: string; size?: number }>("POST", "/api/v2/cms/media", form)).data;
      if (!r?.url) return fail("OpsAPI did not return the image URL.");
      return ok(`Uploaded ${name}: ${r.url}`, { url: r.url, size: r.size ?? bytes.length });
    })
  );

  server.registerTool(
    "notify_website",
    {
      title: "Tell the website to update",
      description:
        "Send the workspace's website webhooks now, so connected sites rebuild or refresh. OpsAPI never sends them by itself: " +
        "call this after publishing, changing or unpublishing content the site shows. With post_uuid the payload names that post. " +
        "With no webhook, every active one is sent. Needs cms:update.",
      inputSchema: {
        post_uuid: uuid().optional().describe("The post that changed (its uuid, slug and status go in the payload)."),
        webhook: z.string().optional().describe("Only this webhook (name or uuid)."),
        event: z
          .enum(["post.published", "post.created", "post.updated", "post.deleted"])
          .optional()
          .describe("Event name sent to the site (default post.published)."),
      },
    },
    safe(async ({ post_uuid, webhook, event }) => {
      const all = (await api.get<CmsWebhook[]>("/api/v2/cms/webhooks")).data ?? [];
      const targets = webhook
        ? [pick(all, webhook, "webhook", (w) => w.uuid, (w) => [w.name ?? undefined], true)]
        : all.filter((w) => w.active !== false);
      if (!targets.length) {
        return ok("This workspace has no active website webhooks, so there is nothing to send. Add one in the dashboard under Content → Website updates.", { sent: [] });
      }
      const post = post_uuid ? (await api.request<CmsPost>("GET", `/api/v2/cms/posts/${post_uuid}`)).data : undefined;
      const payload = { event: event ?? "post.published", uuid: post?.uuid, slug: post?.slug, status: post?.status };
      const sent = await Promise.all(
        targets.map(async (w) => {
          try {
            const r = await api.request<unknown>("POST", `/api/v2/cms/webhooks/${w.uuid}/trigger`, payload);
            return { webhook: w.name || w.url, ok: true, status: (r as { status?: number }).status };
          } catch (e) {
            return { webhook: w.name || w.url, ok: false, error: message(e) };
          }
        })
      );
      const lines = sent.map((s) => `- ${s.webhook}: ${s.ok ? `delivered${s.status ? ` (HTTP ${s.status})` : ""}` : `FAILED — ${s.error}`}`);
      const failed = sent.filter((s) => !s.ok).length;
      return { ...ok(`Sent ${sent.length - failed} of ${sent.length} webhook(s):\n${lines.join("\n")}`, { sent }), ...(failed === sent.length && { isError: true }) };
    })
  );

  return server;
}
