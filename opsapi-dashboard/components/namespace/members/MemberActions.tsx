'use client';

import React, { memo, useState, useRef, useEffect } from 'react';
import {
  MoreVertical,
  UserCog,
  UserMinus,
  Shield,
  Crown,
  Ban,
  CheckCircle,
} from 'lucide-react';
import { Button } from '@/components/ui';
import type { NamespaceMember } from '@/types';

export type MemberActionType =
  | 'edit-roles'
  | 'remove'
  | 'suspend'
  | 'activate'
  | 'transfer-ownership';

interface MemberActionsProps {
  member: NamespaceMember;
  onAction: (action: MemberActionType, member: NamespaceMember) => void;
  isOwner?: boolean;
  disabled?: boolean;
}

interface ActionItem {
  action: MemberActionType;
  label: string;
  icon: React.ElementType;
  variant?: 'default' | 'danger' | 'warning';
  condition?: (member: NamespaceMember, isOwner: boolean) => boolean;
}

const actionItems: ActionItem[] = [
  {
    action: 'edit-roles',
    label: 'Edit Roles',
    icon: UserCog,
    condition: (member) => member.status === 'active' && !member.is_owner,
  },
  {
    action: 'suspend',
    label: 'Suspend Member',
    icon: Ban,
    variant: 'warning',
    condition: (member) => member.status === 'active' && !member.is_owner,
  },
  {
    action: 'activate',
    label: 'Activate Member',
    icon: CheckCircle,
    condition: (member) => member.status === 'suspended',
  },
  {
    action: 'transfer-ownership',
    label: 'Transfer Ownership',
    icon: Crown,
    variant: 'warning',
    condition: (member, isOwner) => isOwner && member.status === 'active' && !member.is_owner,
  },
  {
    action: 'remove',
    label: 'Remove from Namespace',
    icon: UserMinus,
    variant: 'danger',
    condition: (member) => !member.is_owner,
  },
];

export const MemberActions = memo(function MemberActions({
  member,
  onAction,
  isOwner = false,
  disabled = false,
}: MemberActionsProps) {
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  // Close dropdown when clicking outside
  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    }

    if (isOpen) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [isOpen]);

  // Close on escape
  useEffect(() => {
    function handleEscape(event: KeyboardEvent) {
      if (event.key === 'Escape') {
        setIsOpen(false);
      }
    }

    if (isOpen) {
      document.addEventListener('keydown', handleEscape);
      return () => document.removeEventListener('keydown', handleEscape);
    }
  }, [isOpen]);

  const availableActions = actionItems.filter(
    (item) => !item.condition || item.condition(member, isOwner)
  );

  if (availableActions.length === 0 || member.is_owner) {
    return null;
  }

  const handleAction = (action: MemberActionType) => {
    setIsOpen(false);
    onAction(action, member);
  };

  return (
    <div className="relative" ref={dropdownRef}>
      <Button
        variant="ghost"
        size="sm"
        className="p-1.5 h-auto"
        onClick={() => setIsOpen(!isOpen)}
        disabled={disabled}
        aria-label="Member actions"
        aria-haspopup="true"
        aria-expanded={isOpen}
      >
        <MoreVertical className="w-4 h-4" />
      </Button>

      {isOpen && (
        <div
          className="absolute right-0 mt-1 w-56 bg-white rounded-lg shadow-lg border border-secondary-200 py-1 z-50"
          role="menu"
          aria-orientation="vertical"
        >
          {availableActions.map((item) => {
            const Icon = item.icon;
            const variantClasses = {
              default: 'text-secondary-700 hover:bg-secondary-50',
              warning: 'text-warning-600 hover:bg-warning-50',
              danger: 'text-error-600 hover:bg-error-50',
            };

            return (
              <button
                key={item.action}
                className={`w-full flex items-center gap-2 px-3 py-2 text-sm transition-colors ${
                  variantClasses[item.variant || 'default']
                }`}
                onClick={() => handleAction(item.action)}
                role="menuitem"
              >
                <Icon className="w-4 h-4" />
                <span>{item.label}</span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
});

export default MemberActions;
