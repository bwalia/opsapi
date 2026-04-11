'use client';

import React, { useEffect, useState, useCallback, useMemo, useRef } from 'react';
import { useParams, useRouter, useSearchParams } from 'next/navigation';
import {
  ArrowLeft,
  BarChart3,
  TrendingUp,
  Calendar,
  Target,
  CheckCircle2,
  Clock,
  AlertTriangle,
  Loader2,
  ChevronDown,
  RefreshCw,
} from 'lucide-react';
import { toast } from 'react-hot-toast';
import Button from '@/components/ui/Button';
import Card from '@/components/ui/Card';
import { useKanbanStore } from '@/store/kanban.store';
import {
  sprintService,
  getSprintStatusColor,
  getSprintStatusLabel,
  calculateSprintProgress,
  calculateDaysRemaining,
  calculateSprintDuration,
  formatSprintDateRange,
  calculateIdealBurndown,
} from '@/services/sprint.service';
import type {
  KanbanSprint,
  SprintBurndownPoint,
  VelocityHistory,
  VelocityHistoryItem,
} from '@/types';
import { cn } from '@/lib/utils';

// ============================================
// Types
// ============================================

interface SprintStats {
  total_tasks: number;
  completed_tasks: number;
  in_progress_tasks: number;
  total_points: number;
  completed_points: number;
  remaining_points: number;
  days_remaining: number;
  completion_rate: number;
  velocity: number;
}

// ============================================
// SVG Burndown Chart Component
// ============================================

interface BurndownChartProps {
  burndownData: SprintBurndownPoint[];
  sprint: KanbanSprint;
  totalPoints: number;
}

const BurndownChart = React.memo(function BurndownChart({
  burndownData,
  sprint,
  totalPoints,
}: BurndownChartProps) {
  const [hoveredPoint, setHoveredPoint] = useState<number | null>(null);
  const svgRef = useRef<SVGSVGElement>(null);

  const chartPadding = { top: 30, right: 40, bottom: 50, left: 60 };
  const chartWidth = 800;
  const chartHeight = 400;
  const innerWidth = chartWidth - chartPadding.left - chartPadding.right;
  const innerHeight = chartHeight - chartPadding.top - chartPadding.bottom;

  const durationDays = sprint.start_date && sprint.end_date
    ? calculateSprintDuration(sprint.start_date, sprint.end_date)
    : burndownData.length || 14;

  const maxPoints = Math.max(totalPoints, ...burndownData.map((d) => d.remaining_points), ...burndownData.map((d) => d.total_points));
  const yMax = Math.ceil(maxPoints * 1.1) || 10;

  // Ideal burndown line
  const idealPoints = calculateIdealBurndown(totalPoints, durationDays);

  // Helper: map data to SVG coordinates
  const xScale = (dayIndex: number) => chartPadding.left + (dayIndex / Math.max(durationDays, 1)) * innerWidth;
  const yScale = (points: number) => chartPadding.top + (1 - points / yMax) * innerHeight;

  // Build ideal line path
  const idealLinePath = useMemo(() => {
    if (idealPoints.length === 0) return '';
    return idealPoints
      .map((pt, i) => `${i === 0 ? 'M' : 'L'}${xScale(i).toFixed(1)},${yScale(pt).toFixed(1)}`)
      .join(' ');
  }, [idealPoints, yMax, durationDays]);

  // Build actual line path from burndown data
  const actualLinePath = useMemo(() => {
    if (burndownData.length === 0) return '';
    return burndownData
      .map((pt, i) => `${i === 0 ? 'M' : 'L'}${xScale(i).toFixed(1)},${yScale(pt.remaining_points).toFixed(1)}`)
      .join(' ');
  }, [burndownData, yMax, durationDays]);

  // Check for scope changes
  const hasScopeChanges = burndownData.some((d) => d.added_points > 0 || d.removed_points > 0);

  // Grid lines
  const yGridLines = useMemo(() => {
    const lines: number[] = [];
    const step = Math.ceil(yMax / 5);
    for (let i = 0; i <= yMax; i += step) {
      lines.push(i);
    }
    return lines;
  }, [yMax]);

  const xGridLines = useMemo(() => {
    const lines: number[] = [];
    const step = Math.max(1, Math.ceil(durationDays / 7));
    for (let i = 0; i <= durationDays; i += step) {
      lines.push(i);
    }
    return lines;
  }, [durationDays]);

  // Date labels for x axis
  const getDateLabel = useCallback((dayIndex: number) => {
    if (!sprint.start_date) return `Day ${dayIndex}`;
    const date = new Date(sprint.start_date);
    date.setDate(date.getDate() + dayIndex);
    return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  }, [sprint.start_date]);

  if (burndownData.length === 0 && totalPoints === 0) {
    return (
      <div className="flex flex-col items-center justify-center h-64 text-gray-400">
        <BarChart3 size={32} className="mb-2" />
        <p className="text-sm">No burndown data available yet</p>
        <p className="text-xs mt-1">Data will appear after the sprint starts</p>
      </div>
    );
  }

  return (
    <div className="relative">
      {hasScopeChanges && (
        <div className="flex items-center gap-1.5 mb-2 text-xs text-amber-600 bg-amber-50 px-3 py-1.5 rounded-md inline-flex">
          <AlertTriangle size={12} />
          Scope changes detected during this sprint
        </div>
      )}
      <svg
        ref={svgRef}
        viewBox={`0 0 ${chartWidth} ${chartHeight}`}
        className="w-full h-auto"
        style={{ maxHeight: '400px' }}
      >
        {/* Y axis grid lines */}
        {yGridLines.map((val) => (
          <g key={`y-${val}`}>
            <line
              x1={chartPadding.left}
              y1={yScale(val)}
              x2={chartWidth - chartPadding.right}
              y2={yScale(val)}
              stroke="#e5e7eb"
              strokeWidth="1"
            />
            <text
              x={chartPadding.left - 8}
              y={yScale(val) + 4}
              textAnchor="end"
              className="text-xs fill-gray-500"
              fontSize="11"
            >
              {val}
            </text>
          </g>
        ))}

        {/* X axis grid lines */}
        {xGridLines.map((day) => (
          <g key={`x-${day}`}>
            <line
              x1={xScale(day)}
              y1={chartPadding.top}
              x2={xScale(day)}
              y2={chartHeight - chartPadding.bottom}
              stroke="#e5e7eb"
              strokeWidth="1"
            />
            <text
              x={xScale(day)}
              y={chartHeight - chartPadding.bottom + 18}
              textAnchor="middle"
              className="text-xs fill-gray-500"
              fontSize="10"
            >
              {getDateLabel(day)}
            </text>
          </g>
        ))}

        {/* Axis labels */}
        <text
          x={chartPadding.left - 40}
          y={chartHeight / 2}
          textAnchor="middle"
          transform={`rotate(-90, ${chartPadding.left - 40}, ${chartHeight / 2})`}
          className="text-xs fill-gray-500"
          fontSize="11"
        >
          Remaining Points
        </text>
        <text
          x={chartWidth / 2}
          y={chartHeight - 5}
          textAnchor="middle"
          className="text-xs fill-gray-500"
          fontSize="11"
        >
          Sprint Days
        </text>

        {/* Ideal burndown line (dashed) */}
        {idealLinePath && (
          <path
            d={idealLinePath}
            fill="none"
            stroke="#9ca3af"
            strokeWidth="2"
            strokeDasharray="6,4"
          />
        )}

        {/* Actual burndown line */}
        {actualLinePath && (
          <path
            d={actualLinePath}
            fill="none"
            stroke="#3b82f6"
            strokeWidth="2.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        )}

        {/* Actual data points */}
        {burndownData.map((pt, i) => (
          <g key={`point-${i}`}>
            <circle
              cx={xScale(i)}
              cy={yScale(pt.remaining_points)}
              r={hoveredPoint === i ? 6 : 4}
              fill={hoveredPoint === i ? '#2563eb' : '#3b82f6'}
              stroke="white"
              strokeWidth="2"
              className="cursor-pointer transition-all"
              onMouseEnter={() => setHoveredPoint(i)}
              onMouseLeave={() => setHoveredPoint(null)}
            />

            {/* Scope change indicator */}
            {(pt.added_points > 0 || pt.removed_points > 0) && (
              <circle
                cx={xScale(i)}
                cy={yScale(pt.remaining_points) - 12}
                r={3}
                fill="#f59e0b"
              />
            )}
          </g>
        ))}

        {/* Tooltip */}
        {hoveredPoint !== null && burndownData[hoveredPoint] && (
          <g>
            <rect
              x={Math.min(xScale(hoveredPoint) - 70, chartWidth - chartPadding.right - 150)}
              y={Math.max(yScale(burndownData[hoveredPoint].remaining_points) - 65, chartPadding.top)}
              width="140"
              height="55"
              rx="6"
              fill="white"
              stroke="#e5e7eb"
              strokeWidth="1"
              filter="drop-shadow(0 1px 3px rgba(0,0,0,0.1))"
            />
            <text
              x={Math.min(xScale(hoveredPoint), chartWidth - chartPadding.right - 80)}
              y={Math.max(yScale(burndownData[hoveredPoint].remaining_points) - 45, chartPadding.top + 15)}
              textAnchor="middle"
              fontSize="11"
              className="fill-gray-900 font-medium"
            >
              {getDateLabel(hoveredPoint)}
            </text>
            <text
              x={Math.min(xScale(hoveredPoint), chartWidth - chartPadding.right - 80)}
              y={Math.max(yScale(burndownData[hoveredPoint].remaining_points) - 28, chartPadding.top + 32)}
              textAnchor="middle"
              fontSize="11"
              className="fill-gray-600"
            >
              Remaining: {burndownData[hoveredPoint].remaining_points} pts
            </text>
            {(burndownData[hoveredPoint].added_points > 0) && (
              <text
                x={Math.min(xScale(hoveredPoint), chartWidth - chartPadding.right - 80)}
                y={Math.max(yScale(burndownData[hoveredPoint].remaining_points) - 14, chartPadding.top + 46)}
                textAnchor="middle"
                fontSize="10"
                className="fill-amber-600"
              >
                +{burndownData[hoveredPoint].added_points} added
              </text>
            )}
          </g>
        )}

        {/* Legend */}
        <g transform={`translate(${chartPadding.left + 10}, ${chartPadding.top - 15})`}>
          <line x1="0" y1="0" x2="20" y2="0" stroke="#9ca3af" strokeWidth="2" strokeDasharray="6,4" />
          <text x="26" y="4" fontSize="10" className="fill-gray-500">Ideal</text>
          <line x1="70" y1="0" x2="90" y2="0" stroke="#3b82f6" strokeWidth="2.5" />
          <text x="96" y="4" fontSize="10" className="fill-gray-500">Actual</text>
        </g>
      </svg>
    </div>
  );
});

// ============================================
// SVG Velocity Chart Component
// ============================================

interface VelocityChartProps {
  velocityData: VelocityHistory | null;
}

const VelocityChart = React.memo(function VelocityChart({ velocityData }: VelocityChartProps) {
  const [hoveredBar, setHoveredBar] = useState<number | null>(null);

  if (!velocityData || velocityData.sprints.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center h-64 text-gray-400">
        <TrendingUp size={32} className="mb-2" />
        <p className="text-sm">No velocity data available yet</p>
        <p className="text-xs mt-1">Complete sprints to see velocity history</p>
      </div>
    );
  }

  const chartPadding = { top: 30, right: 30, bottom: 60, left: 50 };
  const chartWidth = 800;
  const chartHeight = 350;
  const innerWidth = chartWidth - chartPadding.left - chartPadding.right;
  const innerHeight = chartHeight - chartPadding.top - chartPadding.bottom;

  const sprints = velocityData.sprints;
  const maxPoints = Math.max(...sprints.map((s) => Math.max(s.total_points, s.completed_points)), 1);
  const yMax = Math.ceil(maxPoints * 1.2);
  const barWidth = Math.min(60, innerWidth / sprints.length * 0.6);
  const barGap = (innerWidth - barWidth * sprints.length) / (sprints.length + 1);

  const yScale = (val: number) => chartPadding.top + (1 - val / yMax) * innerHeight;
  const xCenter = (idx: number) => chartPadding.left + barGap * (idx + 1) + barWidth * idx + barWidth / 2;

  const avgVelocity = velocityData.average_velocity;

  // Grid lines
  const yGridLines = useMemo(() => {
    const lines: number[] = [];
    const step = Math.ceil(yMax / 5);
    for (let i = 0; i <= yMax; i += step) {
      lines.push(i);
    }
    return lines;
  }, [yMax]);

  return (
    <div className="relative">
      <svg
        viewBox={`0 0 ${chartWidth} ${chartHeight}`}
        className="w-full h-auto"
        style={{ maxHeight: '350px' }}
      >
        {/* Y grid lines */}
        {yGridLines.map((val) => (
          <g key={`vy-${val}`}>
            <line
              x1={chartPadding.left}
              y1={yScale(val)}
              x2={chartWidth - chartPadding.right}
              y2={yScale(val)}
              stroke="#e5e7eb"
              strokeWidth="1"
            />
            <text
              x={chartPadding.left - 8}
              y={yScale(val) + 4}
              textAnchor="end"
              fontSize="11"
              className="fill-gray-500"
            >
              {val}
            </text>
          </g>
        ))}

        {/* Average velocity line */}
        {avgVelocity > 0 && (
          <g>
            <line
              x1={chartPadding.left}
              y1={yScale(avgVelocity)}
              x2={chartWidth - chartPadding.right}
              y2={yScale(avgVelocity)}
              stroke="#f59e0b"
              strokeWidth="1.5"
              strokeDasharray="8,4"
            />
            <text
              x={chartWidth - chartPadding.right + 4}
              y={yScale(avgVelocity) + 4}
              fontSize="10"
              className="fill-amber-600"
            >
              Avg: {avgVelocity}
            </text>
          </g>
        )}

        {/* Bars */}
        {sprints.map((sprint, i) => {
          const barX = xCenter(i) - barWidth / 2;
          const completedHeight = (sprint.completed_points / yMax) * innerHeight;
          const totalHeight = (sprint.total_points / yMax) * innerHeight;
          const isHovered = hoveredBar === i;

          return (
            <g
              key={sprint.uuid}
              onMouseEnter={() => setHoveredBar(i)}
              onMouseLeave={() => setHoveredBar(null)}
              className="cursor-pointer"
            >
              {/* Total points bar (background) */}
              <rect
                x={barX}
                y={chartPadding.top + innerHeight - totalHeight}
                width={barWidth}
                height={totalHeight}
                rx="4"
                fill={isHovered ? '#dbeafe' : '#e5e7eb'}
                className="transition-colors"
              />
              {/* Completed points bar (foreground) */}
              <rect
                x={barX}
                y={chartPadding.top + innerHeight - completedHeight}
                width={barWidth}
                height={completedHeight}
                rx="4"
                fill={isHovered ? '#2563eb' : '#3b82f6'}
                className="transition-colors"
              />

              {/* Sprint name label */}
              <text
                x={xCenter(i)}
                y={chartHeight - chartPadding.bottom + 18}
                textAnchor="middle"
                fontSize="10"
                className="fill-gray-500"
                transform={sprints.length > 6 ? `rotate(-30, ${xCenter(i)}, ${chartHeight - chartPadding.bottom + 18})` : ''}
              >
                {sprint.name.length > 12 ? sprint.name.slice(0, 12) + '...' : sprint.name}
              </text>

              {/* Value on top */}
              <text
                x={xCenter(i)}
                y={chartPadding.top + innerHeight - completedHeight - 6}
                textAnchor="middle"
                fontSize="11"
                className="fill-gray-700 font-medium"
              >
                {sprint.completed_points}
              </text>
            </g>
          );
        })}

        {/* Tooltip for hovered bar */}
        {hoveredBar !== null && sprints[hoveredBar] && (
          <g>
            <rect
              x={Math.min(Math.max(xCenter(hoveredBar) - 75, chartPadding.left), chartWidth - chartPadding.right - 150)}
              y={Math.max(yScale(sprints[hoveredBar].total_points) - 70, 5)}
              width="150"
              height="60"
              rx="6"
              fill="white"
              stroke="#e5e7eb"
              strokeWidth="1"
              filter="drop-shadow(0 1px 3px rgba(0,0,0,0.1))"
            />
            <text
              x={Math.min(Math.max(xCenter(hoveredBar), chartPadding.left + 75), chartWidth - chartPadding.right - 75)}
              y={Math.max(yScale(sprints[hoveredBar].total_points) - 50, 22)}
              textAnchor="middle"
              fontSize="11"
              className="fill-gray-900 font-medium"
            >
              {sprints[hoveredBar].name}
            </text>
            <text
              x={Math.min(Math.max(xCenter(hoveredBar), chartPadding.left + 75), chartWidth - chartPadding.right - 75)}
              y={Math.max(yScale(sprints[hoveredBar].total_points) - 34, 38)}
              textAnchor="middle"
              fontSize="10"
              className="fill-blue-600"
            >
              Completed: {sprints[hoveredBar].completed_points} / {sprints[hoveredBar].total_points} pts
            </text>
            <text
              x={Math.min(Math.max(xCenter(hoveredBar), chartPadding.left + 75), chartWidth - chartPadding.right - 75)}
              y={Math.max(yScale(sprints[hoveredBar].total_points) - 18, 54)}
              textAnchor="middle"
              fontSize="10"
              className="fill-gray-500"
            >
              Tasks: {sprints[hoveredBar].completed_task_count ?? '?'} / {sprints[hoveredBar].task_count}
            </text>
          </g>
        )}

        {/* Legend */}
        <g transform={`translate(${chartPadding.left + 10}, ${chartPadding.top - 15})`}>
          <rect x="0" y="-5" width="10" height="10" rx="2" fill="#3b82f6" />
          <text x="14" y="4" fontSize="10" className="fill-gray-500">Completed</text>
          <rect x="80" y="-5" width="10" height="10" rx="2" fill="#e5e7eb" />
          <text x="94" y="4" fontSize="10" className="fill-gray-500">Planned</text>
          <line x1="145" y1="0" x2="165" y2="0" stroke="#f59e0b" strokeWidth="1.5" strokeDasharray="6,4" />
          <text x="170" y="4" fontSize="10" className="fill-gray-500">Avg Velocity</text>
        </g>

        {/* Y axis label */}
        <text
          x={chartPadding.left - 35}
          y={chartHeight / 2}
          textAnchor="middle"
          transform={`rotate(-90, ${chartPadding.left - 35}, ${chartHeight / 2})`}
          fontSize="11"
          className="fill-gray-500"
        >
          Story Points
        </text>
      </svg>
    </div>
  );
});

// ============================================
// Sprint Selector (inline)
// ============================================

interface SprintSelectorProps {
  sprints: KanbanSprint[];
  currentSprintUuid: string;
  onSprintChange: (uuid: string) => void;
}

const SprintSelector = React.memo(function SprintSelector({
  sprints,
  currentSprintUuid,
  onSprintChange,
}: SprintSelectorProps) {
  const [isOpen, setIsOpen] = useState(false);
  const currentSprint = sprints.find((s) => s.uuid === currentSprintUuid);

  return (
    <div className="relative">
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="flex items-center gap-2 px-3 py-2 bg-white border border-gray-200 rounded-lg hover:bg-gray-50 transition-colors"
      >
        <Target size={16} />
        <span className="font-medium text-sm">
          {currentSprint?.name || 'Select Sprint'}
        </span>
        <ChevronDown size={16} />
      </button>

      {isOpen && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setIsOpen(false)} />
          <div className="absolute left-0 mt-1 w-64 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20 max-h-72 overflow-y-auto">
            {sprints.map((sprint) => (
              <button
                key={sprint.uuid}
                onClick={() => {
                  onSprintChange(sprint.uuid);
                  setIsOpen(false);
                }}
                className={cn(
                  'w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-gray-50',
                  sprint.uuid === currentSprintUuid && 'bg-gray-50 font-medium'
                )}
              >
                <Target size={14} />
                <span className="flex-1 text-left truncate">{sprint.name}</span>
                <span className={cn('text-xs px-1.5 py-0.5 rounded-full', getSprintStatusColor(sprint.status))}>
                  {getSprintStatusLabel(sprint.status)}
                </span>
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
});

// ============================================
// Main Burndown & Velocity Page
// ============================================

export default function SprintBurndownPage() {
  const params = useParams();
  const router = useRouter();
  const searchParams = useSearchParams();
  const projectUuid = params.uuid as string;
  const initialSprintUuid = searchParams.get('sprint') || '';

  const { currentProject, projectLoading, loadProject } = useKanbanStore();

  // Data state
  const [sprints, setSprints] = useState<KanbanSprint[]>([]);
  const [sprintsLoading, setSprintsLoading] = useState(true);
  const [currentSprintUuid, setCurrentSprintUuid] = useState(initialSprintUuid);
  const [burndownData, setBurndownData] = useState<SprintBurndownPoint[]>([]);
  const [burndownLoading, setBurndownLoading] = useState(false);
  const [velocityData, setVelocityData] = useState<VelocityHistory | null>(null);
  const [velocityLoading, setVelocityLoading] = useState(false);
  const [sprintStats, setSprintStats] = useState<SprintStats | null>(null);
  const [statsLoading, setStatsLoading] = useState(false);

  const currentSprint = useMemo(
    () => sprints.find((s) => s.uuid === currentSprintUuid) || null,
    [sprints, currentSprintUuid]
  );

  // Load project
  useEffect(() => {
    if (projectUuid) {
      loadProject(projectUuid);
    }
  }, [projectUuid, loadProject]);

  // Load sprints
  useEffect(() => {
    if (!projectUuid) return;
    let cancelled = false;

    const load = async () => {
      setSprintsLoading(true);
      try {
        const response = await sprintService.getSprints(projectUuid);
        if (cancelled) return;
        const sprintList = response.data || [];
        setSprints(sprintList);

        // Auto select
        if (!currentSprintUuid && sprintList.length > 0) {
          const active = sprintList.find((s) => s.status === 'active');
          setCurrentSprintUuid(active?.uuid || sprintList[0].uuid);
        }
      } catch (error) {
        if (!cancelled) {
          console.error('Failed to load sprints:', error);
          toast.error('Failed to load sprints');
        }
      } finally {
        if (!cancelled) setSprintsLoading(false);
      }
    };

    load();
    return () => { cancelled = true; };
  }, [projectUuid, currentSprintUuid]);

  // Load burndown data when sprint changes
  useEffect(() => {
    if (!currentSprintUuid) {
      setBurndownData([]);
      setSprintStats(null);
      return;
    }

    let cancelled = false;

    const load = async () => {
      setBurndownLoading(true);
      setStatsLoading(true);
      try {
        const [burndown, stats] = await Promise.all([
          sprintService.getBurndown(currentSprintUuid),
          sprintService.getSprintStats(currentSprintUuid),
        ]);
        if (cancelled) return;
        setBurndownData(burndown || []);
        setSprintStats({
          total_tasks: stats.total_tasks,
          completed_tasks: stats.completed_tasks,
          in_progress_tasks: stats.in_progress_tasks,
          total_points: stats.total_points,
          completed_points: stats.completed_points,
          remaining_points: stats.remaining_points,
          days_remaining: stats.days_remaining,
          completion_rate: stats.completion_rate,
          velocity: stats.velocity,
        });
      } catch (error) {
        if (!cancelled) {
          console.error('Failed to load burndown:', error);
        }
      } finally {
        if (!cancelled) {
          setBurndownLoading(false);
          setStatsLoading(false);
        }
      }
    };

    load();
    return () => { cancelled = true; };
  }, [currentSprintUuid]);

  // Load velocity data
  useEffect(() => {
    if (!projectUuid) return;
    let cancelled = false;

    const load = async () => {
      setVelocityLoading(true);
      try {
        const velocity = await sprintService.getVelocityHistory(projectUuid, 10);
        if (cancelled) return;
        setVelocityData(velocity);
      } catch (error) {
        if (!cancelled) {
          console.error('Failed to load velocity:', error);
        }
      } finally {
        if (!cancelled) setVelocityLoading(false);
      }
    };

    load();
    return () => { cancelled = true; };
  }, [projectUuid]);

  // Refresh handler
  const handleRefresh = useCallback(() => {
    if (currentSprintUuid) {
      setBurndownLoading(true);
      setStatsLoading(true);
      Promise.all([
        sprintService.getBurndown(currentSprintUuid),
        sprintService.getSprintStats(currentSprintUuid),
        sprintService.getVelocityHistory(projectUuid, 10),
      ]).then(([burndown, stats, velocity]) => {
        setBurndownData(burndown || []);
        setSprintStats({
          total_tasks: stats.total_tasks,
          completed_tasks: stats.completed_tasks,
          in_progress_tasks: stats.in_progress_tasks,
          total_points: stats.total_points,
          completed_points: stats.completed_points,
          remaining_points: stats.remaining_points,
          days_remaining: stats.days_remaining,
          completion_rate: stats.completion_rate,
          velocity: stats.velocity,
        });
        setVelocityData(velocity);
      }).catch(console.error).finally(() => {
        setBurndownLoading(false);
        setStatsLoading(false);
      });
    }
  }, [currentSprintUuid, projectUuid]);

  const isLoading = sprintsLoading || projectLoading;
  const daysRemaining = currentSprint?.end_date ? calculateDaysRemaining(currentSprint.end_date) : 0;

  return (
    <div className="h-full flex flex-col">
      {/* Top Bar */}
      <div className="flex items-center justify-between px-6 py-3 border-b border-gray-200 bg-white">
        <div className="flex items-center gap-3">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => router.push(`/dashboard/projects/${projectUuid}/sprints`)}
          >
            <ArrowLeft size={18} />
          </Button>
          <div>
            <h1 className="text-lg font-bold text-gray-900">
              {currentProject?.name || 'Loading...'} - Sprint Analytics
            </h1>
            <p className="text-xs text-gray-500">Burndown &amp; Velocity Charts</p>
          </div>
        </div>

        <div className="flex items-center gap-3">
          {!sprintsLoading && (
            <SprintSelector
              sprints={sprints}
              currentSprintUuid={currentSprintUuid}
              onSprintChange={setCurrentSprintUuid}
            />
          )}
          <Button
            variant="ghost"
            size="sm"
            onClick={handleRefresh}
            disabled={burndownLoading}
          >
            <RefreshCw size={16} className={burndownLoading ? 'animate-spin' : ''} />
          </Button>
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto p-6 space-y-6">
        {isLoading ? (
          <div className="flex items-center justify-center h-64">
            <Loader2 size={32} className="animate-spin text-gray-400" />
          </div>
        ) : sprints.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-64 text-center">
            <BarChart3 size={48} className="text-gray-300 mb-4" />
            <h2 className="text-lg font-semibold text-gray-900 mb-2">No Sprints Yet</h2>
            <p className="text-sm text-gray-500 mb-4">
              Create sprints from the Sprint Board to see analytics here.
            </p>
            <Button
              variant="primary"
              size="sm"
              onClick={() => router.push(`/dashboard/projects/${projectUuid}/sprints`)}
            >
              Go to Sprint Board
            </Button>
          </div>
        ) : (
          <>
            {/* Sprint Summary Cards */}
            <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
              <Card padding="sm">
                <div className="flex items-center gap-2 mb-1">
                  <Target size={14} className="text-blue-500" />
                  <span className="text-xs text-gray-500">Total Points</span>
                </div>
                <div className="text-xl font-bold text-gray-900">
                  {statsLoading ? '-' : sprintStats?.total_points ?? 0}
                </div>
              </Card>
              <Card padding="sm">
                <div className="flex items-center gap-2 mb-1">
                  <CheckCircle2 size={14} className="text-green-500" />
                  <span className="text-xs text-gray-500">Completed</span>
                </div>
                <div className="text-xl font-bold text-green-600">
                  {statsLoading ? '-' : sprintStats?.completed_points ?? 0}
                </div>
              </Card>
              <Card padding="sm">
                <div className="flex items-center gap-2 mb-1">
                  <AlertTriangle size={14} className="text-orange-500" />
                  <span className="text-xs text-gray-500">Remaining</span>
                </div>
                <div className="text-xl font-bold text-orange-600">
                  {statsLoading ? '-' : sprintStats?.remaining_points ?? 0}
                </div>
              </Card>
              <Card padding="sm">
                <div className="flex items-center gap-2 mb-1">
                  <CheckCircle2 size={14} className="text-blue-500" />
                  <span className="text-xs text-gray-500">Tasks Done</span>
                </div>
                <div className="text-xl font-bold text-gray-900">
                  {statsLoading ? '-' : `${sprintStats?.completed_tasks ?? 0}/${sprintStats?.total_tasks ?? 0}`}
                </div>
              </Card>
              <Card padding="sm">
                <div className="flex items-center gap-2 mb-1">
                  <Clock size={14} className="text-purple-500" />
                  <span className="text-xs text-gray-500">Days Left</span>
                </div>
                <div className="text-xl font-bold text-gray-900">{daysRemaining}</div>
              </Card>
              <Card padding="sm">
                <div className="flex items-center gap-2 mb-1">
                  <TrendingUp size={14} className="text-amber-500" />
                  <span className="text-xs text-gray-500">Avg Velocity</span>
                </div>
                <div className="text-xl font-bold text-gray-900">
                  {velocityLoading ? '-' : velocityData?.average_velocity ?? 0}
                </div>
              </Card>
            </div>

            {/* Sprint progress bar */}
            {currentSprint && sprintStats && (
              <Card padding="sm">
                <div className="flex items-center justify-between mb-2">
                  <div className="flex items-center gap-2">
                    <h3 className="text-sm font-semibold text-gray-900">{currentSprint.name}</h3>
                    <span className={cn('text-xs px-2 py-0.5 rounded-full font-medium', getSprintStatusColor(currentSprint.status))}>
                      {getSprintStatusLabel(currentSprint.status)}
                    </span>
                  </div>
                  {currentSprint.start_date && currentSprint.end_date && (
                    <span className="text-xs text-gray-500">
                      {formatSprintDateRange(currentSprint.start_date, currentSprint.end_date)}
                    </span>
                  )}
                </div>
                <div className="h-2 bg-gray-200 rounded-full overflow-hidden">
                  <div
                    className="h-full bg-primary-500 rounded-full transition-all"
                    style={{ width: `${calculateSprintProgress(sprintStats.completed_points, sprintStats.total_points)}%` }}
                  />
                </div>
                <div className="flex justify-between text-xs text-gray-500 mt-1">
                  <span>{sprintStats.completion_rate}% complete</span>
                  <span>{sprintStats.completed_points} / {sprintStats.total_points} story points</span>
                </div>
              </Card>
            )}

            {/* Burndown Chart */}
            <Card>
              <div className="flex items-center justify-between mb-4">
                <h2 className="text-base font-bold text-gray-900 flex items-center gap-2">
                  <BarChart3 size={18} className="text-blue-500" />
                  Sprint Burndown
                </h2>
                {currentSprint && (
                  <span className="text-xs text-gray-500">{currentSprint.name}</span>
                )}
              </div>
              {burndownLoading ? (
                <div className="flex items-center justify-center h-64">
                  <Loader2 size={24} className="animate-spin text-gray-400" />
                </div>
              ) : currentSprint ? (
                <BurndownChart
                  burndownData={burndownData}
                  sprint={currentSprint}
                  totalPoints={sprintStats?.total_points || currentSprint.total_points}
                />
              ) : (
                <div className="flex items-center justify-center h-64 text-sm text-gray-400">
                  Select a sprint to view burndown chart
                </div>
              )}
            </Card>

            {/* Velocity Chart */}
            <Card>
              <div className="flex items-center justify-between mb-4">
                <h2 className="text-base font-bold text-gray-900 flex items-center gap-2">
                  <TrendingUp size={18} className="text-amber-500" />
                  Velocity History
                </h2>
                {velocityData && (
                  <span className="text-xs text-gray-500">
                    Last {velocityData.sprint_count} sprints
                  </span>
                )}
              </div>
              {velocityLoading ? (
                <div className="flex items-center justify-center h-64">
                  <Loader2 size={24} className="animate-spin text-gray-400" />
                </div>
              ) : (
                <VelocityChart velocityData={velocityData} />
              )}
            </Card>

            {/* Sprint history table */}
            {velocityData && velocityData.sprints.length > 0 && (
              <Card>
                <h2 className="text-base font-bold text-gray-900 mb-4 flex items-center gap-2">
                  <Calendar size={18} className="text-gray-500" />
                  Sprint History
                </h2>
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-gray-200">
                        <th className="text-left py-2 px-3 text-xs font-semibold text-gray-500 uppercase tracking-wider">Sprint</th>
                        <th className="text-center py-2 px-3 text-xs font-semibold text-gray-500 uppercase tracking-wider">Status</th>
                        <th className="text-center py-2 px-3 text-xs font-semibold text-gray-500 uppercase tracking-wider">Dates</th>
                        <th className="text-center py-2 px-3 text-xs font-semibold text-gray-500 uppercase tracking-wider">Planned</th>
                        <th className="text-center py-2 px-3 text-xs font-semibold text-gray-500 uppercase tracking-wider">Completed</th>
                        <th className="text-center py-2 px-3 text-xs font-semibold text-gray-500 uppercase tracking-wider">Tasks</th>
                        <th className="text-center py-2 px-3 text-xs font-semibold text-gray-500 uppercase tracking-wider">Velocity</th>
                      </tr>
                    </thead>
                    <tbody>
                      {velocityData.sprints.map((sprint) => (
                        <tr key={sprint.uuid} className="border-b border-gray-100 hover:bg-gray-50">
                          <td className="py-2 px-3 font-medium text-gray-900">{sprint.name}</td>
                          <td className="py-2 px-3 text-center">
                            <span className={cn('text-xs px-2 py-0.5 rounded-full', getSprintStatusColor(sprint.status))}>
                              {getSprintStatusLabel(sprint.status)}
                            </span>
                          </td>
                          <td className="py-2 px-3 text-center text-xs text-gray-500">
                            {sprint.start_date && sprint.end_date
                              ? formatSprintDateRange(sprint.start_date, sprint.end_date)
                              : '-'}
                          </td>
                          <td className="py-2 px-3 text-center">{sprint.total_points}</td>
                          <td className="py-2 px-3 text-center font-medium text-green-600">{sprint.completed_points}</td>
                          <td className="py-2 px-3 text-center">
                            {sprint.completed_task_count ?? '?'}/{sprint.task_count}
                          </td>
                          <td className="py-2 px-3 text-center font-medium">
                            {sprint.velocity ?? (sprint.total_points > 0
                              ? Math.round((sprint.completed_points / sprint.total_points) * 100) + '%'
                              : '-')}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </Card>
            )}
          </>
        )}
      </div>
    </div>
  );
}
