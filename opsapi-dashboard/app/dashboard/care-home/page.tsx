'use client';

import React, { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
  Heart,
  AlertTriangle,
  Brain,
  ClipboardList,
  ArrowRight,
  Activity,
} from 'lucide-react';
import { Card, Badge, Button } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { carePlansService, dementiaService, hospitalsService } from '@/services';
import { formatDate } from '@/lib/utils';
import type { CarePlan, DementiaAssessment, Hospital } from '@/types';

function CareHomeDashboardContent() {
  const router = useRouter();
  const [isLoading, setIsLoading] = useState(true);
  const [careHomes, setCareHomes] = useState<Hospital[]>([]);
  const [plansDueForReview, setPlansDueForReview] = useState<CarePlan[]>([]);
  const [wanderingRisk, setWanderingRisk] = useState<DementiaAssessment[]>([]);
  const [reassessmentDue, setReassessmentDue] = useState<DementiaAssessment[]>([]);

  useEffect(() => {
    const load = async () => {
      setIsLoading(true);
      try {
        const [homesRes, plansRes, wanderRes, reassessRes] = await Promise.allSettled([
          hospitalsService.getHospitals({ type: 'care_home', perPage: 50 }),
          carePlansService.dueForReview(),
          dementiaService.highRiskWandering(),
          dementiaService.dueForReassessment(),
        ]);

        if (homesRes.status === 'fulfilled') setCareHomes(homesRes.value.data || []);
        if (plansRes.status === 'fulfilled') setPlansDueForReview(plansRes.value || []);
        if (wanderRes.status === 'fulfilled') setWanderingRisk(wanderRes.value || []);
        if (reassessRes.status === 'fulfilled') setReassessmentDue(reassessRes.value || []);
      } catch (error) {
        console.error('Care home dashboard load error:', error);
      } finally {
        setIsLoading(false);
      }
    };

    load();
  }, []);

  const stats = [
    {
      label: 'Care Homes',
      value: careHomes.length,
      icon: Heart,
      color: 'success',
    },
    {
      label: 'Plans Due Review',
      value: plansDueForReview.length,
      icon: ClipboardList,
      color: 'warning',
    },
    {
      label: 'High Wandering Risk',
      value: wanderingRisk.length,
      icon: AlertTriangle,
      color: 'error',
    },
    {
      label: 'Reassessment Due',
      value: reassessmentDue.length,
      icon: Brain,
      color: 'info',
    },
  ] as const;

  const colorClasses: Record<string, { bg: string; text: string }> = {
    success: { bg: 'bg-success-500/10', text: 'text-success-600' },
    warning: { bg: 'bg-warning-500/10', text: 'text-warning-600' },
    error: { bg: 'bg-error-500/10', text: 'text-error-600' },
    info: { bg: 'bg-info-500/10', text: 'text-info-600' },
  };

  if (isLoading) {
    return (
      <div className="space-y-4">
        <div className="h-8 bg-secondary-100 rounded animate-pulse w-1/3" />
        <div className="grid grid-cols-4 gap-4">
          {[1, 2, 3, 4].map((i) => (
            <div key={i} className="h-24 bg-secondary-100 rounded animate-pulse" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-secondary-900">Care Home Dashboard</h1>
        <p className="text-secondary-500 mt-1">
          Dementia care, risk monitoring, and care plan oversight
        </p>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {stats.map((stat) => {
          const Icon = stat.icon;
          const colors = colorClasses[stat.color];
          return (
            <Card key={stat.label} padding="md">
              <div className="flex items-center gap-3">
                <div className={`w-10 h-10 rounded-lg ${colors.bg} flex items-center justify-center`}>
                  <Icon className={`w-5 h-5 ${colors.text}`} />
                </div>
                <div>
                  <p className="text-xs text-secondary-500">{stat.label}</p>
                  <p className="text-xl font-bold text-secondary-900">{stat.value}</p>
                </div>
              </div>
            </Card>
          );
        })}
      </div>

      {/* Care plans due for review */}
      <Card padding="md">
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-sm font-semibold text-secondary-900 flex items-center gap-2">
            <ClipboardList className="w-4 h-4 text-warning-500" />
            Care Plans Due for Review
          </h3>
        </div>
        {plansDueForReview.length === 0 ? (
          <p className="text-sm text-secondary-400 text-center py-6">
            All care plans are up to date ✓
          </p>
        ) : (
          <div className="divide-y divide-secondary-100">
            {plansDueForReview.slice(0, 10).map((plan) => (
              <div
                key={plan.uuid}
                className="py-3 flex items-center justify-between"
              >
                <div>
                  <div className="flex items-center gap-2">
                    <p className="font-medium text-sm text-secondary-900">{plan.title}</p>
                    <Badge variant="info" size="sm">
                      {plan.plan_type}
                    </Badge>
                    <Badge
                      variant={plan.priority === 'urgent' ? 'error' : 'secondary'}
                      size="sm"
                    >
                      {plan.priority}
                    </Badge>
                  </div>
                  <p className="text-xs text-secondary-500 mt-0.5">
                    Review date: {formatDate(plan.review_date || '')}
                  </p>
                </div>
                <ArrowRight className="w-4 h-4 text-secondary-400" />
              </div>
            ))}
          </div>
        )}
      </Card>

      {/* Two-column: wandering risk + reassessment */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <Card padding="md">
          <h3 className="text-sm font-semibold text-secondary-900 mb-4 flex items-center gap-2">
            <AlertTriangle className="w-4 h-4 text-error-500" />
            High Wandering Risk
          </h3>
          {wanderingRisk.length === 0 ? (
            <p className="text-sm text-secondary-400 text-center py-6">
              No high-risk patients
            </p>
          ) : (
            <div className="space-y-2">
              {wanderingRisk.slice(0, 8).map((a) => (
                <div
                  key={a.uuid}
                  className="p-3 border border-secondary-200 rounded-lg text-sm"
                >
                  <div className="flex items-center justify-between">
                    <p className="font-medium text-secondary-900">
                      Patient #{a.patient_id}
                    </p>
                    <Badge variant="error" size="sm">
                      {a.wandering_risk}
                    </Badge>
                  </div>
                  <p className="text-xs text-secondary-500 mt-1">
                    Assessed {formatDate(a.assessment_date)}
                    {a.severity_level ? ` · ${a.severity_level}` : ''}
                  </p>
                </div>
              ))}
            </div>
          )}
        </Card>

        <Card padding="md">
          <h3 className="text-sm font-semibold text-secondary-900 mb-4 flex items-center gap-2">
            <Brain className="w-4 h-4 text-info-500" />
            Reassessment Due
          </h3>
          {reassessmentDue.length === 0 ? (
            <p className="text-sm text-secondary-400 text-center py-6">
              No reassessments due
            </p>
          ) : (
            <div className="space-y-2">
              {reassessmentDue.slice(0, 8).map((a) => (
                <div
                  key={a.uuid}
                  className="p-3 border border-secondary-200 rounded-lg text-sm"
                >
                  <div className="flex items-center justify-between">
                    <p className="font-medium text-secondary-900">
                      Patient #{a.patient_id}
                    </p>
                    <Badge variant="info" size="sm">
                      {a.assessment_type}
                    </Badge>
                  </div>
                  <p className="text-xs text-secondary-500 mt-1">
                    Due: {formatDate(a.next_assessment_date || '')}
                  </p>
                </div>
              ))}
            </div>
          )}
        </Card>
      </div>

      {/* Care homes */}
      <Card padding="md">
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-sm font-semibold text-secondary-900 flex items-center gap-2">
            <Activity className="w-4 h-4 text-success-500" />
            Active Care Homes
          </h3>
          <Button variant="ghost" size="sm" onClick={() => router.push('/dashboard/hospitals')}>
            View all
          </Button>
        </div>
        {careHomes.length === 0 ? (
          <p className="text-sm text-secondary-400 text-center py-6">
            No care homes registered
          </p>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
            {careHomes.map((h) => (
              <div
                key={h.uuid}
                onClick={() => router.push(`/dashboard/hospitals/${h.uuid}`)}
                className="p-4 border border-secondary-200 rounded-lg hover:border-primary-300 hover:shadow-md cursor-pointer transition-all"
              >
                <div className="flex items-center justify-between">
                  <div>
                    <p className="font-medium text-secondary-900">{h.name}</p>
                    <p className="text-xs text-secondary-500">
                      {[h.city, h.country].filter(Boolean).join(', ')}
                    </p>
                  </div>
                  <Badge
                    variant={h.status === 'active' ? 'success' : 'secondary'}
                    size="sm"
                  >
                    {h.status}
                  </Badge>
                </div>
                <p className="text-xs text-secondary-500 mt-2">
                  Capacity: {h.capacity || 0} beds
                </p>
              </div>
            ))}
          </div>
        )}
      </Card>
    </div>
  );
}

export default function CareHomeDashboardPage() {
  return (
    <ProtectedPage module="care_home" title="Care Home Dashboard">
      <CareHomeDashboardContent />
    </ProtectedPage>
  );
}
