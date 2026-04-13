'use client';

import React, { useCallback, useMemo, memo } from 'react';
import { cn } from '@/lib/utils';
import { useGridNavigation } from '@/hooks/useGridNavigation';
import { Plus, Loader2, Check, AlertCircle, Trash2 } from 'lucide-react';

// ── Types ─────────────────────────────────────────────────────────────────────

export interface GridColumn {
  key: string;
  header: string;
  width: string;
  type: 'date' | 'text' | 'currency' | 'select' | 'readonly';
  options?: { value: string; label: string }[];
  required?: boolean;
  placeholder?: string;
}

export interface GridRow {
  id: string;
  isNew: boolean;
  isDirty: boolean;
  isSaving: boolean;
  hasError: boolean;
  data: Record<string, string>;
}

interface SpreadsheetGridProps {
  columns: GridColumn[];
  rows: GridRow[];
  onRowChange: (rowIndex: number, field: string, value: string) => void;
  onRowCommit: (rowIndex: number) => void;
  onRowDelete?: (rowIndex: number) => void;
  onAddRow: () => void;
  isLoading?: boolean;
  emptyMessage?: string;
  className?: string;
}

// ── Cell Component ────────────────────────────────────────────────────────────

const GridCell = memo(function GridCell({
  column,
  value,
  isFocused,
  rowIndex,
  colIndex,
  onChange,
  registerRef,
}: {
  column: GridColumn;
  value: string;
  isFocused: boolean;
  rowIndex: number;
  colIndex: number;
  onChange: (value: string) => void;
  registerRef: (row: number, col: number, el: HTMLInputElement | HTMLSelectElement | null) => void;
}) {
  const handleChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
      onChange(e.target.value);
    },
    [onChange]
  );

  // Readonly cells always show display value
  if (column.type === 'readonly') {
    return (
      <div className="px-3 py-2.5 text-sm text-secondary-500 bg-secondary-50/50 h-full flex items-center tabular-nums">
        {value || '-'}
      </div>
    );
  }

  // Select cells
  if (column.type === 'select') {
    return (
      <select
        ref={(el) => registerRef(rowIndex, colIndex, el)}
        value={value}
        onChange={handleChange}
        className={cn(
          'w-full h-full px-3 py-2.5 text-sm border-0 bg-transparent focus:outline-none focus:bg-primary-50/30',
          'appearance-none cursor-pointer',
          isFocused && 'bg-primary-50/30'
        )}
        aria-label={column.header}
      >
        <option value="">{column.placeholder || `Select ${column.header}...`}</option>
        {column.options?.map((opt) => (
          <option key={opt.value} value={opt.value}>
            {opt.label}
          </option>
        ))}
      </select>
    );
  }

  // Text, date, and currency cells
  return (
    <input
      ref={(el) => registerRef(rowIndex, colIndex, el)}
      type={column.type === 'date' ? 'date' : column.type === 'currency' ? 'number' : 'text'}
      value={value}
      onChange={handleChange}
      placeholder={column.placeholder || column.header}
      step={column.type === 'currency' ? '0.01' : undefined}
      min={column.type === 'currency' ? '0' : undefined}
      className={cn(
        'w-full h-full px-3 py-2.5 text-sm border-0 bg-transparent focus:outline-none focus:bg-primary-50/30',
        column.type === 'currency' && 'text-right tabular-nums',
        isFocused && 'bg-primary-50/30'
      )}
      aria-label={column.header}
    />
  );
});

// ── Row Status Indicator ──────────────────────────────────────────────────────

const RowStatus = memo(function RowStatus({
  row,
}: {
  row: GridRow;
}) {
  if (row.isSaving) {
    return (
      <div className="flex items-center justify-center w-6 h-6" title="Saving...">
        <Loader2 className="w-3.5 h-3.5 text-primary-500 animate-spin" />
      </div>
    );
  }
  if (row.hasError) {
    return (
      <div className="flex items-center justify-center w-6 h-6" title="Save failed">
        <AlertCircle className="w-3.5 h-3.5 text-error-500" />
      </div>
    );
  }
  if (!row.isNew && !row.isDirty) {
    return (
      <div className="flex items-center justify-center w-6 h-6" title="Saved">
        <Check className="w-3.5 h-3.5 text-success-500" />
      </div>
    );
  }
  if (row.isDirty) {
    return (
      <div className="flex items-center justify-center w-6 h-6" title="Unsaved changes">
        <div className="w-2 h-2 rounded-full bg-warning-500" />
      </div>
    );
  }
  return <div className="w-6 h-6" />;
});

// ── Main Grid Component ───────────────────────────────────────────────────────

const SpreadsheetGrid: React.FC<SpreadsheetGridProps> = ({
  columns,
  rows,
  onRowChange,
  onRowCommit,
  onRowDelete,
  onAddRow,
  isLoading = false,
  emptyMessage = 'No entries yet. Click "Add Row" or press the + button below to start.',
  className,
}) => {
  const editableColumns = useMemo(
    () => columns
      .map((col, idx) => (col.type !== 'readonly' ? idx : -1))
      .filter((idx) => idx !== -1),
    [columns]
  );

  const { focusedCell, focusCell, registerCellRef, handleKeyDown } = useGridNavigation({
    rowCount: rows.length,
    colCount: columns.length,
    editableColumns,
    onCommitRow: onRowCommit,
    onAddRow,
  });

  const handleCellClick = useCallback(
    (rowIndex: number, colIndex: number) => {
      if (columns[colIndex].type === 'readonly') return;
      focusCell(rowIndex, colIndex);
    },
    [columns, focusCell]
  );

  const gridTemplateColumns = useMemo(
    () => `40px ${columns.map((c) => c.width).join(' ')} ${onRowDelete ? '48px' : ''}`,
    [columns, onRowDelete]
  );

  if (isLoading) {
    return (
      <div className="bg-white rounded-xl border border-secondary-200 p-12" role="status">
        <div className="flex flex-col items-center justify-center gap-3">
          <Loader2 className="w-8 h-8 text-primary-500 animate-spin" aria-hidden="true" />
          <p className="text-secondary-500 text-sm">Loading entries...</p>
        </div>
      </div>
    );
  }

  return (
    <div className={cn('bg-white rounded-xl border border-secondary-200 overflow-hidden', className)}>
      <div
        className="overflow-x-auto"
        role="grid"
        aria-label="Spreadsheet data entry"
        onKeyDown={handleKeyDown}
      >
        {/* Header Row */}
        <div
          className="grid bg-secondary-50 border-b border-secondary-200 sticky top-0 z-10"
          style={{ gridTemplateColumns }}
          role="row"
        >
          <div className="px-2 py-3 text-xs font-semibold text-secondary-400 flex items-center justify-center" role="columnheader">
            #
          </div>
          {columns.map((col) => (
            <div
              key={col.key}
              className="px-3 py-3 text-xs font-semibold text-secondary-600 uppercase tracking-wider flex items-center"
              role="columnheader"
            >
              {col.header}
              {col.required && <span className="text-error-500 ml-0.5">*</span>}
            </div>
          ))}
          {onRowDelete && (
            <div className="px-2 py-3" role="columnheader">
              <span className="sr-only">Actions</span>
            </div>
          )}
        </div>

        {/* Data Rows */}
        {rows.length === 0 ? (
          <div className="px-6 py-12 text-center">
            <p className="text-secondary-500 text-sm">{emptyMessage}</p>
          </div>
        ) : (
          rows.map((row, rowIndex) => (
            <div
              key={row.id}
              className={cn(
                'grid border-b border-secondary-100 transition-colors',
                focusedCell?.row === rowIndex && 'bg-primary-50/20',
                row.isDirty && !row.isNew && 'border-l-2 border-l-warning-400',
                row.hasError && 'border-l-2 border-l-error-400',
                !row.isDirty && !row.isNew && !row.hasError && 'border-l-2 border-l-transparent'
              )}
              style={{ gridTemplateColumns }}
              role="row"
            >
              {/* Row number + status */}
              <div className="px-2 py-1 text-xs text-secondary-400 flex items-center justify-center gap-1 border-r border-secondary-100">
                <RowStatus row={row} />
              </div>

              {/* Data Cells */}
              {columns.map((col, colIndex) => (
                <div
                  key={col.key}
                  className={cn(
                    'border-r border-secondary-100 last:border-r-0 min-h-[44px]',
                    col.type !== 'readonly' && 'cursor-text',
                    focusedCell?.row === rowIndex &&
                      focusedCell?.col === colIndex &&
                      'ring-2 ring-inset ring-primary-500/40'
                  )}
                  onClick={() => handleCellClick(rowIndex, colIndex)}
                  role="gridcell"
                >
                  <GridCell
                    column={col}
                    value={row.data[col.key] || ''}
                    isFocused={
                      focusedCell?.row === rowIndex && focusedCell?.col === colIndex
                    }
                    rowIndex={rowIndex}
                    colIndex={colIndex}
                    onChange={(value) => onRowChange(rowIndex, col.key, value)}
                    registerRef={registerCellRef}
                  />
                </div>
              ))}

              {/* Delete button */}
              {onRowDelete && (
                <div className="flex items-center justify-center">
                  <button
                    onClick={() => onRowDelete(rowIndex)}
                    className="p-2 text-secondary-300 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors min-w-[40px] min-h-[40px] flex items-center justify-center"
                    aria-label={`Delete row ${rowIndex + 1}`}
                    title="Delete row"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                </div>
              )}
            </div>
          ))
        )}

        {/* Add Row Button */}
        <div
          className="grid border-b border-secondary-100 hover:bg-secondary-50 cursor-pointer transition-colors group"
          style={{ gridTemplateColumns }}
          onClick={onAddRow}
          role="row"
          aria-label="Add new row"
        >
          <div className="px-2 py-3 flex items-center justify-center">
            <Plus className="w-4 h-4 text-secondary-300 group-hover:text-primary-500 transition-colors" />
          </div>
          <div
            className="px-3 py-3 text-sm text-secondary-400 group-hover:text-primary-500 transition-colors flex items-center"
            style={{ gridColumn: `span ${columns.length + (onRowDelete ? 1 : 0)}` }}
          >
            Add new entry...
          </div>
        </div>

        {/* Totals Row */}
        <TotalsRow columns={columns} rows={rows} gridTemplateColumns={gridTemplateColumns} hasDelete={!!onRowDelete} />
      </div>

      {/* Footer info */}
      <div className="px-4 py-2.5 bg-secondary-50 border-t border-secondary-200 flex items-center justify-between text-xs text-secondary-500">
        <span>{rows.length} {rows.length === 1 ? 'entry' : 'entries'}</span>
        <span className="hidden sm:inline">Tab to move between cells, Enter to move to next row, Esc to deselect</span>
      </div>
    </div>
  );
};

// ── Totals Row ────────────────────────────────────────────────────────────────

const TotalsRow = memo(function TotalsRow({
  columns,
  rows,
  gridTemplateColumns,
  hasDelete,
}: {
  columns: GridColumn[];
  rows: GridRow[];
  gridTemplateColumns: string;
  hasDelete: boolean;
}) {
  const hasCurrencyColumns = columns.some((c) => c.type === 'currency' || c.type === 'readonly');
  if (!hasCurrencyColumns || rows.length === 0) return null;

  const totals = columns.map((col) => {
    if (col.type !== 'currency' && col.type !== 'readonly') return null;
    const total = rows.reduce((sum, row) => {
      const val = parseFloat(row.data[col.key] || '0');
      return sum + (isNaN(val) ? 0 : val);
    }, 0);
    return total;
  });

  return (
    <div
      className="grid bg-secondary-50 border-t-2 border-secondary-300 font-semibold"
      style={{ gridTemplateColumns }}
      role="row"
      aria-label="Totals"
    >
      <div className="px-2 py-3 text-xs text-secondary-600 flex items-center justify-center">
        &Sigma;
      </div>
      {columns.map((col, idx) => (
        <div
          key={col.key}
          className={cn(
            'px-3 py-3 text-sm border-r border-secondary-200 last:border-r-0',
            (col.type === 'currency' || col.type === 'readonly') ? 'text-right tabular-nums text-secondary-900' : ''
          )}
          role="gridcell"
        >
          {totals[idx] !== null
            ? new Intl.NumberFormat('en-GB', {
                style: 'currency',
                currency: 'GBP',
              }).format(totals[idx]!)
            : idx === 0
            ? 'Totals'
            : ''}
        </div>
      ))}
      {hasDelete && <div className="px-2 py-3" />}
    </div>
  );
});

export default SpreadsheetGrid;
