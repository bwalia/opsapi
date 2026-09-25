'use client';

/**
 * App-wide chat real-time owner. Mounted once in DashboardLayout so a new DM or
 * group message notifies you on ANY dashboard page (toast + chime when the tab is
 * visible, an OS notification + chime when it's hidden), not only on /chat.
 *
 * It holds the single chat WebSocket for the tab and re-broadcasts its events to
 * the chat page via store/chat-realtime.store — the page no longer opens its own.
 * The socket stays connected while the tab is hidden; that's what makes
 * background notifications possible (one idle socket per open tab).
 */
import { useCallback, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { useAuthStore } from '@/store/auth.store';
import { useMenuStore } from '@/store/menu.store';
import { useNamespace } from '@/contexts/NamespaceContext';
import { useChatSocket, type ChatWsNewMessage } from '@/hooks/useChatSocket';
import { useChatRealtime, emitChatEvent } from '@/store/chat-realtime.store';
import { senderName } from '@/services/chat.service';
import { notify } from '@/lib/notify';

export default function ChatNotifier() {
  const router = useRouter();
  const myUuid = useAuthStore((s) => (s.user as { uuid?: string } | null)?.uuid);
  // Only users who can see Chat (backend-filtered menu) get a socket.
  const hasChat = useMenuStore((s) => s.menu.some((m) => m.module === 'chat' || m.key === 'chat'));
  const nsId = useNamespace().currentNamespace?.id;

  const openChannel = useCallback(
    (uuid: string) => {
      useChatRealtime.setState({ openRequest: uuid });
      router.push(`/dashboard/chat?c=${encodeURIComponent(uuid)}`);
    },
    [router]
  );

  const onMessage = useCallback(
    (data: ChatWsNewMessage) => {
      emitChatEvent({ type: 'message', data });
      // Other tenants' conversations aren't in the current rail — stay quiet.
      if (data.namespace_id && nsId && data.namespace_id !== nsId) return;
      const m = data.message;
      if (!m || m.user_uuid === myUuid) return;
      const viewing =
        useChatRealtime.getState().activeChannel === data.channel_uuid &&
        document.visibilityState === 'visible';
      if (viewing) return;

      const from = senderName(m);
      const isDm = data.channel_type === 'direct';
      void notify({
        title: isDm || !data.channel_name ? from : `${from} in #${data.channel_name}`,
        body: m.content || '📎 Attachment',
        url: `/dashboard/chat?c=${data.channel_uuid}`,
        tag: `chat-${data.channel_uuid}`,
        onClick: () => openChannel(data.channel_uuid),
      });
    },
    [nsId, myUuid, openChannel]
  );

  const { status } = useChatSocket(
    { onMessage, onReaction: (data) => emitChatEvent({ type: 'reaction', data }) },
    { enabled: !!myUuid && hasChat }
  );

  useEffect(() => {
    useChatRealtime.setState({ status });
  }, [status]);

  return null;
}
