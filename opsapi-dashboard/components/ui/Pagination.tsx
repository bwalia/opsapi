'use client';

import React from 'react';
import { cn } from '@/lib/utils';
import { ChevronLeft, ChevronRight } from 'lucide-react';

export interface PaginationProps {
  currentPage: number;
  totalPages: number;
  totalItems: number;
  perPage: number;
  onPageChange: (page: number) => void;
  className?: string;
}

const Pagination: React.FC<PaginationProps> = ({
  currentPage,
  totalPages,
  totalItems,
  perPage,
  onPageChange,
  className,
}) => {
  const startItem = (currentPage - 1) * perPage + 1;
  const endItem = Math.min(currentPage * perPage, totalItems);

  const getPageNumbers = (): (number | string)[] => {
    const pages: (number | string)[] = [];
    const maxVisible = 5;

    if (totalPages <= maxVisible) {
      for (let i = 1; i <= totalPages; i++) {
        pages.push(i);
      }
    } else {
      if (currentPage <= 3) {
        for (let i = 1; i <= 4; i++) {
          pages.push(i);
        }
        pages.push('...');
        pages.push(totalPages);
      } else if (currentPage >= totalPages - 2) {
        pages.push(1);
        pages.push('...');
        for (let i = totalPages - 3; i <= totalPages; i++) {
          pages.push(i);
        }
      } else {
        pages.push(1);
        pages.push('...');
        for (let i = currentPage - 1; i <= currentPage + 1; i++) {
          pages.push(i);
        }
        pages.push('...');
        pages.push(totalPages);
      }
    }

    return pages;
  };

  if (totalPages <= 1) return null;

  return (
    <div
      className={cn(
        'flex flex-col sm:flex-row items-center justify-between gap-4 mt-6',
        className
      )}
    >
      <p className="text-sm text-secondary-500">
        Showing <span className="font-medium text-secondary-700">{startItem}</span> to{' '}
        <span className="font-medium text-secondary-700">{endItem}</span> of{' '}
        <span className="font-medium text-secondary-700">{totalItems}</span> results
      </p>

      <nav className="flex items-center gap-1">
        <button
          onClick={() => onPageChange(currentPage - 1)}
          disabled={currentPage === 1}
          className={cn(
            'p-2 rounded-lg transition-colors',
            currentPage === 1
              ? 'text-secondary-300 cursor-not-allowed'
              : 'text-secondary-600 hover:bg-secondary-100 hover:text-secondary-900'
          )}
        >
          <ChevronLeft className="w-5 h-5" />
        </button>

        {getPageNumbers().map((page, index) =>
          typeof page === 'number' ? (
            <button
              key={index}
              onClick={() => onPageChange(page)}
              className={cn(
                'min-w-[40px] h-10 px-3 rounded-lg text-sm font-medium transition-colors',
                page === currentPage
                  ? 'bg-primary-500 text-white'
                  : 'text-secondary-600 hover:bg-secondary-100 hover:text-secondary-900'
              )}
            >
              {page}
            </button>
          ) : (
            <span key={index} className="px-2 text-secondary-400">
              {page}
            </span>
          )
        )}

        <button
          onClick={() => onPageChange(currentPage + 1)}
          disabled={currentPage === totalPages}
          className={cn(
            'p-2 rounded-lg transition-colors',
            currentPage === totalPages
              ? 'text-secondary-300 cursor-not-allowed'
              : 'text-secondary-600 hover:bg-secondary-100 hover:text-secondary-900'
          )}
        >
          <ChevronRight className="w-5 h-5" />
        </button>
      </nav>
    </div>
  );
};

export default Pagination;
