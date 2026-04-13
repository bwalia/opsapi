'use client';

import React, { memo } from 'react';
import { cn } from '@/lib/utils';
import { formatRoleName, getRoleColor } from '@/services/roles.service';
import { Shield } from 'lucide-react';

interface RoleBadgeProps {
  roleName: string;
  size?: 'sm' | 'md' | 'lg';
  showIcon?: boolean;
  className?: string;
}

const RoleBadge: React.FC<RoleBadgeProps> = memo(function RoleBadge({
  roleName,
  size = 'md',
  showIcon = true,
  className,
}) {
  const sizeClasses = {
    sm: 'px-1.5 py-0.5 text-xs',
    md: 'px-2 py-1 text-xs',
    lg: 'px-3 py-1.5 text-sm',
  };

  const iconSizes = {
    sm: 'w-3 h-3',
    md: 'w-3.5 h-3.5',
    lg: 'w-4 h-4',
  };

  return (
    <span
      className={cn(
        'inline-flex items-center gap-1 font-medium rounded-full border',
        sizeClasses[size],
        getRoleColor(roleName),
        className
      )}
    >
      {showIcon && <Shield className={iconSizes[size]} />}
      {formatRoleName(roleName)}
    </span>
  );
});

export default RoleBadge;
