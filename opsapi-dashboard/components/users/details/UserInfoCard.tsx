'use client';

import React, { memo } from 'react';
import { User as UserIcon, Mail, Phone, MapPin, Calendar, Clock } from 'lucide-react';
import { Card } from '@/components/ui';
import { formatDate } from '@/lib/utils';
import type { User } from '@/types';

export interface UserInfoCardProps {
  user: User;
  isLoading?: boolean;
}

interface InfoRowProps {
  icon: React.ReactNode;
  label: string;
  value?: string | null;
  isLink?: boolean;
  href?: string;
}

const InfoRow: React.FC<InfoRowProps> = ({ icon, label, value, isLink, href }) => {
  if (!value) return null;

  return (
    <div className="flex items-start gap-3 py-3 border-b border-secondary-100 last:border-0">
      <div className="w-8 h-8 rounded-lg bg-secondary-100 flex items-center justify-center flex-shrink-0">
        {icon}
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-xs font-medium text-secondary-500 uppercase tracking-wider">{label}</p>
        {isLink && href ? (
          <a
            href={href}
            className="text-sm text-primary-600 hover:text-primary-700 transition-colors truncate block"
          >
            {value}
          </a>
        ) : (
          <p className="text-sm text-secondary-900 truncate">{value}</p>
        )}
      </div>
    </div>
  );
};

const UserInfoCard: React.FC<UserInfoCardProps> = memo(function UserInfoCard({
  user,
  isLoading,
}) {
  if (isLoading) {
    return (
      <Card className="p-6 animate-pulse">
        <div className="h-5 bg-secondary-200 rounded w-32 mb-6" />
        <div className="space-y-4">
          {[1, 2, 3, 4].map((i) => (
            <div key={i} className="flex items-center gap-3">
              <div className="w-8 h-8 rounded-lg bg-secondary-200" />
              <div className="flex-1 space-y-1">
                <div className="h-3 bg-secondary-200 rounded w-20" />
                <div className="h-4 bg-secondary-200 rounded w-40" />
              </div>
            </div>
          ))}
        </div>
      </Card>
    );
  }

  return (
    <Card className="p-6">
      <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
        User Information
      </h3>

      <div className="divide-y divide-secondary-100">
        <InfoRow
          icon={<UserIcon className="w-4 h-4 text-secondary-500" />}
          label="Username"
          value={user.username}
        />
        <InfoRow
          icon={<Mail className="w-4 h-4 text-secondary-500" />}
          label="Email"
          value={user.email}
          isLink
          href={`mailto:${user.email}`}
        />
        <InfoRow
          icon={<Phone className="w-4 h-4 text-secondary-500" />}
          label="Phone"
          value={user.phone_no}
          isLink
          href={user.phone_no ? `tel:${user.phone_no}` : undefined}
        />
        <InfoRow
          icon={<MapPin className="w-4 h-4 text-secondary-500" />}
          label="Address"
          value={user.address}
        />
        <InfoRow
          icon={<Calendar className="w-4 h-4 text-secondary-500" />}
          label="Member Since"
          value={formatDate(user.created_at)}
        />
        <InfoRow
          icon={<Clock className="w-4 h-4 text-secondary-500" />}
          label="Last Updated"
          value={formatDate(user.updated_at)}
        />
      </div>
    </Card>
  );
});

export default UserInfoCard;
