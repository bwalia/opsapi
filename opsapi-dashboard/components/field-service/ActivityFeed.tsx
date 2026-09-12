'use client';

import React from 'react';
import { History } from 'lucide-react';
import { formatFsDateTime, type FsActivity } from '@/services/field-service.service';
import { SectionCard } from './shared';

export function ActivityFeed({ activity }: { activity: FsActivity[] }) {
  return (
    <SectionCard title="Activity">
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
