'use client';

import React, { useState } from 'react';
import { History, Send } from 'lucide-react';
import toast from 'react-hot-toast';
import { Textarea, Button } from '@/components/ui';
import { fieldService, formatFsDateTime, type FsActivity } from '@/services/field-service.service';
import { SectionCard, apiError } from './shared';

interface ActivityFeedProps {
  activity: FsActivity[];
  /** When set, show a comment box (manager or the engineer booked on the job). */
  jobUuid?: string;
  canComment?: boolean;
  onPosted?: () => void;
}

export function ActivityFeed({ activity, jobUuid, canComment = false, onPosted }: ActivityFeedProps) {
  const [message, setMessage] = useState('');
  const [posting, setPosting] = useState(false);

  const post = async () => {
    const text = message.trim();
    if (!text || !jobUuid) return;
    setPosting(true);
    try {
      await fieldService.addJobComment(jobUuid, text);
      setMessage('');
      toast.success('Comment added');
      onPosted?.();
    } catch (err) {
      toast.error(apiError(err, 'Could not add comment'));
    } finally {
      setPosting(false);
    }
  };

  return (
    <SectionCard title="Activity">
      {canComment && jobUuid && (
        <div className="mb-4 space-y-2">
          <Textarea
            label="Add a comment"
            rows={2}
            value={message}
            onChange={(e) => setMessage(e.target.value)}
            placeholder="Note for the office / next engineer — e.g. found a leak on the return line"
          />
          <div className="flex justify-end">
            <Button size="sm" onClick={post} isLoading={posting} disabled={!message.trim()} leftIcon={<Send className="w-4 h-4" />}>
              Post
            </Button>
          </div>
        </div>
      )}

      {activity.length === 0 ? (
        <p className="text-sm text-secondary-500">No activity yet.</p>
      ) : (
        <ol className="space-y-3">
          {activity.map((a) => (
            <li key={a.uuid} className="flex gap-3">
              <span className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-secondary-100 text-secondary-500">
                <History className="w-3.5 h-3.5" />
              </span>
              <div className="min-w-0">
                <p className="text-sm text-secondary-800">{a.message || a.action.replace(/_/g, ' ')}</p>
                <p className="text-xs text-secondary-500">
                  {a.actor_name || 'System'} · {formatFsDateTime(a.created_at)}
                </p>
              </div>
            </li>
          ))}
        </ol>
      )}
    </SectionCard>
  );
}

export default ActivityFeed;
