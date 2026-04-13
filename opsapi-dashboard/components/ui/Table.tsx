'use client';

import React from 'react';
import { cn } from '@/lib/utils';
import { ChevronUp, ChevronDown, Loader2 } from 'lucide-react';
import type { TableColumn } from '@/types';

export interface TableProps<T> {
  columns: TableColumn<T>[];
  data: T[];
  keyExtractor: (item: T) => string | number;
  onRowClick?: (item: T) => void;
  sortColumn?: string;
  sortDirection?: 'asc' | 'desc';
  onSort?: (column: string) => void;
  isLoading?: boolean;
  emptyMessage?: string;
  className?: string;
  caption?: string;
}

function Table<T>({
  columns,
  data,
  keyExtractor,
  onRowClick,
  sortColumn,
  sortDirection,
  onSort,
  isLoading = false,
  emptyMessage = 'No data found',
  className,
  caption,
}: TableProps<T>) {
  const renderSortIcon = (column: TableColumn<T>) => {
    if (!column.sortable) return null;

    const isActive = sortColumn === column.key;
    return (
      <span className="ml-1.5 inline-flex flex-col" aria-hidden="true">
        <ChevronUp
          className={cn(
            'w-3 h-3 -mb-1',
            isActive && sortDirection === 'asc' ? 'text-primary-500' : 'text-secondary-300'
          )}
        />
        <ChevronDown
          className={cn(
            'w-3 h-3',
            isActive && sortDirection === 'desc' ? 'text-primary-500' : 'text-secondary-300'
          )}
        />
      </span>
    );
  };

  const getAriaSortValue = (column: TableColumn<T>): 'ascending' | 'descending' | 'none' | undefined => {
    if (!column.sortable) return undefined;
    if (sortColumn !== column.key) return 'none';
    return sortDirection === 'asc' ? 'ascending' : 'descending';
  };

  if (isLoading) {
    return (
      <div className="bg-white rounded-xl border border-secondary-200 p-12" role="status">
        <div className="flex flex-col items-center justify-center gap-3">
          <Loader2 className="w-8 h-8 text-primary-500 animate-spin" aria-hidden="true" />
          <p className="text-secondary-500 text-sm">Loading data...</p>
        </div>
      </div>
    );
  }

  return (
    <div className={cn('bg-white rounded-xl border border-secondary-200 overflow-hidden', className)}>
      <div className="overflow-x-auto" tabIndex={0} role="region" aria-label={caption || 'Data table'}>
        <table className="w-full">
          {caption && <caption className="sr-only">{caption}</caption>}
          <thead>
            <tr className="bg-secondary-50 border-b border-secondary-200">
              {columns.map((column) => (
                <th
                  key={String(column.key)}
                  scope="col"
                  aria-sort={getAriaSortValue(column)}
                  className={cn(
                    'px-6 py-4 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider',
                    column.sortable && 'cursor-pointer hover:bg-secondary-100 select-none',
                    column.width
                  )}
                  onClick={() => column.sortable && onSort?.(String(column.key))}
                  onKeyDown={(e) => {
                    if (column.sortable && (e.key === 'Enter' || e.key === ' ')) {
                      e.preventDefault();
                      onSort?.(String(column.key));
                    }
                  }}
                  tabIndex={column.sortable ? 0 : undefined}
                  role={column.sortable ? 'columnheader button' : 'columnheader'}
                >
                  <div className="flex items-center">
                    {column.header}
                    {renderSortIcon(column)}
                  </div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-secondary-100">
            {data.length === 0 ? (
              <tr>
                <td colSpan={columns.length} className="px-6 py-12 text-center">
                  <p className="text-secondary-500">{emptyMessage}</p>
                </td>
              </tr>
            ) : (
              data.map((item) => (
                <tr
                  key={keyExtractor(item)}
                  className={cn(
                    'hover:bg-secondary-50 transition-colors',
                    onRowClick && 'cursor-pointer'
                  )}
                  onClick={() => onRowClick?.(item)}
                  onKeyDown={(e) => {
                    if (onRowClick && (e.key === 'Enter' || e.key === ' ')) {
                      e.preventDefault();
                      onRowClick(item);
                    }
                  }}
                  tabIndex={onRowClick ? 0 : undefined}
                  role={onRowClick ? 'button' : undefined}
                >
                  {columns.map((column) => (
                    <td
                      key={String(column.key)}
                      className={cn('px-6 py-4 text-sm text-secondary-900', column.width)}
                    >
                      {column.render
                        ? column.render(item)
                        : String((item as Record<string, unknown>)[String(column.key)] ?? '-')}
                    </td>
                  ))}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export default Table;
