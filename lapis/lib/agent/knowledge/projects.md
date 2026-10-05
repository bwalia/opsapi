---
title: Projects
pages: /dashboard/projects
api: /api/v2/kanban/projects, /api/v2/kanban/my-tasks, /api/v2/kanban/boards, /api/v2/kanban/columns, /api/v2/kanban/tasks, /api/v2/kanban/comments, /api/v2/kanban/checklists, /api/v2/kanban/checklist-items, /api/v2/kanban/labels, /api/v2/kanban/time-entries, /api/v2/kanban/timer, /api/v2/kanban/sprints, /api/v2/kanban/epics, /api/v2/namespace/members
modules: projects, users
tools: list_projects, create_project, list_my_tasks, create_task
suggestions: Show tasks assigned to me | Create a high-priority task to fix login | Log 30 minutes on this task
readonly: false
---
# Projects
Kanban project management. A project has boards (default "Main Board": Backlog, To Do, In Progress, Review, Done), tasks (#task_number), sprints and epics. Project status: active|on_hold|completed|archived|cancelled. Task status: open|in_progress|blocked|review|completed|cancelled. Priority: critical|high|medium|low|none.
URLs: /dashboard/projects/{project_uuid} = board; .../tasks/{task_uuid} = task page; .../sprints, .../epics, .../analytics, .../settings. Read uuids from the current URL.

## Using the page
- List: **New Project** (Project Name*, Description, Color, Visibility; advanced: Customer, Start/Due Date); tabs All/Starred/Active/On Hold/Completed/Archived; card menu Edit/Archive/Delete.
- Board: board selector, "Filter by epic", "Search tasks...". Drag cards between columns; column + = Add task, column menu Edit column/Delete, "Add column". Header: Labels, Scrum, Epics, Analytics, gear = settings. Click a card to open the task page.
- Task page: title, Description, Subtasks, Checklists, Attachments, comments (@mention), Activity; sidebar Status, Assignees, Labels, Priority, Due date, Story points, Start/Stop timer; "..." → Delete task.
- Scrum: New Sprint → Start Sprint → Complete (retro) or Cancel; Backlog view "Move to Sprint". Epics: New Epic. Settings tabs: General, Members (Invite Member), Visibility, Budget, Timeline, Danger Zone.

## Rules
- Paths take uuids; body/query ids are NUMERIC `id`s (column_id, label_id, epic_id, parent_task_id, sprint task_ids) — read them from GET board (columns[].id), labels, epics or the task.
- Project roles owner|admin|member|viewer|guest. Members read; owner/admin/member write tasks, comments, checklists, time (viewer/guest: "Read-only access"). Project admins (owner/admin, workspace owner or `projects.manage`) edit project, columns, labels, sprints, epics and approve time. Managing members also needs `projects.manage`; archiving a project needs project owner.
- DELETE on project/task = archive. New project → Main Board + 5 columns, creator = owner.
- Task: title required; defaults first column, open, medium. Status changes do NOT move the card — use /move. Moving into Done sets completed.
- Assignees/new members must already be workspace members; assigning adds them to the project. The owner can't be removed or re-roled.
- Deleting a column moves its tasks to the first remaining column; the last column can't be deleted.
- Time: duration_minutes 1–1440, or started_at+ended_at. One running timer per user. Only `logged` entries can be approved/rejected, by a project admin, never your own; approved entries are locked.
- Sprints: planned → start (one active per project) → complete; cancel unless completed (tasks return to backlog); can't delete an active sprint. Completing leaves unfinished tasks — add them to the next sprint.
- GET /api/v2/kanban/projects lists only my non-archived projects and ignores search/status — filter yourself.

## API
- `GET /api/v2/kanban/projects` · `POST /api/v2/kanban/projects` {name*, description, visibility: private|internal|public, color: "#hex", start_date, due_date: YYYY-MM-DD, customer_uuid}
- `GET /api/v2/kanban/projects/{project_uuid}` (incl. boards) · `PUT /api/v2/kanban/projects/{project_uuid}` {same fields, status} · `DELETE /api/v2/kanban/projects/{project_uuid}`
- `GET /api/v2/kanban/projects/{project_uuid}/members` · `POST /api/v2/kanban/projects/{project_uuid}/members` {user_uuid*, role: admin|member|viewer|guest} · `PUT /api/v2/kanban/projects/{project_uuid}/members/{user_uuid}/role {role*}` · `DELETE /api/v2/kanban/projects/{project_uuid}/members/{user_uuid}`
- `GET /api/v2/namespace/members?search&status=active` — workspace users (row.user.uuid)
- `GET /api/v2/kanban/boards/{board_uuid}` (columns) · `GET /api/v2/kanban/boards/{board_uuid}/full` (columns + tasks)
- `POST /api/v2/kanban/boards/{board_uuid}/columns {name*, color, wip_limit, is_done_column, auto_close_tasks}` · `PUT /api/v2/kanban/columns/{column_uuid}` · `DELETE /api/v2/kanban/columns/{column_uuid}`
- `GET /api/v2/kanban/boards/{board_uuid}/tasks?search&status&priority&assignee_uuid&column_id&epic_id`
- `POST /api/v2/kanban/boards/{board_uuid}/tasks {title*, description, column_id, priority, status, story_points, time_estimate_minutes, start_date, due_date, assignee_uuids: [user uuid], epic_id, parent_task_id}`
- `GET /api/v2/kanban/tasks/{task_uuid}` · `PUT /api/v2/kanban/tasks/{task_uuid}` {title, description, status, priority, story_points, time_estimate_minutes, start_date, due_date, epic_id ("" detaches)} · `DELETE /api/v2/kanban/tasks/{task_uuid}`
- `PUT /api/v2/kanban/tasks/{task_uuid}/move {column_id*, position}`
- `POST /api/v2/kanban/tasks/{task_uuid}/assignees {user_uuid*}` · `DELETE /api/v2/kanban/tasks/{task_uuid}/assignees/{user_uuid}`
- `GET /api/v2/kanban/projects/{project_uuid}/labels` · `POST /api/v2/kanban/projects/{project_uuid}/labels` {name*, color} · `POST /api/v2/kanban/tasks/{task_uuid}/labels {label_id*}` · `DELETE /api/v2/kanban/tasks/{task_uuid}/labels/{label_id}`
- `GET /api/v2/kanban/tasks/{task_uuid}/comments` · `POST /api/v2/kanban/tasks/{task_uuid}/comments {content*, mentioned_uuids: [user uuid]}` · `PUT /api/v2/kanban/comments/{uuid} {content*}` (own only) · `DELETE /api/v2/kanban/comments/{uuid}`
- `GET /api/v2/kanban/tasks/{task_uuid}/checklists` · `POST /api/v2/kanban/tasks/{task_uuid}/checklists {name*}` · `POST /api/v2/kanban/checklists/{checklist_uuid}/items {content*}` · `PUT /api/v2/kanban/checklist-items/{item_uuid}/toggle`
- `GET /api/v2/kanban/tasks/{task_uuid}/time-entries` · `POST /api/v2/kanban/tasks/{task_uuid}/time-entries {duration_minutes | started_at+ended_at (ISO), description, is_billable}` · `PUT /api/v2/kanban/time-entries/{uuid}` · `DELETE /api/v2/kanban/time-entries/{uuid}` · `PUT /api/v2/kanban/time-entries/{uuid}/approve` · `PUT /api/v2/kanban/time-entries/{uuid}/reject`
- `POST /api/v2/kanban/timer/start {task_uuid*}` · `POST /api/v2/kanban/timer/stop` · `GET /api/v2/kanban/timer/current`
- `GET /api/v2/kanban/projects/{project_uuid}/sprints?status=planned|active|completed|cancelled` · `POST /api/v2/kanban/projects/{project_uuid}/sprints` {name*, goal, start_date, end_date}
- `GET /api/v2/kanban/sprints/{sprint_uuid}` · `PUT /api/v2/kanban/sprints/{sprint_uuid}` · `DELETE /api/v2/kanban/sprints/{sprint_uuid}` · `POST /api/v2/kanban/sprints/{sprint_uuid}/start` · `POST /api/v2/kanban/sprints/{sprint_uuid}/complete {retrospective: {went_well, to_improve, action_items}}` · `POST /api/v2/kanban/sprints/{sprint_uuid}/cancel`
- `GET /api/v2/kanban/sprints/{sprint_uuid}/tasks` · `POST /api/v2/kanban/sprints/{sprint_uuid}/tasks` or `DELETE /api/v2/kanban/sprints/{sprint_uuid}/tasks` {task_ids*: [numeric task id]}
- `GET /api/v2/kanban/projects/{project_uuid}/epics` · `POST /api/v2/kanban/projects/{project_uuid}/epics` {name*, description, status: open|in_progress|done|cancelled, color, start_date, due_date} · `PUT /api/v2/kanban/epics/{epic_uuid}` · `DELETE /api/v2/kanban/epics/{epic_uuid}` · `POST /api/v2/kanban/epics/{epic_uuid}/tasks {task_uuids*: [task uuid]}` · `DELETE /api/v2/kanban/epics/{epic_uuid}/tasks {task_uuids*: [task uuid]}`
