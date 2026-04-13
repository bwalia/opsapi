'use client';

import { useState, useCallback, useRef } from 'react';

export interface FocusedCell {
  row: number;
  col: number;
}

interface UseGridNavigationOptions {
  rowCount: number;
  colCount: number;
  editableColumns?: number[]; // indices of editable columns (skip readonly)
  onCommitRow?: (rowIndex: number) => void;
  onAddRow?: () => void;
}

export function useGridNavigation({
  rowCount,
  colCount,
  editableColumns,
  onCommitRow,
  onAddRow,
}: UseGridNavigationOptions) {
  const [focusedCell, setFocusedCell] = useState<FocusedCell | null>(null);
  const cellRefs = useRef<Map<string, HTMLInputElement | HTMLSelectElement>>(new Map());

  const getCellKey = (row: number, col: number) => `${row}-${col}`;

  const registerCellRef = useCallback(
    (row: number, col: number, el: HTMLInputElement | HTMLSelectElement | null) => {
      const key = getCellKey(row, col);
      if (el) {
        cellRefs.current.set(key, el);
      } else {
        cellRefs.current.delete(key);
      }
    },
    []
  );

  const focusCell = useCallback(
    (row: number, col: number) => {
      const key = getCellKey(row, col);
      const el = cellRefs.current.get(key);
      if (el) {
        setFocusedCell({ row, col });
        // Delay focus to allow React to render the input
        requestAnimationFrame(() => {
          el.focus();
          if (el instanceof HTMLInputElement && el.type !== 'date') {
            el.select();
          }
        });
      }
    },
    []
  );

  const getNextEditableCol = useCallback(
    (currentCol: number, direction: 1 | -1): number | null => {
      if (!editableColumns || editableColumns.length === 0) {
        const next = currentCol + direction;
        if (next >= 0 && next < colCount) return next;
        return null;
      }

      const currentIdx = editableColumns.indexOf(currentCol);
      if (currentIdx === -1) {
        // Find nearest in direction
        if (direction === 1) {
          return editableColumns.find((c) => c > currentCol) ?? null;
        } else {
          return [...editableColumns].reverse().find((c) => c < currentCol) ?? null;
        }
      }

      const nextIdx = currentIdx + direction;
      if (nextIdx >= 0 && nextIdx < editableColumns.length) {
        return editableColumns[nextIdx];
      }
      return null;
    },
    [colCount, editableColumns]
  );

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (!focusedCell) return;

      const { row, col } = focusedCell;

      switch (e.key) {
        case 'Tab': {
          e.preventDefault();
          const direction = e.shiftKey ? -1 : 1;
          const nextCol = getNextEditableCol(col, direction as 1 | -1);

          if (nextCol !== null) {
            focusCell(row, nextCol);
          } else if (direction === 1) {
            // Wrap to next row
            if (row < rowCount - 1) {
              const firstCol = editableColumns?.[0] ?? 0;
              onCommitRow?.(row);
              focusCell(row + 1, firstCol);
            } else {
              // Last row, last col - commit and optionally add new row
              onCommitRow?.(row);
              onAddRow?.();
            }
          } else {
            // Wrap to previous row
            if (row > 0) {
              const lastCol = editableColumns?.[editableColumns.length - 1] ?? colCount - 1;
              focusCell(row - 1, lastCol);
            }
          }
          break;
        }

        case 'Enter': {
          e.preventDefault();
          onCommitRow?.(row);
          if (row < rowCount - 1) {
            focusCell(row + 1, col);
          } else {
            onAddRow?.();
          }
          break;
        }

        case 'Escape': {
          e.preventDefault();
          setFocusedCell(null);
          // Blur the current element
          const key = getCellKey(row, col);
          cellRefs.current.get(key)?.blur();
          break;
        }

        case 'ArrowDown': {
          if (e.altKey) return; // Allow alt+arrow for other behaviors
          e.preventDefault();
          if (row < rowCount - 1) {
            focusCell(row + 1, col);
          }
          break;
        }

        case 'ArrowUp': {
          if (e.altKey) return;
          e.preventDefault();
          if (row > 0) {
            focusCell(row - 1, col);
          }
          break;
        }

        case 'ArrowRight': {
          // Only navigate if cursor is at end of input
          const el = cellRefs.current.get(getCellKey(row, col));
          if (el instanceof HTMLInputElement && el.selectionStart !== el.value.length) return;
          const nextCol = getNextEditableCol(col, 1);
          if (nextCol !== null) {
            e.preventDefault();
            focusCell(row, nextCol);
          }
          break;
        }

        case 'ArrowLeft': {
          const elLeft = cellRefs.current.get(getCellKey(row, col));
          if (elLeft instanceof HTMLInputElement && elLeft.selectionStart !== 0) return;
          const prevCol = getNextEditableCol(col, -1);
          if (prevCol !== null) {
            e.preventDefault();
            focusCell(row, prevCol);
          }
          break;
        }
      }
    },
    [focusedCell, rowCount, colCount, editableColumns, focusCell, getNextEditableCol, onCommitRow, onAddRow]
  );

  return {
    focusedCell,
    setFocusedCell,
    focusCell,
    registerCellRef,
    handleKeyDown,
  };
}
