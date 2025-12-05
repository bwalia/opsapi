'use client';

import React, { memo, useState, useCallback, useRef, useEffect } from 'react';
import { Search, User, X, Loader2, Mail } from 'lucide-react';
import { usersService } from '@/services';
import type { User as UserType } from '@/types';
import { cn } from '@/lib/utils';

interface UserSearchInputProps {
  value: UserType | null;
  onChange: (user: UserType | null) => void;
  placeholder?: string;
  disabled?: boolean;
  excludeNamespaceId?: number;
  className?: string;
  error?: string;
}

export const UserSearchInput = memo(function UserSearchInput({
  value,
  onChange,
  placeholder = 'Search by name or email...',
  disabled = false,
  excludeNamespaceId,
  className,
  error,
}: UserSearchInputProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<UserType[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [isOpen, setIsOpen] = useState(false);
  const [highlightedIndex, setHighlightedIndex] = useState(-1);
  const inputRef = useRef<HTMLInputElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const debounceRef = useRef<NodeJS.Timeout | null>(null);

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (
        dropdownRef.current &&
        !dropdownRef.current.contains(event.target as Node) &&
        inputRef.current &&
        !inputRef.current.contains(event.target as Node)
      ) {
        setIsOpen(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  // Search users with debounce
  const searchUsers = useCallback(
    async (searchQuery: string) => {
      if (searchQuery.length < 2) {
        setResults([]);
        setIsOpen(false);
        return;
      }

      setIsLoading(true);
      try {
        const users = await usersService.searchUsers(searchQuery, {
          limit: 10,
          excludeNamespaceId,
        });
        setResults(users);
        setIsOpen(users.length > 0);
        setHighlightedIndex(-1);
      } catch (err) {
        console.error('Failed to search users:', err);
        setResults([]);
      } finally {
        setIsLoading(false);
      }
    },
    [excludeNamespaceId]
  );

  // Handle input change with debounce
  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const newQuery = e.target.value;
      setQuery(newQuery);

      // Clear previous timeout
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
      }

      // Debounce search
      debounceRef.current = setTimeout(() => {
        searchUsers(newQuery);
      }, 300);
    },
    [searchUsers]
  );

  // Handle user selection
  const handleSelectUser = useCallback(
    (user: UserType) => {
      onChange(user);
      setQuery('');
      setResults([]);
      setIsOpen(false);
    },
    [onChange]
  );

  // Handle clearing selection
  const handleClear = useCallback(() => {
    onChange(null);
    setQuery('');
    setResults([]);
    inputRef.current?.focus();
  }, [onChange]);

  // Handle keyboard navigation
  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (!isOpen || results.length === 0) return;

      switch (e.key) {
        case 'ArrowDown':
          e.preventDefault();
          setHighlightedIndex((prev) =>
            prev < results.length - 1 ? prev + 1 : 0
          );
          break;
        case 'ArrowUp':
          e.preventDefault();
          setHighlightedIndex((prev) =>
            prev > 0 ? prev - 1 : results.length - 1
          );
          break;
        case 'Enter':
          e.preventDefault();
          if (highlightedIndex >= 0 && highlightedIndex < results.length) {
            handleSelectUser(results[highlightedIndex]);
          }
          break;
        case 'Escape':
          setIsOpen(false);
          break;
      }
    },
    [isOpen, results, highlightedIndex, handleSelectUser]
  );

  // Get display name for a user
  const getDisplayName = (user: UserType) => {
    const firstName = user.first_name || '';
    const lastName = user.last_name || '';
    const fullName = `${firstName} ${lastName}`.trim();
    return fullName || user.username || user.email;
  };

  // Render selected user
  if (value) {
    return (
      <div
        className={cn(
          'flex items-center gap-2 px-3 py-2 bg-secondary-50 border border-secondary-200 rounded-lg',
          disabled && 'opacity-50 cursor-not-allowed',
          className
        )}
      >
        <div className="w-8 h-8 rounded-full bg-primary-100 flex items-center justify-center flex-shrink-0">
          <User className="w-4 h-4 text-primary-600" />
        </div>
        <div className="flex-1 min-w-0">
          <p className="font-medium text-secondary-900 truncate">
            {getDisplayName(value)}
          </p>
          <p className="text-sm text-secondary-500 truncate">{value.email}</p>
        </div>
        {!disabled && (
          <button
            type="button"
            onClick={handleClear}
            className="p-1 hover:bg-secondary-200 rounded-full transition-colors"
            aria-label="Clear selection"
          >
            <X className="w-4 h-4 text-secondary-500" />
          </button>
        )}
      </div>
    );
  }

  return (
    <div className={cn('relative', className)}>
      {/* Search Input */}
      <div className="relative">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-secondary-400" />
        <input
          ref={inputRef}
          type="text"
          value={query}
          onChange={handleInputChange}
          onKeyDown={handleKeyDown}
          onFocus={() => query.length >= 2 && results.length > 0 && setIsOpen(true)}
          placeholder={placeholder}
          disabled={disabled}
          className={cn(
            'w-full pl-10 pr-10 py-2 border rounded-lg',
            'focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-primary-500',
            'disabled:bg-secondary-100 disabled:cursor-not-allowed',
            error
              ? 'border-error-500 focus:ring-error-500 focus:border-error-500'
              : 'border-secondary-300'
          )}
          aria-label="Search users"
          aria-expanded={isOpen}
          aria-autocomplete="list"
          role="combobox"
        />
        {isLoading && (
          <Loader2 className="absolute right-3 top-1/2 -translate-y-1/2 w-5 h-5 text-secondary-400 animate-spin" />
        )}
      </div>

      {/* Error message */}
      {error && <p className="mt-1 text-sm text-error-500">{error}</p>}

      {/* Dropdown Results */}
      {isOpen && results.length > 0 && (
        <div
          ref={dropdownRef}
          className="absolute z-50 w-full mt-1 bg-white border border-secondary-200 rounded-lg shadow-lg max-h-64 overflow-auto"
          role="listbox"
        >
          {results.map((user, index) => (
            <button
              key={user.uuid || user.id}
              type="button"
              onClick={() => handleSelectUser(user)}
              onMouseEnter={() => setHighlightedIndex(index)}
              className={cn(
                'w-full flex items-center gap-3 px-3 py-2 text-left transition-colors',
                highlightedIndex === index
                  ? 'bg-primary-50'
                  : 'hover:bg-secondary-50'
              )}
              role="option"
              aria-selected={highlightedIndex === index}
            >
              <div className="w-8 h-8 rounded-full bg-secondary-100 flex items-center justify-center flex-shrink-0">
                <User className="w-4 h-4 text-secondary-500" />
              </div>
              <div className="flex-1 min-w-0">
                <p className="font-medium text-secondary-900 truncate">
                  {getDisplayName(user)}
                </p>
                <div className="flex items-center gap-1 text-sm text-secondary-500">
                  <Mail className="w-3 h-3" />
                  <span className="truncate">{user.email}</span>
                </div>
              </div>
            </button>
          ))}
        </div>
      )}

      {/* No results message */}
      {isOpen && query.length >= 2 && results.length === 0 && !isLoading && (
        <div
          ref={dropdownRef}
          className="absolute z-50 w-full mt-1 bg-white border border-secondary-200 rounded-lg shadow-lg p-4 text-center"
        >
          <p className="text-secondary-500">No users found matching "{query}"</p>
          <p className="text-sm text-secondary-400 mt-1">
            Try a different search term or invite by email
          </p>
        </div>
      )}

      {/* Hint text */}
      {!isOpen && query.length === 0 && (
        <p className="mt-1 text-xs text-secondary-500">
          Type at least 2 characters to search
        </p>
      )}
    </div>
  );
});

export default UserSearchInput;
