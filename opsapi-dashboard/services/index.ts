export { authService } from './auth.service';
export { usersService } from './users.service';
export { ordersService } from './orders.service';
export { storesService } from './stores.service';
export { productsService } from './products.service';
export { customersService } from './customers.service';
export { dashboardService } from './dashboard.service';
export { rolesService, formatRoleName, getRoleColor, type NamespaceRole, type CreateRoleData, type UpdateRoleData } from './roles.service';
export { permissionsService, DASHBOARD_MODULES, NAMESPACE_MODULES, PERMISSION_ACTIONS } from './permissions.service';
export { modulesService } from './modules.service';
export { namespaceService } from './namespace.service';
export {
  servicesService,
  getServiceStatusColor,
  getDeploymentStatusColor,
  getServiceIcon,
  getServiceColorClass,
  formatDeploymentStatus,
  formatServiceStatus,
} from './services.service';
export {
  notificationService,
  getNotificationTypeLabel,
  getNotificationPriorityColor,
  getNotificationIcon,
  formatNotificationTime,
  groupNotificationsByDate,
} from './notification.service';
export {
  timeTrackingService,
  formatDuration,
  formatDurationLong,
  formatTimerDisplay,
  calculateElapsedSeconds,
  getTimeEntryStatusColor,
  formatHourlyRate,
  calculateBillableAmount,
  formatTimesheetDate,
  getWeekDates,
  getMonthDates,
} from './time-tracking.service';
export {
  sprintService,
  getSprintStatusColor,
  getSprintStatusLabel,
  calculateSprintProgress,
  calculateDaysRemaining,
  calculateSprintDuration,
  formatSprintDateRange,
  calculateIdealBurndown,
  calculateAverageVelocity,
  predictSprintCompletion,
} from './sprint.service';
export {
  analyticsService,
  formatPercentage,
  formatNumber,
  getTrendIndicator,
  getHealthScoreColor,
  getHealthScoreLabel,
  formatActivityAction,
  getDateRange,
  calculateAverageCycleTime,
  getWorkloadLevel,
} from './analytics.service';
export { menuService } from './menu.service';
