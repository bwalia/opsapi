'use client';

import React, { useState, useEffect, useCallback } from 'react';
import {
  BarChart3,
  PieChart,
  TrendingUp,
  Calculator,
  RefreshCw,
  Loader2,
  ChevronDown,
} from 'lucide-react';
import { Card } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  taxService,
  type TaxReportCategoryBreakdown,
  type TaxReportHmrcBoxes,
  type TaxReportMonthlyTrend,
  type TaxCalculation,
} from '@/services/tax.service';
import { formatCurrency } from '@/lib/utils';
import toast from 'react-hot-toast';

type TabId = 'categories' | 'hmrc' | 'trends' | 'calculation';

function ReportsContent() {
  const [activeTab, setActiveTab] = useState<TabId>('categories');
  const [taxYear, setTaxYear] = useState('2025');
  const [isLoading, setIsLoading] = useState(false);

  const [categoryBreakdown, setCategoryBreakdown] = useState<TaxReportCategoryBreakdown[]>([]);
  const [hmrcBoxes, setHmrcBoxes] = useState<TaxReportHmrcBoxes[]>([]);
  const [monthlyTrend, setMonthlyTrend] = useState<TaxReportMonthlyTrend[]>([]);
  const [taxCalculation, setTaxCalculation] = useState<TaxCalculation | null>(null);

  const fetchData = useCallback(async () => {
    setIsLoading(true);
    try {
      switch (activeTab) {
        case 'categories': {
          const data = await taxService.getCategoryBreakdown(taxYear);
          setCategoryBreakdown(Array.isArray(data) ? data : []);
          break;
        }
        case 'hmrc': {
          const data = await taxService.getHmrcBoxes(taxYear);
          setHmrcBoxes(Array.isArray(data) ? data : []);
          break;
        }
        case 'trends': {
          const data = await taxService.getMonthlyTrend(taxYear);
          setMonthlyTrend(Array.isArray(data) ? data : []);
          break;
        }
        case 'calculation': {
          const data = await taxService.getTaxCalculation(taxYear);
          setTaxCalculation(data);
          break;
        }
      }
    } catch {
      toast.error('Failed to load report data');
    } finally {
      setIsLoading(false);
    }
  }, [activeTab, taxYear]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  const tabs: { id: TabId; label: string; icon: React.ReactNode }[] = [
    { id: 'categories', label: 'Category Breakdown', icon: <PieChart className="w-4 h-4" /> },
    { id: 'hmrc', label: 'HMRC Boxes', icon: <BarChart3 className="w-4 h-4" /> },
    { id: 'trends', label: 'Monthly Trends', icon: <TrendingUp className="w-4 h-4" /> },
    { id: 'calculation', label: 'Tax Calculation', icon: <Calculator className="w-4 h-4" /> },
  ];

  const currentYear = new Date().getFullYear();
  const taxYears = Array.from({ length: 5 }, (_, i) => String(currentYear - i));

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-secondary-900">Tax Reports</h1>
        <div className="flex items-center gap-3">
          <select
            value={taxYear}
            onChange={(e) => setTaxYear(e.target.value)}
            className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500"
          >
            {taxYears.map((y) => (
              <option key={y} value={y}>Tax Year {y}/{Number(y) + 1}</option>
            ))}
          </select>
          <button
            onClick={fetchData}
            className="p-2 text-secondary-600 hover:bg-secondary-100 rounded-lg"
          >
            <RefreshCw className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* Tabs */}
      <div className="border-b border-secondary-200">
        <nav className="flex gap-1 -mb-px">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`flex items-center gap-2 px-4 py-3 text-sm font-medium border-b-2 transition-colors ${
                activeTab === tab.id
                  ? 'border-primary-500 text-primary-600'
                  : 'border-transparent text-secondary-500 hover:text-secondary-700 hover:border-secondary-300'
              }`}
            >
              {tab.icon}
              {tab.label}
            </button>
          ))}
        </nav>
      </div>

      {/* Loading */}
      {isLoading && (
        <div className="flex items-center justify-center py-12">
          <Loader2 className="w-8 h-8 text-primary-500 animate-spin" />
        </div>
      )}

      {/* Category Breakdown */}
      {!isLoading && activeTab === 'categories' && (
        <div>
          {categoryBreakdown.length === 0 ? (
            <div className="text-center py-12 text-secondary-500">
              No categorised transactions for this tax year. Upload statements and classify transactions first.
            </div>
          ) : (
            <div className="space-y-4">
              {/* Summary */}
              <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div className="bg-green-50 rounded-xl p-4 border border-green-200">
                  <p className="text-sm text-green-700">Total Income</p>
                  <p className="text-2xl font-bold text-green-800">
                    {formatCurrency(
                      categoryBreakdown.filter((c) => c.category_type === 'income').reduce((s, c) => s + Number(c.total_amount), 0),
                      'GBP', 'en-GB'
                    )}
                  </p>
                </div>
                <div className="bg-red-50 rounded-xl p-4 border border-red-200">
                  <p className="text-sm text-red-700">Total Expenses</p>
                  <p className="text-2xl font-bold text-red-800">
                    {formatCurrency(
                      categoryBreakdown.filter((c) => c.category_type === 'expense').reduce((s, c) => s + Number(c.total_amount), 0),
                      'GBP', 'en-GB'
                    )}
                  </p>
                </div>
                <div className="bg-blue-50 rounded-xl p-4 border border-blue-200">
                  <p className="text-sm text-blue-700">Tax Deductible</p>
                  <p className="text-2xl font-bold text-blue-800">
                    {formatCurrency(
                      categoryBreakdown.filter((c) => c.is_deductible).reduce((s, c) => s + Number(c.total_amount), 0),
                      'GBP', 'en-GB'
                    )}
                  </p>
                </div>
              </div>

              {/* Table */}
              <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden">
                <table className="w-full">
                  <thead>
                    <tr className="bg-secondary-50 border-b border-secondary-200">
                      <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase">Category</th>
                      <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase">Type</th>
                      <th className="px-6 py-3 text-right text-xs font-semibold text-secondary-600 uppercase">Amount</th>
                      <th className="px-6 py-3 text-right text-xs font-semibold text-secondary-600 uppercase">Count</th>
                      <th className="px-6 py-3 text-center text-xs font-semibold text-secondary-600 uppercase">Deductible</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-secondary-100">
                    {categoryBreakdown.map((cat, i) => (
                      <tr key={i} className="hover:bg-secondary-50">
                        <td className="px-6 py-3 text-sm font-medium">{cat.category_name}</td>
                        <td className="px-6 py-3">
                          <span className={`text-xs px-2 py-0.5 rounded-full ${
                            cat.category_type === 'income' ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'
                          }`}>
                            {cat.category_type}
                          </span>
                        </td>
                        <td className="px-6 py-3 text-sm text-right font-medium">
                          {formatCurrency(Number(cat.total_amount), 'GBP', 'en-GB')}
                        </td>
                        <td className="px-6 py-3 text-sm text-right text-secondary-500">{cat.transaction_count}</td>
                        <td className="px-6 py-3 text-center">
                          {cat.is_deductible ? (
                            <span className="text-green-600 text-xs">Yes</span>
                          ) : (
                            <span className="text-secondary-400 text-xs">No</span>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>
      )}

      {/* HMRC Boxes */}
      {!isLoading && activeTab === 'hmrc' && (
        <div>
          {hmrcBoxes.length === 0 ? (
            <div className="text-center py-12 text-secondary-500">
              No HMRC box data available. Classify your transactions first.
            </div>
          ) : (
            <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden">
              <div className="p-4 border-b border-secondary-200 bg-secondary-50">
                <h3 className="font-semibold text-secondary-900">SA103F Self-Employment (Full)</h3>
                <p className="text-sm text-secondary-500">Tax Year {taxYear}/{Number(taxYear) + 1}</p>
              </div>
              <table className="w-full">
                <thead>
                  <tr className="border-b border-secondary-200">
                    <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase">Box</th>
                    <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase">Description</th>
                    <th className="px-6 py-3 text-right text-xs font-semibold text-secondary-600 uppercase">Amount</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-secondary-100">
                  {hmrcBoxes.map((box, i) => (
                    <tr key={i} className="hover:bg-secondary-50">
                      <td className="px-6 py-3 text-sm font-mono font-bold text-primary-600">{box.box_number}</td>
                      <td className="px-6 py-3 text-sm">{box.box_name}</td>
                      <td className="px-6 py-3 text-sm text-right font-medium">
                        {formatCurrency(Number(box.amount), 'GBP', 'en-GB')}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      {/* Monthly Trends */}
      {!isLoading && activeTab === 'trends' && (
        <div>
          {monthlyTrend.length === 0 ? (
            <div className="text-center py-12 text-secondary-500">
              No monthly trend data available for this tax year.
            </div>
          ) : (
            <div className="space-y-4">
              <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden">
                <table className="w-full">
                  <thead>
                    <tr className="bg-secondary-50 border-b border-secondary-200">
                      <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase">Month</th>
                      <th className="px-6 py-3 text-right text-xs font-semibold text-secondary-600 uppercase">Income</th>
                      <th className="px-6 py-3 text-right text-xs font-semibold text-secondary-600 uppercase">Expenses</th>
                      <th className="px-6 py-3 text-right text-xs font-semibold text-secondary-600 uppercase">Net</th>
                      <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase">Bar</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-secondary-100">
                    {monthlyTrend.map((month, i) => {
                      const maxVal = Math.max(...monthlyTrend.map((m) => Math.max(Number(m.income), Number(m.expenses))));
                      const incomeWidth = maxVal > 0 ? (Number(month.income) / maxVal) * 100 : 0;
                      const expenseWidth = maxVal > 0 ? (Number(month.expenses) / maxVal) * 100 : 0;
                      return (
                        <tr key={i} className="hover:bg-secondary-50">
                          <td className="px-6 py-3 text-sm font-medium">{month.month}</td>
                          <td className="px-6 py-3 text-sm text-right text-green-600">
                            {formatCurrency(Number(month.income), 'GBP', 'en-GB')}
                          </td>
                          <td className="px-6 py-3 text-sm text-right text-red-600">
                            {formatCurrency(Number(month.expenses), 'GBP', 'en-GB')}
                          </td>
                          <td className={`px-6 py-3 text-sm text-right font-medium ${Number(month.net) >= 0 ? 'text-green-700' : 'text-red-700'}`}>
                            {formatCurrency(Number(month.net), 'GBP', 'en-GB')}
                          </td>
                          <td className="px-6 py-3 w-48">
                            <div className="space-y-1">
                              <div className="h-2 bg-green-200 rounded-full overflow-hidden">
                                <div className="h-full bg-green-500 rounded-full" style={{ width: `${incomeWidth}%` }} />
                              </div>
                              <div className="h-2 bg-red-200 rounded-full overflow-hidden">
                                <div className="h-full bg-red-500 rounded-full" style={{ width: `${expenseWidth}%` }} />
                              </div>
                            </div>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>
      )}

      {/* Tax Calculation */}
      {!isLoading && activeTab === 'calculation' && (
        <div>
          {!taxCalculation ? (
            <div className="text-center py-12 text-secondary-500">
              No tax calculation available. Classify your transactions first.
            </div>
          ) : (
            <div className="space-y-6">
              {/* Summary cards */}
              <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                <div className="bg-white rounded-xl border border-secondary-200 p-5">
                  <p className="text-sm text-secondary-500">Total Income</p>
                  <p className="text-2xl font-bold text-secondary-900">
                    {formatCurrency(Number(taxCalculation.total_income), 'GBP', 'en-GB')}
                  </p>
                </div>
                <div className="bg-white rounded-xl border border-secondary-200 p-5">
                  <p className="text-sm text-secondary-500">Allowable Expenses</p>
                  <p className="text-2xl font-bold text-secondary-900">
                    {formatCurrency(Number(taxCalculation.total_expenses), 'GBP', 'en-GB')}
                  </p>
                </div>
                <div className="bg-white rounded-xl border border-secondary-200 p-5">
                  <p className="text-sm text-secondary-500">Taxable Income</p>
                  <p className="text-2xl font-bold text-secondary-900">
                    {formatCurrency(Number(taxCalculation.taxable_income), 'GBP', 'en-GB')}
                  </p>
                </div>
                <div className="bg-primary-50 rounded-xl border border-primary-200 p-5">
                  <p className="text-sm text-primary-700">Total Tax Due</p>
                  <p className="text-2xl font-bold text-primary-900">
                    {formatCurrency(Number(taxCalculation.total_due), 'GBP', 'en-GB')}
                  </p>
                </div>
              </div>

              {/* Tax bands */}
              {taxCalculation.tax_bands && taxCalculation.tax_bands.length > 0 && (
                <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden">
                  <div className="p-4 border-b border-secondary-200 bg-secondary-50">
                    <h3 className="font-semibold text-secondary-900">Income Tax Bands</h3>
                  </div>
                  <table className="w-full">
                    <thead>
                      <tr className="border-b border-secondary-200">
                        <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase">Band</th>
                        <th className="px-6 py-3 text-right text-xs font-semibold text-secondary-600 uppercase">Rate</th>
                        <th className="px-6 py-3 text-right text-xs font-semibold text-secondary-600 uppercase">Taxable Amount</th>
                        <th className="px-6 py-3 text-right text-xs font-semibold text-secondary-600 uppercase">Tax</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-secondary-100">
                      {taxCalculation.tax_bands.map((band, i) => (
                        <tr key={i} className="hover:bg-secondary-50">
                          <td className="px-6 py-3 text-sm font-medium">{band.band}</td>
                          <td className="px-6 py-3 text-sm text-right">{band.rate}%</td>
                          <td className="px-6 py-3 text-sm text-right">
                            {formatCurrency(Number(band.taxable_amount), 'GBP', 'en-GB')}
                          </td>
                          <td className="px-6 py-3 text-sm text-right font-medium">
                            {formatCurrency(Number(band.tax_amount), 'GBP', 'en-GB')}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                    <tfoot>
                      <tr className="bg-secondary-50 border-t border-secondary-200">
                        <td className="px-6 py-3 text-sm font-bold" colSpan={3}>Income Tax</td>
                        <td className="px-6 py-3 text-sm text-right font-bold">
                          {formatCurrency(Number(taxCalculation.total_tax), 'GBP', 'en-GB')}
                        </td>
                      </tr>
                      {taxCalculation.national_insurance != null && (
                        <tr className="bg-secondary-50">
                          <td className="px-6 py-3 text-sm font-bold" colSpan={3}>National Insurance (Class 4)</td>
                          <td className="px-6 py-3 text-sm text-right font-bold">
                            {formatCurrency(Number(taxCalculation.national_insurance), 'GBP', 'en-GB')}
                          </td>
                        </tr>
                      )}
                      <tr className="bg-primary-50">
                        <td className="px-6 py-3 text-sm font-bold text-primary-900" colSpan={3}>Total Due</td>
                        <td className="px-6 py-3 text-sm text-right font-bold text-primary-900">
                          {formatCurrency(Number(taxCalculation.total_due), 'GBP', 'en-GB')}
                        </td>
                      </tr>
                    </tfoot>
                  </table>
                </div>
              )}

              {/* Disclaimer */}
              <div className="bg-amber-50 border border-amber-200 rounded-xl p-4 text-sm text-amber-800">
                <strong>Disclaimer:</strong> This is an estimate based on classified transactions.
                Always verify with a qualified accountant before filing with HMRC. Personal allowance
                ({formatCurrency(Number(taxCalculation.personal_allowance), 'GBP', 'en-GB')}) is
                applied automatically.
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export default function ReportsPage() {
  return (
    <ProtectedPage module="tax_transactions" title="Tax Reports">
      <ReportsContent />
    </ProtectedPage>
  );
}
