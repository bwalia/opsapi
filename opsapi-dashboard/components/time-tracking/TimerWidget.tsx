'use client';

import React, { useState, useEffect, useCallback, memo } from 'react';
import { Play, Square, Clock, Pause, X, ChevronDown, ChevronUp } from 'lucide-react';
import { cn } from '@/lib/utils';
import { timeTrackingService, formatTimerDisplay, calculateElapsedSeconds } from '@/services/time-tracking.service';
import type { RunningTimer, KanbanTask } from '@/types';
import toast from 'react-hot-toast';

// ============================================
// Timer Button Component (Compact)
// ============================================

interface TimerButtonProps {
  task: KanbanTask;
  size?: 'sm' | 'md';
  className?: string;
}

export const TimerButton = memo(function TimerButton({
  task,
  size = 'sm',
  className,
}: TimerButtonProps) {
  const [isRunning, setIsRunning] = useState(false);
  const [runningTimer, setRunningTimer] = useState<RunningTimer | null>(null);
  const [isLoading, setIsLoading] = useState(false);

  // Check if there's a running timer for this task
  useEffect(() => {
    const checkTimer = async () => {
      try {
        const timer = await timeTrackingService.getRunningTimer();
        if (timer && timer.task_uuid === task.uuid) {
          setRunningTimer(timer);
          setIsRunning(true);
        } else {
          setRunningTimer(null);
          setIsRunning(false);
        }
      } catch {
        // Ignore errors
      }
    };

    checkTimer();
  }, [task.uuid]);

  const handleToggle = useCallback(async () => {
    setIsLoading(true);

    try {
      if (isRunning) {
        await timeTrackingService.stopTimer();
        setRunningTimer(null);
        setIsRunning(false);
        toast.success('Timer stopped');
      } else {
        const timer = await timeTrackingService.startTimer(task.uuid);
        setRunningTimer(timer);
        setIsRunning(true);
        toast.success('Timer started');
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to toggle timer';
      toast.error(message);
    } finally {
      setIsLoading(false);
    }
  }, [isRunning, task.uuid]);

  const sizeClasses = {
    sm: 'p-1.5',
    md: 'p-2',
  };

  const iconSizes = {
    sm: 'w-3.5 h-3.5',
    md: 'w-4 h-4',
  };

  return (
    <button
      onClick={(e) => {
        e.stopPropagation();
        handleToggle();
      }}
      disabled={isLoading}
      className={cn(
        'rounded-lg transition-colors',
        isRunning
          ? 'bg-error-100 text-error-600 hover:bg-error-200'
          : 'bg-primary-100 text-primary-600 hover:bg-primary-200',
        sizeClasses[size],
        isLoading && 'opacity-50 cursor-not-allowed',
        className
      )}
      title={isRunning ? 'Stop timer' : 'Start timer'}
    >
      {isRunning ? (
        <Square className={iconSizes[size]} />
      ) : (
        <Play className={iconSizes[size]} />
      )}
    </button>
  );
});

// ============================================
// Global Timer Widget Component
// ============================================

interface GlobalTimerWidgetProps {
  className?: string;
}

export const GlobalTimerWidget = memo(function GlobalTimerWidget({
  className,
}: GlobalTimerWidgetProps) {
  const [runningTimer, setRunningTimer] = useState<RunningTimer | null>(null);
  const [elapsedSeconds, setElapsedSeconds] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isExpanded, setIsExpanded] = useState(false);

  // Poll for running timer
  useEffect(() => {
    const checkTimer = async () => {
      try {
        const timer = await timeTrackingService.getRunningTimer();
        setRunningTimer(timer);
        if (timer) {
          setElapsedSeconds(calculateElapsedSeconds(timer.started_at));
        }
      } catch {
        // Ignore errors
      }
    };

    checkTimer();
    const interval = setInterval(checkTimer, 60000); // Check every minute

    return () => clearInterval(interval);
  }, []);

  // Update elapsed time every second when timer is running
  useEffect(() => {
    if (!runningTimer) {
      setElapsedSeconds(0);
      return;
    }

    const interval = setInterval(() => {
      setElapsedSeconds(calculateElapsedSeconds(runningTimer.started_at));
    }, 1000);

    return () => clearInterval(interval);
  }, [runningTimer]);

  const handleStop = useCallback(async () => {
    setIsLoading(true);
    try {
      await timeTrackingService.stopTimer();
      setRunningTimer(null);
      setElapsedSeconds(0);
      toast.success('Timer stopped and time entry saved');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to stop timer';
      toast.error(message);
    } finally {
      setIsLoading(false);
    }
  }, []);

  const handleDiscard = useCallback(async () => {
    setIsLoading(true);
    try {
      await timeTrackingService.discardTimer();
      setRunningTimer(null);
      setElapsedSeconds(0);
      toast.success('Timer discarded');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to discard timer';
      toast.error(message);
    } finally {
      setIsLoading(false);
    }
  }, []);

  if (!runningTimer) {
    return null;
  }

  return (
    <div
      className={cn(
        'fixed bottom-6 right-6 bg-white rounded-xl shadow-xl border border-secondary-200 z-40 overflow-hidden transition-all',
        isExpanded ? 'w-80' : 'w-auto',
        className
      )}
    >
      {/* Compact View */}
      <div className="flex items-center gap-3 p-3">
        {/* Pulsing indicator */}
        <div className="relative flex-shrink-0">
          <div className="w-10 h-10 bg-primary-100 rounded-lg flex items-center justify-center">
            <Clock className="w-5 h-5 text-primary-600" />
          </div>
          <span className="absolute -top-0.5 -right-0.5 w-3 h-3 bg-error-500 rounded-full animate-pulse" />
        </div>

        {/* Timer display */}
        <div className="flex-1 min-w-0">
          <p className="text-lg font-mono font-semibold text-secondary-900">
            {formatTimerDisplay(elapsedSeconds)}
          </p>
          {!isExpanded && runningTimer.task_title && (
            <p className="text-xs text-secondary-500 truncate max-w-[120px]">
              {runningTimer.task_title}
            </p>
          )}
        </div>

        {/* Actions */}
        <div className="flex items-center gap-1">
          <button
            onClick={handleStop}
            disabled={isLoading}
            className="p-2 bg-error-100 text-error-600 hover:bg-error-200 rounded-lg transition-colors"
            title="Stop timer"
          >
            <Square className="w-4 h-4" />
          </button>
          <button
            onClick={() => setIsExpanded(!isExpanded)}
            className="p-2 text-secondary-400 hover:text-secondary-600 hover:bg-secondary-100 rounded-lg transition-colors"
          >
            {isExpanded ? (
              <ChevronDown className="w-4 h-4" />
            ) : (
              <ChevronUp className="w-4 h-4" />
            )}
          </button>
        </div>
      </div>

      {/* Expanded View */}
      {isExpanded && (
        <div className="border-t border-secondary-200 p-3">
          <div className="space-y-2">
            {runningTimer.task_title && (
              <div>
                <p className="text-xs text-secondary-500">Task</p>
                <p className="text-sm font-medium text-secondary-900 truncate">
                  #{runningTimer.task_number} {runningTimer.task_title}
                </p>
              </div>
            )}
            {runningTimer.project_name && (
              <div>
                <p className="text-xs text-secondary-500">Project</p>
                <p className="text-sm text-secondary-700">{runningTimer.project_name}</p>
              </div>
            )}
            <div>
              <p className="text-xs text-secondary-500">Started</p>
              <p className="text-sm text-secondary-700">
                {new Date(runningTimer.started_at).toLocaleTimeString()}
              </p>
            </div>
          </div>

          <div className="flex gap-2 mt-4">
            <button
              onClick={handleDiscard}
              disabled={isLoading}
              className="flex-1 py-2 text-sm font-medium text-secondary-600 hover:bg-secondary-100 rounded-lg transition-colors"
            >
              <X className="w-4 h-4 inline-block mr-1" />
              Discard
            </button>
            <button
              onClick={handleStop}
              disabled={isLoading}
              className="flex-1 py-2 text-sm font-medium text-white bg-primary-600 hover:bg-primary-700 rounded-lg transition-colors"
            >
              <Square className="w-4 h-4 inline-block mr-1" />
              Stop & Save
            </button>
          </div>
        </div>
      )}
    </div>
  );
});

// ============================================
// Timer Display Component (Inline)
// ============================================

interface TimerDisplayProps {
  startTime: string;
  className?: string;
}

export const TimerDisplay = memo(function TimerDisplay({
  startTime,
  className,
}: TimerDisplayProps) {
  const [elapsed, setElapsed] = useState(calculateElapsedSeconds(startTime));

  useEffect(() => {
    const interval = setInterval(() => {
      setElapsed(calculateElapsedSeconds(startTime));
    }, 1000);

    return () => clearInterval(interval);
  }, [startTime]);

  return (
    <span className={cn('font-mono text-primary-600', className)}>
      {formatTimerDisplay(elapsed)}
    </span>
  );
});

export default GlobalTimerWidget;
