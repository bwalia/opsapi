'use client';

/**
 * Employees moved to its own core module at /dashboard/employees (it is no longer
 * field-service-specific). This route just redirects, so old links/bookmarks and
 * the former field-service "Employees" tab keep working.
 */

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';

export default function FieldServiceEmployeesRedirect() {
  const router = useRouter();
  useEffect(() => {
    router.replace('/dashboard/employees');
  }, [router]);
  return null;
}
