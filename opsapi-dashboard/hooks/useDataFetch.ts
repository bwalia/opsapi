import { useState, useEffect, useRef, useCallback } from 'react';

interface UseDataFetchOptions<T> {
  initialData?: T;
  onError?: (error: Error) => void;
}

interface UseDataFetchResult<T> {
  data: T | null;
  isLoading: boolean;
  error: Error | null;
  refetch: () => Promise<void>;
}

/**
 * Custom hook for data fetching with automatic deduplication
 * Prevents duplicate API calls from React StrictMode and re-renders
 */
export function useDataFetch<T>(
  fetchFn: () => Promise<T>,
  deps: React.DependencyList = [],
  options: UseDataFetchOptions<T> = {}
): UseDataFetchResult<T> {
  const [data, setData] = useState<T | null>(options.initialData ?? null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  // Track fetch state to prevent duplicate calls
  const fetchIdRef = useRef(0);
  const isMountedRef = useRef(true);

  const fetchData = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    setError(null);

    try {
      const result = await fetchFn();

      // Only update state if this is still the latest fetch and component is mounted
      if (fetchId === fetchIdRef.current && isMountedRef.current) {
        setData(result);
      }
    } catch (err) {
      if (fetchId === fetchIdRef.current && isMountedRef.current) {
        const error = err instanceof Error ? err : new Error(String(err));
        setError(error);
        options.onError?.(error);
      }
    } finally {
      if (fetchId === fetchIdRef.current && isMountedRef.current) {
        setIsLoading(false);
      }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fetchFn, ...deps]);

  useEffect(() => {
    isMountedRef.current = true;
    fetchData();

    return () => {
      isMountedRef.current = false;
    };
  }, [fetchData]);

  const refetch = useCallback(async () => {
    await fetchData();
  }, [fetchData]);

  return { data, isLoading, error, refetch };
}

/**
 * Custom hook for paginated data fetching
 */
export function usePaginatedFetch<T, P extends Record<string, unknown>>(
  fetchFn: (params: P) => Promise<{ data: T[]; total: number; totalPages: number }>,
  initialParams: P,
  options: UseDataFetchOptions<T[]> = {}
) {
  const [data, setData] = useState<T[]>([]);
  const [total, setTotal] = useState(0);
  const [totalPages, setTotalPages] = useState(1);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);
  const [params, setParams] = useState<P>(initialParams);

  const fetchIdRef = useRef(0);
  const isMountedRef = useRef(true);

  const fetchData = useCallback(async (newParams?: Partial<P>) => {
    const fetchId = ++fetchIdRef.current;
    const currentParams = newParams ? { ...params, ...newParams } : params;

    if (newParams) {
      setParams(currentParams as P);
    }

    setIsLoading(true);
    setError(null);

    try {
      const result = await fetchFn(currentParams as P);

      if (fetchId === fetchIdRef.current && isMountedRef.current) {
        setData(result.data);
        setTotal(result.total);
        setTotalPages(result.totalPages);
      }
    } catch (err) {
      if (fetchId === fetchIdRef.current && isMountedRef.current) {
        const error = err instanceof Error ? err : new Error(String(err));
        setError(error);
        options.onError?.(error);
      }
    } finally {
      if (fetchId === fetchIdRef.current && isMountedRef.current) {
        setIsLoading(false);
      }
    }
  }, [fetchFn, params, options]);

  useEffect(() => {
    isMountedRef.current = true;
    fetchData();

    return () => {
      isMountedRef.current = false;
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const refetch = useCallback(() => fetchData(), [fetchData]);

  const updateParams = useCallback((newParams: Partial<P>) => {
    fetchData(newParams);
  }, [fetchData]);

  return {
    data,
    total,
    totalPages,
    isLoading,
    error,
    params,
    refetch,
    updateParams,
  };
}

export default useDataFetch;
