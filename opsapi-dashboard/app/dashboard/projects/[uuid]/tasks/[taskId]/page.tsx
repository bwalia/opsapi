'use client';

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft, Loader2, MoreHorizontal, Trash2, Plus, X, Check, Send,
  CheckSquare, MessageSquare, ListTree, Paperclip, Activity as ActivityIcon,
  Users, Tag, Flag, Calendar, Clock, Target, Link2, ExternalLink, Upload,
} from 'lucide-react';
import { toast } from 'react-hot-toast';
import { useKanbanStore } from '@/store/kanban.store';
import { usePermissions } from '@/contexts/PermissionsContext';
import { namespaceService } from '@/services/namespace.service';
import {
  kanbanService,
  formatPriority,
  formatTaskStatus,
  getPriorityColor,
  getTaskStatusColor,
  formatTimeMinutes,
} from '@/services/kanban.service';
import { TimerButton } from '@/components/time-tracking';
import RichTextEditor from '@/components/academy/RichTextEditor';
import type {
  KanbanTask, KanbanProjectMember, KanbanActivity, KanbanTaskStatus, KanbanTaskPriority,
} from '@/types';
import { cn } from '@/lib/utils';

const STATUSES: KanbanTaskStatus[] = ['open', 'in_progress', 'blocked', 'review', 'completed', 'cancelled'];
const PRIORITIES: KanbanTaskPriority[] = ['critical', 'high', 'medium', 'low', 'none'];

// Shared modern input style — soft filled field that lifts to white on focus.
const INPUT =
  'w-full rounded-lg border border-secondary-200 bg-secondary-50/60 px-3 py-2 text-sm text-secondary-800 transition focus:bg-surface focus:border-primary-400 focus:outline-none focus:ring-2 focus:ring-primary-500/20';

const initials = (f?: string, l?: string) => `${(f || '?')[0] || '?'}${(l || '')[0] || ''}`.toUpperCase();
const shortDate = (s?: string | null) => (s ? new Date(s).toLocaleDateString() : '');
const dateTime = (s?: string | null) => (s ? new Date(s).toLocaleString() : '');

// ── Small building blocks ────────────────────────────────────────────────────

function SectionTitle({ icon, children, right }: { icon: React.ReactNode; children: React.ReactNode; right?: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between mb-3">
      <div className="flex items-center gap-2 text-sm font-semibold text-secondary-800">
        {icon}
        {children}
      </div>
      {right}
    </div>
  );
}

function Avatar({ f, l, size = 28 }: { f?: string; l?: string; size?: number }) {
  return (
    <span
      className="rounded-full bg-primary-100 text-primary-700 font-medium inline-flex items-center justify-center shrink-0"
      style={{ width: size, height: size, fontSize: size * 0.4 }}
      title={`${f ?? ''} ${l ?? ''}`.trim()}
    >
      {initials(f, l)}
    </span>
  );
}

// A compact multi-select popover (assignees / labels) that closes on choose.
function Picker({
  label, disabled, children,
}: { label: string; disabled?: boolean; children: (close: () => void) => React.ReactNode }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="relative inline-block">
      <button
        type="button"
        disabled={disabled}
        onClick={() => setOpen((o) => !o)}
        className="inline-flex items-center gap-1 rounded-full border border-dashed border-secondary-300 px-2.5 py-1 text-xs text-secondary-500 hover:text-secondary-800 hover:border-secondary-400 disabled:opacity-50 transition-colors"
      >
        <Plus size={12} /> {label}
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setOpen(false)} />
          <div className="absolute z-20 mt-1 w-56 max-h-60 overflow-y-auto rounded-lg border border-secondary-200 bg-surface shadow-lg py-1">
            {children(() => setOpen(false))}
          </div>
        </>
      )}
    </div>
  );
}

// ── Page ─────────────────────────────────────────────────────────────────────

export default function TaskDetailPage() {
  const { uuid: projectUuid, taskId } = useParams<{ uuid: string; taskId: string }>();
  const router = useRouter();
  const boardHref = `/dashboard/projects/${projectUuid}`;

  const {
    selectedTask, selectedTaskLoading, loadTask, updateTask, deleteTask,
    addTaskAssignee, removeTaskAssignee, addTaskLabel, removeTaskLabel,
    labels, loadLabels, createTask,
  } = useKanbanStore();

  const { isNamespaceOwner, isAdmin: isPlatformAdmin, canManage } = usePermissions();

  const task = selectedTask && selectedTask.uuid === taskId ? selectedTask : null;

  const [projectRole, setProjectRole] = useState<string | undefined>();
  const [assignableMembers, setAssignableMembers] = useState<KanbanProjectMember[]>([]);
  const [activity, setActivity] = useState<KanbanActivity[]>([]);
  const [menuOpen, setMenuOpen] = useState(false);

  const canEdit =
    projectRole === 'owner' || projectRole === 'admin' || projectRole === 'member' ||
    isNamespaceOwner || isPlatformAdmin || canManage('projects');

  const refresh = useCallback(() => { if (taskId) void loadTask(taskId); }, [taskId, loadTask]);

  useEffect(() => { refresh(); }, [refresh]);

  // Project role (for canEdit), labels, namespace members (assignee source), activity.
  useEffect(() => {
    if (!projectUuid) return;
    let cancelled = false;
    kanbanService.getProject(projectUuid).then((p) => { if (!cancelled) setProjectRole(p.current_user_role); }).catch(() => {});
    void loadLabels(projectUuid);
    namespaceService.getMembers({ perPage: 200, status: 'active' }).then((res) => {
      if (cancelled) return;
      setAssignableMembers(
        (res.data || []).filter((m) => m.user).map((m) => ({
          id: m.id, uuid: m.uuid, project_id: 0, user_uuid: m.user!.uuid, role: 'member',
          joined_at: m.joined_at ?? '', is_starred: false, notification_preference: 'all',
          created_at: m.created_at, updated_at: m.updated_at,
          user: { uuid: m.user!.uuid, first_name: m.user!.first_name, last_name: m.user!.last_name, email: m.user!.email },
        }) as KanbanProjectMember),
      );
    }).catch(() => {});
    return () => { cancelled = true; };
  }, [projectUuid, loadLabels]);

  useEffect(() => {
    if (!taskId) return;
    kanbanService.getTaskActivity(taskId).then(setActivity).catch(() => setActivity([]));
  }, [taskId, task?.updated_at]);

  const patch = useCallback(async (data: Partial<KanbanTask>) => {
    if (!task) return;
    try { await updateTask(task.uuid, data); } catch { toast.error('Failed to update task'); }
  }, [task, updateTask]);

  if (selectedTaskLoading && !task) {
    return <div className="h-[60vh] flex items-center justify-center"><Loader2 className="w-6 h-6 animate-spin text-primary-500" /></div>;
  }
  if (!task) {
    return (
      <div className="max-w-lg mx-auto text-center py-20">
        <p className="text-secondary-600 mb-4">Task not found.</p>
        <button onClick={() => router.push(boardHref)} className="text-primary-600 hover:underline">Back to board</button>
      </div>
    );
  }

  const assignedUuids = new Set((task.assignees ?? []).map((a) => a.user_uuid));
  const labelIds = new Set((task.labels ?? []).map((l) => l.id));
  const subtasks = task.subtasks ?? [];
  const doneSubtasks = subtasks.filter((s) => s.status === 'completed').length;

  return (
    <div className="w-full pb-16">
      {/* Top bar */}
      <div className="flex items-center gap-2 py-3 text-sm">
        <button onClick={() => router.push(boardHref)} className="inline-flex items-center justify-center w-8 h-8 rounded-lg border border-secondary-200 text-secondary-500 hover:text-secondary-800 hover:border-secondary-300 transition-colors" aria-label="Back to board">
          <ArrowLeft className="w-4 h-4" />
        </button>
        <span className="text-secondary-400">{task.project_name || 'Project'}</span>
        <span className="text-secondary-300">/</span>
        <span className="font-mono text-secondary-500">#{task.task_number}</span>
        <div className="ml-auto relative">
          {canEdit && (
            <button onClick={() => setMenuOpen((o) => !o)} className="inline-flex items-center justify-center w-8 h-8 rounded-lg text-secondary-500 hover:bg-secondary-100" aria-label="Task actions">
              <MoreHorizontal className="w-5 h-5" />
            </button>
          )}
          {menuOpen && (
            <>
              <div className="fixed inset-0 z-10" onClick={() => setMenuOpen(false)} />
              <div className="absolute right-0 z-20 mt-1 w-44 rounded-lg border border-secondary-200 bg-surface shadow-lg py-1">
                <button
                  onClick={async () => {
                    setMenuOpen(false);
                    if (!window.confirm('Delete this task?')) return;
                    const ok = await deleteTask(task.uuid);
                    if (ok) { toast.success('Task deleted'); router.push(boardHref); }
                    else toast.error('Failed to delete');
                  }}
                  className="w-full flex items-center gap-2 px-3 py-2 text-sm text-error-600 hover:bg-error-50"
                >
                  <Trash2 size={14} /> Delete task
                </button>
              </div>
            </>
          )}
        </div>
      </div>

      {/* Editable title */}
      <InlineTitle value={task.title} canEdit={canEdit} onSave={(v) => patch({ title: v })} />

      <div className="mt-5 grid grid-cols-1 xl:grid-cols-[minmax(0,1fr)_380px] gap-6 items-start">
        {/* Main column */}
        <div className="min-w-0 space-y-8">
          {/* Description */}
          <section>
            <SectionTitle icon={<span className="w-1.5 h-4 rounded bg-primary-400" />}>Description</SectionTitle>
            <DescriptionEditor value={task.description || ''} canEdit={canEdit} onSave={(v) => patch({ description: v })} />
          </section>

          {/* Subtasks */}
          <section>
            <SectionTitle icon={<ListTree size={16} className="text-secondary-500" />}
              right={subtasks.length > 0 ? <span className="text-xs text-secondary-500 tabular-nums">{doneSubtasks}/{subtasks.length}</span> : undefined}>
              Subtasks
            </SectionTitle>
            {subtasks.length > 0 && (
              <>
                <div className="h-1.5 rounded-full bg-secondary-100 mb-3 overflow-hidden">
                  <div className="h-full bg-green-500 transition-all" style={{ width: `${subtasks.length ? (doneSubtasks / subtasks.length) * 100 : 0}%` }} />
                </div>
                <ul className="space-y-1.5 mb-3">
                  {subtasks.map((s) => (
                    <li key={s.uuid} className="group flex items-center gap-2 rounded-lg border border-secondary-200 px-3 py-2">
                      <button
                        disabled={!canEdit}
                        onClick={() => patchSubtask(s, s.status === 'completed' ? 'open' : 'completed', updateTask, refresh)}
                        className={cn('w-4 h-4 rounded border flex items-center justify-center shrink-0', s.status === 'completed' ? 'bg-green-500 border-green-500 text-white' : 'border-secondary-300', !canEdit && 'opacity-60')}
                      >
                        {s.status === 'completed' && <Check size={11} />}
                      </button>
                      <button onClick={() => router.push(`/dashboard/projects/${projectUuid}/tasks/${s.uuid}`)} className="flex-1 text-left text-sm text-secondary-800 hover:text-primary-600 truncate">
                        <span className="font-mono text-xs text-secondary-400 mr-1">#{s.task_number}</span>
                        <span className={cn(s.status === 'completed' && 'line-through text-secondary-400')}>{s.title}</span>
                      </button>
                      {canEdit && (
                        <button onClick={async () => { await deleteTask(s.uuid); refresh(); }} className="opacity-0 group-hover:opacity-100 text-secondary-400 hover:text-error-500" aria-label="Delete subtask">
                          <X size={14} />
                        </button>
                      )}
                    </li>
                  ))}
                </ul>
              </>
            )}
            {canEdit && (
              <AddInput placeholder="Add a subtask…" onAdd={async (title) => {
                try { await createTask(task.board_uuid || '', { title, parent_task_id: task.id }); refresh(); }
                catch { toast.error('Failed to add subtask'); }
              }} />
            )}
          </section>

          {/* Checklists */}
          <section>
            <SectionTitle icon={<CheckSquare size={16} className="text-secondary-500" />}>Checklists</SectionTitle>
            <div className="space-y-4">
              {(task.checklists ?? []).map((cl) => (
                <div key={cl.uuid} className="rounded-lg border border-secondary-200 p-3">
                  <div className="flex items-center justify-between mb-2">
                    <span className="text-sm font-medium text-secondary-800">{cl.name}</span>
                    <div className="flex items-center gap-2">
                      <span className="text-xs text-secondary-500 tabular-nums">{cl.completed_item_count}/{cl.item_count}</span>
                      {canEdit && <button onClick={async () => { await kanbanService.deleteChecklist(cl.uuid); refresh(); }} className="text-secondary-400 hover:text-error-500" aria-label="Delete checklist"><Trash2 size={13} /></button>}
                    </div>
                  </div>
                  <ul className="space-y-1">
                    {(cl.items ?? []).map((it) => (
                      <li key={it.uuid} className="group flex items-center gap-2 text-sm">
                        <button disabled={!canEdit} onClick={async () => { await kanbanService.toggleChecklistItem(it.uuid); refresh(); }}
                          className={cn('w-4 h-4 rounded border flex items-center justify-center shrink-0', it.is_completed ? 'bg-primary-500 border-primary-500 text-white' : 'border-secondary-300')}>
                          {it.is_completed && <Check size={11} />}
                        </button>
                        <span className={cn('flex-1', it.is_completed && 'line-through text-secondary-400')}>{it.content}</span>
                        {canEdit && <button onClick={async () => { await kanbanService.deleteChecklistItem(it.uuid); refresh(); }} className="opacity-0 group-hover:opacity-100 text-secondary-400 hover:text-error-500"><X size={13} /></button>}
                      </li>
                    ))}
                  </ul>
                  {canEdit && (
                    <div className="mt-2">
                      <AddInput small placeholder="Add item…" onAdd={async (content) => { await kanbanService.addChecklistItem(cl.uuid, { content }); refresh(); }} />
                    </div>
                  )}
                </div>
              ))}
              {canEdit && (
                <AddInput placeholder="Add a checklist…" onAdd={async (name) => { await kanbanService.createChecklist(task.uuid, { name }); refresh(); }} />
              )}
            </div>
          </section>

          {/* Attachments */}
          <section>
            <SectionTitle icon={<Paperclip size={16} className="text-secondary-500" />}>Attachments</SectionTitle>
            <ul className="space-y-1.5 mb-3">
              {(task.attachments ?? []).map((a) => (
                <li key={a.uuid} className="group flex items-center gap-2 rounded-lg border border-secondary-200 px-3 py-2 text-sm">
                  <Link2 size={14} className="text-secondary-400 shrink-0" />
                  <a href={a.file_url} target="_blank" rel="noreferrer" className="flex-1 truncate text-primary-600 hover:underline inline-flex items-center gap-1">
                    {a.file_name} <ExternalLink size={11} />
                  </a>
                  {canEdit && <button onClick={async () => { await kanbanService.deleteAttachment(a.uuid); refresh(); }} className="opacity-0 group-hover:opacity-100 text-secondary-400 hover:text-error-500"><X size={14} /></button>}
                </li>
              ))}
              {(task.attachments ?? []).length === 0 && <li className="text-sm text-secondary-400">No attachments.</li>}
            </ul>
            {canEdit && <AttachmentAdder taskUuid={task.uuid} onAdded={refresh} />}
          </section>

          {/* Comments */}
          <section>
            <SectionTitle icon={<MessageSquare size={16} className="text-secondary-500" />}>Comments ({task.comments?.length ?? 0})</SectionTitle>
            {canEdit && <CommentComposer taskUuid={task.uuid} onAdded={refresh} members={assignableMembers} />}
            <ul className="mt-4 space-y-4">
              {(task.comments ?? []).map((c) => (
                <li key={c.uuid} className="flex gap-3">
                  <Avatar f={c.user?.first_name} l={c.user?.last_name} />
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 text-sm">
                      <span className="font-medium text-secondary-800">{c.user?.first_name} {c.user?.last_name}</span>
                      <span className="text-xs text-secondary-400">{dateTime(c.created_at)}{c.is_edited ? ' · edited' : ''}</span>
                      {canEdit && (
                        <button onClick={async () => { await kanbanService.deleteComment(c.uuid); refresh(); }} className="ml-auto text-secondary-400 hover:text-error-500" aria-label="Delete comment"><Trash2 size={13} /></button>
                      )}
                    </div>
                    <div className="mt-1 text-sm text-secondary-700 rich-content">
                      <RichTextEditor value={c.content} editable={false} />
                    </div>
                  </div>
                </li>
              ))}
            </ul>
          </section>

          {/* Activity */}
          <section>
            <SectionTitle icon={<ActivityIcon size={16} className="text-secondary-500" />}>Activity</SectionTitle>
            <ul className="space-y-2">
              {activity.length === 0 && <li className="text-sm text-secondary-400">No activity yet.</li>}
              {activity.map((a) => (
                <li key={a.uuid} className="flex items-center gap-2 text-xs text-secondary-500">
                  <span className="w-1.5 h-1.5 rounded-full bg-secondary-300 shrink-0" />
                  <span className="font-medium text-secondary-700">{a.user?.first_name || 'Someone'}</span>
                  <span>{a.action.replace(/_/g, ' ')}</span>
                  {a.entity_type && <span className="text-secondary-400">{a.entity_type}</span>}
                  <span className="ml-auto tabular-nums">{dateTime(a.created_at)}</span>
                </li>
              ))}
            </ul>
          </section>
        </div>

        {/* Sidebar */}
        <aside className="space-y-5 lg:sticky lg:top-4">
          <div className="rounded-xl border border-secondary-200 bg-surface p-4 space-y-4">
            {/* Status */}
            <Field label="Status" icon={null}>
              <select disabled={!canEdit} value={task.status} onChange={(e) => patch({ status: e.target.value as KanbanTaskStatus })}
                className={cn('w-full rounded-lg border px-2.5 py-1.5 text-sm capitalize disabled:opacity-70', getTaskStatusColor(task.status))}>
                {STATUSES.map((s) => <option key={s} value={s}>{formatTaskStatus(s)}</option>)}
              </select>
            </Field>

            {/* Assignees */}
            <Field label="Assignees" icon={<Users size={14} />}>
              <div className="flex flex-wrap items-center gap-1.5">
                {(task.assignees ?? []).map((a) => (
                  <span key={a.uuid} className="group inline-flex items-center gap-1 rounded-full bg-secondary-100 pl-0.5 pr-2 py-0.5 text-xs">
                    <Avatar f={a.user?.first_name} l={a.user?.last_name} size={20} />
                    <span className="text-secondary-700">{a.user?.first_name}</span>
                    {canEdit && <button onClick={() => removeTaskAssignee(task.uuid, a.user_uuid)} className="text-secondary-400 hover:text-error-500"><X size={11} /></button>}
                  </span>
                ))}
                {canEdit && (
                  <Picker label="Add">
                    {(close) => assignableMembers.length === 0
                      ? <div className="px-3 py-2 text-xs text-secondary-400">No members</div>
                      : assignableMembers.map((m) => {
                          const on = assignedUuids.has(m.user_uuid);
                          return (
                            <button key={m.user_uuid} onClick={() => { if (on) { removeTaskAssignee(task.uuid, m.user_uuid); } else { addTaskAssignee(task.uuid, m.user_uuid); } close(); }}
                              className="w-full flex items-center gap-2 px-3 py-1.5 text-sm hover:bg-secondary-50">
                              <Avatar f={m.user?.first_name} l={m.user?.last_name} size={22} />
                              <span className="flex-1 text-left truncate">{m.user?.first_name} {m.user?.last_name}</span>
                              {on && <Check size={14} className="text-primary-600" />}
                            </button>
                          );
                        })}
                  </Picker>
                )}
              </div>
            </Field>

            {/* Labels */}
            <Field label="Labels" icon={<Tag size={14} />}>
              <div className="flex flex-wrap items-center gap-1.5">
                {(task.labels ?? []).map((l) => (
                  <span key={l.id} className="group inline-flex items-center gap-1 rounded px-2 py-0.5 text-xs text-white" style={{ backgroundColor: l.color }}>
                    {l.name}
                    {canEdit && <button onClick={() => removeTaskLabel(task.uuid, l.id)}><X size={11} /></button>}
                  </span>
                ))}
                {canEdit && (
                  <Picker label="Add">
                    {(close) => labels.length === 0
                      ? <div className="px-3 py-2 text-xs text-secondary-400">No labels</div>
                      : labels.map((l) => {
                          const on = labelIds.has(l.id);
                          return (
                            <button key={l.id} onClick={() => { if (on) { removeTaskLabel(task.uuid, l.id); } else { addTaskLabel(task.uuid, l.id); } close(); }}
                              className="w-full flex items-center gap-2 px-3 py-1.5 text-sm hover:bg-secondary-50">
                              <span className="w-3 h-3 rounded-full" style={{ backgroundColor: l.color }} />
                              <span className="flex-1 text-left truncate">{l.name}</span>
                              {on && <Check size={14} className="text-primary-600" />}
                            </button>
                          );
                        })}
                  </Picker>
                )}
              </div>
            </Field>

            {/* Priority */}
            <Field label="Priority" icon={<Flag size={14} />}>
              <select disabled={!canEdit} value={task.priority} onChange={(e) => patch({ priority: e.target.value as KanbanTaskPriority })}
                className={cn('w-full rounded-lg border px-2.5 py-1.5 text-sm capitalize disabled:opacity-70', getPriorityColor(task.priority))}>
                {PRIORITIES.map((p) => <option key={p} value={p}>{formatPriority(p)}</option>)}
              </select>
            </Field>

            {/* Due date */}
            <Field label="Due date" icon={<Calendar size={14} />}>
              <input type="date" disabled={!canEdit} value={task.due_date ? String(task.due_date).slice(0, 10) : ''}
                onChange={(e) => patch({ due_date: e.target.value || undefined })}
                className={cn(INPUT, 'disabled:opacity-70')} />
            </Field>

            {/* Story points */}
            <Field label="Story points" icon={<Target size={14} />}>
              <input type="number" min={0} disabled={!canEdit} defaultValue={task.story_points || 0}
                onBlur={(e) => { const v = parseInt(e.target.value) || 0; if (v !== (task.story_points || 0)) patch({ story_points: v }); }}
                className={cn(INPUT, 'w-28 disabled:opacity-70')} style={{ width: '7rem' }} />
            </Field>

            {/* Time tracking */}
            <Field label="Time tracking" icon={<Clock size={14} />} right={canEdit ? <TimerButton task={task} size="sm" onChange={refresh} /> : undefined}>
              <span className="text-sm text-secondary-600">
                Spent: {formatTimeMinutes(task.time_spent_minutes ?? 0)}
                {task.time_estimate_minutes ? ` / ${formatTimeMinutes(task.time_estimate_minutes)}` : ''}
              </span>
            </Field>
          </div>

          {/* Meta */}
          <div className="rounded-xl border border-secondary-200 bg-secondary-50/50 p-4 text-xs text-secondary-500 space-y-1">
            <div>Created {shortDate(task.created_at)}</div>
            <div>Updated {shortDate(task.updated_at)}</div>
          </div>
        </aside>
      </div>
    </div>
  );
}

// Toggle a subtask's completion via updateTask.
function patchSubtask(
  s: KanbanTask, status: KanbanTaskStatus,
  updateTask: (uuid: string, data: Partial<KanbanTask>) => Promise<KanbanTask | null>,
  refresh: () => void,
) {
  void updateTask(s.uuid, { status }).then(refresh);
}

// ── Field wrapper for the sidebar ────────────────────────────────────────────
function Field({ label, icon, right, children }: { label: string; icon: React.ReactNode; right?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div>
      <div className="flex items-center justify-between mb-1.5">
        <span className="inline-flex items-center gap-1.5 text-xs font-medium text-secondary-500">{icon}{label}</span>
        {right}
      </div>
      {children}
    </div>
  );
}

// ── Inline title ─────────────────────────────────────────────────────────────
function InlineTitle({ value, canEdit, onSave }: { value: string; canEdit: boolean; onSave: (v: string) => void }) {
  const [editing, setEditing] = useState(false);
  const [text, setText] = useState(value);
  const start = () => { if (canEdit) { setText(value); setEditing(true); } };
  if (!editing) {
    return (
      <h1 onClick={start} className={cn('text-2xl font-bold text-secondary-900', canEdit && 'cursor-text hover:bg-secondary-50 rounded px-1 -mx-1')}>
        {value}
      </h1>
    );
  }
  return (
    <input
      autoFocus value={text} onChange={(e) => setText(e.target.value)}
      onBlur={() => { setEditing(false); if (text.trim() && text !== value) onSave(text.trim()); }}
      onKeyDown={(e) => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur(); if (e.key === 'Escape') { setText(value); setEditing(false); } }}
      className="w-full text-2xl font-bold text-secondary-900 border-b-2 border-primary-400 focus:outline-none"
    />
  );
}

// ── Description (WYSIWYG, auto-saves ~1s after you stop typing) ───────────────
function DescriptionEditor({ value, canEdit, onSave }: { value: string; canEdit: boolean; onSave: (v: string) => void }) {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastSaved = useRef(value);
  useEffect(() => { lastSaved.current = value; }, [value]);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  if (!canEdit) {
    return value
      ? <div className="rich-content"><RichTextEditor value={value} editable={false} /></div>
      : <p className="text-sm text-secondary-400">No description</p>;
  }
  return (
    <RichTextEditor
      value={value}
      placeholder="Add a description…"
      onChange={(html) => {
        if (timer.current) clearTimeout(timer.current);
        timer.current = setTimeout(() => {
          if (html !== lastSaved.current) { lastSaved.current = html; onSave(html); }
        }, 1000);
      }}
    />
  );
}

// ── Generic add-input (Enter to add) ─────────────────────────────────────────
function AddInput({ placeholder, onAdd, small }: { placeholder: string; onAdd: (v: string) => void | Promise<void>; small?: boolean }) {
  const [v, setV] = useState('');
  const [busy, setBusy] = useState(false);
  const submit = async () => {
    if (!v.trim() || busy) return;
    setBusy(true);
    try { await onAdd(v.trim()); setV(''); } finally { setBusy(false); }
  };
  return (
    <div className="flex items-center gap-2">
      <input value={v} onChange={(e) => setV(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); submit(); } }}
        placeholder={placeholder}
        className={cn('flex-1 rounded-lg border border-secondary-200 bg-secondary-50/60 text-secondary-800 transition focus:bg-surface focus:border-primary-400 focus:outline-none focus:ring-2 focus:ring-primary-500/20', small ? 'px-2.5 py-1.5 text-xs' : 'px-3.5 py-2.5 text-sm')} />
      <button onClick={submit} disabled={!v.trim() || busy} className={cn('rounded-lg bg-primary-600 text-white transition hover:bg-primary-700 disabled:opacity-40', small ? 'p-1.5' : 'p-2.5')} aria-label="Add"><Plus size={small ? 14 : 18} /></button>
    </div>
  );
}

// Pull @mention user UUIDs out of the editor HTML (TipTap Mention renders
// <span data-type="mention" data-id="<uuid>">). Deduped.
function extractMentionUuids(html: string): string[] {
  if (typeof window === 'undefined' || !html.includes('data-type="mention"')) return [];
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const ids = Array.from(doc.querySelectorAll('[data-type="mention"]'))
    .map((el) => el.getAttribute('data-id'))
    .filter((id): id is string => !!id);
  return Array.from(new Set(ids));
}

// ── Comment composer (WYSIWYG rich text + inline @mentions) ──────────────────
function CommentComposer({
  taskUuid, onAdded, members,
}: { taskUuid: string; onAdded: () => void; members: KanbanProjectMember[] }) {
  const [html, setHtml] = useState('');
  const [busy, setBusy] = useState(false);
  const [seed, setSeed] = useState(0); // remount the editor to clear it after posting
  const isEmpty = html.replace(/<[^>]*>/g, '').replace(/&nbsp;/g, '').trim() === '';

  const mentionItems = members
    .filter((m) => m.user)
    .map((m) => ({ id: m.user_uuid, label: `${m.user?.first_name ?? ''} ${m.user?.last_name ?? ''}`.trim() || m.user!.email }));

  const submit = async () => {
    if (isEmpty || busy) return;
    setBusy(true);
    try {
      const mentioned = extractMentionUuids(html);
      await kanbanService.addComment(taskUuid, {
        content: html,
        mentioned_uuids: mentioned.length ? mentioned : undefined,
      });
      setHtml(''); setSeed((s) => s + 1); onAdded();
    } catch { toast.error('Failed to add comment'); } finally { setBusy(false); }
  };

  return (
    <div>
      <RichTextEditor key={seed} value="" onChange={(h) => setHtml(h)} mentionItems={mentionItems} placeholder="Write a comment…  type @ to mention a teammate" />
      <div className="mt-2 flex items-center justify-between gap-2">
        <span className="text-xs text-secondary-400">Type <span className="font-semibold text-secondary-500">@</span> to mention · rich text, links, code &amp; tables supported</span>
        <button onClick={submit} disabled={isEmpty || busy}
          className="inline-flex items-center gap-1.5 rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-primary-700 disabled:opacity-40">
          {busy ? <Loader2 size={15} className="animate-spin" /> : <Send size={15} />} Comment
        </button>
      </div>
    </div>
  );
}

// ── Attachment adder — real file upload (MinIO) + drag/drop, or link reference ─
function AttachmentAdder({ taskUuid, onAdded }: { taskUuid: string; onAdded: () => void }) {
  const [linkOpen, setLinkOpen] = useState(false);
  const [name, setName] = useState('');
  const [url, setUrl] = useState('');
  const [busy, setBusy] = useState(false);
  const [drag, setDrag] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  const uploadFiles = async (files: FileList | File[]) => {
    const list = Array.from(files);
    if (!list.length || busy) return;
    setBusy(true);
    try {
      for (const f of list) await kanbanService.uploadAttachment(taskUuid, f);
      onAdded();
    } catch { toast.error('Upload failed'); } finally { setBusy(false); }
  };

  const submitLink = async () => {
    if (!name.trim() || !url.trim() || busy) return;
    setBusy(true);
    try { await kanbanService.addAttachmentByUrl(taskUuid, { file_name: name.trim(), file_url: url.trim() }); setName(''); setUrl(''); setLinkOpen(false); onAdded(); }
    catch { toast.error('Failed to add link'); } finally { setBusy(false); }
  };

  return (
    <div className="space-y-2">
      <div
        onDragOver={(e) => { e.preventDefault(); setDrag(true); }}
        onDragLeave={() => setDrag(false)}
        onDrop={(e) => { e.preventDefault(); setDrag(false); uploadFiles(e.dataTransfer.files); }}
        onClick={() => !busy && fileRef.current?.click()}
        className={cn(
          'flex cursor-pointer items-center justify-center gap-2 rounded-lg border-2 border-dashed px-3 py-4 text-sm transition-colors',
          drag ? 'border-primary-400 bg-primary-50 text-primary-700' : 'border-secondary-200 text-secondary-500 hover:border-primary-300 hover:text-primary-600'
        )}
      >
        {busy ? <><Loader2 size={16} className="animate-spin" /> Uploading…</> : <><Upload size={16} /> Drop a file or click to upload</>}
      </div>
      <input ref={fileRef} type="file" multiple className="hidden" onChange={(e) => { if (e.target.files) uploadFiles(e.target.files); e.target.value = ''; }} />

      {!linkOpen ? (
        <button onClick={() => setLinkOpen(true)} className="inline-flex items-center gap-1.5 text-sm text-primary-600 hover:underline"><Link2 size={14} /> …or attach a link</button>
      ) : (
        <div className="rounded-lg border border-secondary-200 p-3 space-y-2">
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Name (e.g. Design spec)" className={INPUT} />
          <input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://…" className={INPUT} />
          <div className="flex gap-2">
            <button onClick={submitLink} disabled={!name.trim() || !url.trim() || busy} className="rounded-lg bg-primary-600 px-3 py-1.5 text-sm text-white hover:bg-primary-700 disabled:opacity-40">Attach</button>
            <button onClick={() => setLinkOpen(false)} className="rounded-lg px-3 py-1.5 text-sm text-secondary-600 hover:bg-secondary-100">Cancel</button>
          </div>
        </div>
      )}
    </div>
  );
}
