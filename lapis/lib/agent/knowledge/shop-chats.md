---
title: Shop AI chats
pages: /dashboard/shop/chats
api: /api/v2/shop/admin/chats
modules: shop
tools:
suggestions: Summarise this week's shop chats | Find chats that mention warranty | Which chats led to a quote or order?
readonly: true
---
# Shop AI chats
Read-only transcripts of conversations between shop visitors and the shop's AI sales assistant. Each session may link to a cart, a quote and/or an order.

## Using the page
- List: search by email or message text; each row shows the first visitor message and badges Order / Quote / Cart. Click a row for the transcript.
- Transcript page: messages, "Linked" panel (Email, Cart, Quote, Order, Messages, Last activity) and a Summary. "Chats" goes back.

## Rules
- Nothing can be changed here — only read and summarise. To act on a linked quote or order, open it from the Linked panel.

## API
- `GET /api/v2/shop/admin/chats?q&with_messages_only=true&limit&offset` — sessions (email, message_count, first_user_message, quote_number, order_number; limit ≤200)
- `GET /api/v2/shop/admin/chats/{uuid}` — one session with all messages
