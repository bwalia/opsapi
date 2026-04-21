'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  Calculator,
  Landmark,
  FileUp,
  ArrowLeftRight,
  BarChart3,
  TrendingUp,
  TrendingDown,
  AlertCircle,
  CheckCircle,
  RefreshCw,
} from 'lucide-react';
import { Card } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { taxService, type TaxDashboardStats } from '@/services/tax.service';
import { formatCurrency } from '@/lib/utils';
import toast from 'react-hot-toast';

interface StatCardProps {
  title: string;
  value: string | number;
  icon: React.ReactNode;
  color: 'primary' | 'success' | 'warning' | 'danger' | 'info';
  onClick?: () => void;
}

const StatCard: React.FC<StatCardProps> = ({ title, value, icon, color, onClick }) => {
  const colorClasses = {
    primary: 'bg-primary-50 text-primary-600',
    success: 'bg-green-50 text-green-600',
    warning: 'bg-amber-50 text-amber-600',
    danger: 'bg-red-50 text-red-600',
    info: 'bg-blue-50 text-blue-600',
  };

  return (
    <div
      className={`bg-white rounded-xl border border-secondary-200 p-5 shadow-sm ${onClick ? 'cursor-pointer hover:border-primary-300 transition-colors' : ''}`}
      onClick={onClick}
    >
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-secondary-500">{title}</p>
          <p className="text-2xl font-bold text-secondary-900 mt-1">{value}</p>
        </div>
        <div className={`w-12 h-12 rounded-xl flex items-center justify-center ${colorClasses[color]}`}>
          {icon}
        </div>
      </div>
    </div>
  );
};

function TaxDashboardContent() {
  const router = useRouter();
  const [stats, setStats] = useState<TaxDashboardStats | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  const fetchStats = useCallback(async () => {
    setIsLoading(true);
    try {
      const data = await taxService.getDashboardStats();
      setStats(data);
    } catch {
      // Stats endpoint may not exist yet, use defaults
      setStats({
        total_bank_accounts: 0,
        total_statements: 0,
        total_transactions: 0,
        classified_transactions: 0,
        unclassified_transactions: 0,
        total_income: 0,
        total_expenses: 0,
      });
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchStats();
  }, [fetchStats]);

  const quickActions = [
    {
      title: 'Bank Accounts',
      description: 'Add and manage your bank accounts',
      icon: <Landmark className="w-6 h-6" />,
      path: '/dashboard/tax/bank-accounts',
      color: 'bg-blue-50 text-blue-600',
    },
    {
      title: 'Upload Statement',
      description: 'Upload a bank statement (PDF, CSV, or image)',
      icon: <FileUp className="w-6 h-6" />,
      path: '/dashboard/tax/statements',
      color: 'bg-purple-50 text-purple-600',
    },
    {
      title: 'Transactions',
      description: 'View and classify your transactions',
      icon: <ArrowLeftRight className="w-6 h-6" />,
      path: '/dashboard/tax/transactions',
      color: 'bg-amber-50 text-amber-600',
    },
    {
      title: 'Tax Reports',
      description: 'View category breakdowns and HMRC boxes',
      icon: <BarChart3 className="w-6 h-6" />,
      path: '/dashboard/tax/reports',
      color: 'bg-green-50 text-green-600',
    },
  ];

  if (isLoading) {
    return (
      <div className="animate-pulse space-y-6 p-6">
        <div className="h-8 bg-secondary-200 rounded w-1/4"></div>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
          {[1, 2, 3, 4].map((i) => (
            <div key={i} className="h-24 bg-secondary-200 rounded-xl"></div>
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Tax Returns</h1>
          <p className="text-secondary-500 mt-1">Manage your UK self-assessment tax return</p>
        </div>
        <button
          onClick={fetchStats}
          className="flex items-center gap-2 px-3 py-2 text-secondary-600 hover:text-secondary-900 hover:bg-secondary-100 rounded-lg transition-colors"
        >
          <RefreshCw className="w-4 h-4" />
          Refresh
        </button>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          title="Bank Accounts"
          value={stats?.total_bank_accounts ?? 0}
          icon={<Landmark className="w-5 h-5" />}
          color="primary"
          onClick={() => router.push('/dashboard/tax/bank-accounts')}
        />
        <StatCard
          title="Statements"
          value={stats?.total_statements ?? 0}
          icon={<FileUp className="w-5 h-5" />}
          color="info"
          onClick={() => router.push('/dashboard/tax/statements')}
        />
        <StatCard
          title="Total Income"
          value={formatCurrency(stats?.total_income ?? 0, 'GBP', 'en-GB')}
          icon={<TrendingUp className="w-5 h-5" />}
          color="success"
        />
        <StatCard
          title="Total Expenses"
          value={formatCurrency(stats?.total_expenses ?? 0, 'GBP', 'en-GB')}
          icon={<TrendingDown className="w-5 h-5" />}
          color="danger"
        />
      </div>

      {/* Classification status */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <StatCard
          title="Total Transactions"
          value={stats?.total_transactions ?? 0}
          icon={<ArrowLeftRight className="w-5 h-5" />}
          color="primary"
          onClick={() => router.push('/dashboard/tax/transactions')}
        />
        <StatCard
          title="Classified"
          value={stats?.classified_transactions ?? 0}
          icon={<CheckCircle className="w-5 h-5" />}
          color="success"
        />
        <StatCard
          title="Unclassified"
          value={stats?.unclassified_transactions ?? 0}
          icon={<AlertCircle className="w-5 h-5" />}
          color="warning"
          onClick={() => router.push('/dashboard/tax/transactions')}
        />
      </div>

      {/* Quick Actions */}
      <div>
        <h2 className="text-lg font-semibold text-secondary-900 mb-4">Quick Actions</h2>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
          {quickActions.map((action) => (
            <div
              key={action.path}
              onClick={() => router.push(action.path)}
              className="bg-white rounded-xl border border-secondary-200 p-5 shadow-sm cursor-pointer hover:border-primary-300 hover:shadow-md transition-all"
            >
              <div className={`w-12 h-12 rounded-xl flex items-center justify-center ${action.color} mb-3`}>
                {action.icon}
              </div>
              <h3 className="font-semibold text-secondary-900">{action.title}</h3>
              <p className="text-sm text-secondary-500 mt-1">{action.description}</p>
            </div>
          ))}
        </div>
      </div>

      {/* Workflow guide */}
      <div className="bg-blue-50 border border-blue-200 rounded-xl p-6">
        <h3 className="font-semibold text-blue-900 flex items-center gap-2">
          <Calculator className="w-5 h-5" />
          How it works
        </h3>
        <ol className="mt-3 space-y-2 text-sm text-blue-800">
          <li className="flex items-start gap-2">
            <span className="font-bold min-w-[20px]">1.</span>
            <span>Add your bank accounts under <strong>Bank Accounts</strong></span>
          </li>
          <li className="flex items-start gap-2">
            <span className="font-bold min-w-[20px]">2.</span>
            <span>Upload bank statements (PDF, CSV, or image) under <strong>Statements</strong></span>
          </li>
          <li className="flex items-start gap-2">
            <span className="font-bold min-w-[20px]">3.</span>
            <span>AI automatically extracts and classifies your transactions</span>
          </li>
          <li className="flex items-start gap-2">
            <span className="font-bold min-w-[20px]">4.</span>
            <span>Review classifications under <strong>Transactions</strong> and verify</span>
          </li>
          <li className="flex items-start gap-2">
            <span className="font-bold min-w-[20px]">5.</span>
            <span>View your tax summary and HMRC box mapping under <strong>Reports</strong></span>
          </li>
        </ol>
      </div>
    </div>
  );
}

export default function TaxDashboardPage() {
  return (
    <ProtectedPage module="tax_transactions" title="Tax Returns">
      <TaxDashboardContent />
    </ProtectedPage>
  );
}
