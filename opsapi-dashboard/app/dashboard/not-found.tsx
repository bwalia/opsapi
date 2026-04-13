'use client';

import React from 'react';
import Link from 'next/link';
import { Home, ArrowLeft, Search, FileQuestion, FolderOpen } from 'lucide-react';
import { Button, Card } from '@/components/ui';

export default function DashboardNotFound() {
  const suggestedPages = [
    { name: 'Dashboard', href: '/dashboard', icon: Home },
    { name: 'Users', href: '/dashboard/users', icon: FolderOpen },
    { name: 'Namespaces', href: '/dashboard/namespaces', icon: FolderOpen },
    { name: 'Settings', href: '/dashboard/settings', icon: FolderOpen },
  ];

  return (
    <div className="min-h-[80vh] flex items-center justify-center p-4">
      <div className="max-w-2xl w-full text-center">
        {/* Icon and Title */}
        <div className="mb-8">
          <div className="inline-flex items-center justify-center w-24 h-24 rounded-2xl bg-gradient-to-br from-primary-100 to-primary-200 mb-6">
            <FileQuestion className="w-12 h-12 text-primary-600" />
          </div>
          <h1 className="text-4xl sm:text-5xl font-bold text-secondary-900 mb-3">
            Page Not Found
          </h1>
          <p className="text-lg text-secondary-600 max-w-md mx-auto">
            The page you&apos;re looking for doesn&apos;t exist or you don&apos;t have permission to access it.
          </p>
        </div>

        {/* Action Buttons */}
        <div className="flex flex-col sm:flex-row items-center justify-center gap-3 mb-10">
          <Link href="/dashboard">
            <Button size="lg">
              <Home className="w-5 h-5 mr-2" />
              Back to Dashboard
            </Button>
          </Link>
          <Button
            variant="outline"
            size="lg"
            onClick={() => window.history.back()}
          >
            <ArrowLeft className="w-5 h-5 mr-2" />
            Go Back
          </Button>
        </div>

        {/* Suggested Pages */}
        <Card className="p-6">
          <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
            Suggested Pages
          </h3>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            {suggestedPages.map((page) => (
              <Link
                key={page.href}
                href={page.href}
                className="flex flex-col items-center gap-2 p-4 rounded-xl hover:bg-secondary-50 transition-colors group"
              >
                <div className="w-10 h-10 rounded-lg bg-secondary-100 group-hover:bg-primary-100 flex items-center justify-center transition-colors">
                  <page.icon className="w-5 h-5 text-secondary-500 group-hover:text-primary-600 transition-colors" />
                </div>
                <span className="text-sm font-medium text-secondary-700 group-hover:text-primary-600 transition-colors">
                  {page.name}
                </span>
              </Link>
            ))}
          </div>
        </Card>

        {/* Search Suggestion */}
        <div className="mt-8 flex items-center justify-center gap-2 text-sm text-secondary-500">
          <Search className="w-4 h-4" />
          <span>Try using the search bar to find what you&apos;re looking for</span>
        </div>
      </div>
    </div>
  );
}
