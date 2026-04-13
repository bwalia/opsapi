export { default as NamespaceSwitcher } from './NamespaceSwitcher';
export { default as CreateNamespaceModal } from './CreateNamespaceModal';
export type { CreateNamespaceModalProps } from './CreateNamespaceModal';

// Namespace Details Components
export {
  NamespaceHeader,
  NamespaceStatsCard,
  NamespaceMembersCard,
  NamespaceSettingsCard,
  NamespaceActivityCard,
} from './details';
export type {
  NamespaceHeaderProps,
  NamespaceStatsCardProps,
  NamespaceMembersCardProps,
  NamespaceSettingsCardProps,
  NamespaceActivityCardProps,
  ActivityItem,
} from './details';

// Namespace Members Components
export {
  MembersTable,
  MemberActions,
  InviteMemberModal,
  InvitationsTable,
} from './members';
export type { MemberActionType } from './members';
