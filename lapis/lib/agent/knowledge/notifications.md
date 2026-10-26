---
title: Notifications
pages: /dashboard/notifications
api: /api/v2/kanban/notifications
modules: projects
tools:
suggestions: What needs my attention? | Summarise my unread notifications | Mark everything as read
---
# Notifications
Everything the bell shows, as a full list: task assignments, comments, mentions and due dates, newest first, across all your workspaces.

## Using the page
- All / Unread switch at the top; "Mark all read" clears the unread count. Pages of 20.
- Click a notification to mark it read and open what it is about (the task, comment, …). If it belongs to another workspace, the dashboard switches workspace first.

## Rules
- These are the signed-in person's own notifications only.

## API
- `GET /api/v2/kanban/notifications?page&per_page&unread_only=true` — notifications (title, message, type, is_read, created_at); meta.total, meta.unread_count
- `PUT /api/v2/kanban/notifications/{uuid}/read` — mark one read
- `POST /api/v2/kanban/notifications/mark-all-read` — mark all read
