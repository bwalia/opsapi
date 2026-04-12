'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  Edit,
  User,
  Heart,
  Pill,
  ClipboardList,
  Users as UsersIcon,
  Shield,
  Bell,
  Activity,
  Phone,
  Mail,
  MapPin,
  AlertTriangle,
  CheckCircle2,
  XCircle,
} from 'lucide-react';
import { Button, Card, Badge } from '@/components/ui';
import { AddPatientModal } from '@/components/patients';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  patientsService,
  carePlansService,
  medicationsService,
  dailyLogsService,
  familyMembersService,
  accessControlsService,
  alertsService,
} from '@/services';
import { formatDate, getInitials } from '@/lib/utils';
import type {
  Patient,
  CarePlan,
  Medication,
  DailyLog,
  FamilyMember,
  PatientAccessControl,
  PatientAlert,
} from '@/types';
import toast from 'react-hot-toast';

type TabKey = 'overview' | 'care-plans' | 'medications' | 'daily-logs' | 'family' | 'access' | 'alerts';

const TABS: { key: TabKey; label: string; icon: React.ComponentType<{ className?: string }> }[] = [
  { key: 'overview', label: 'Overview', icon: User },
  { key: 'care-plans', label: 'Care Plans', icon: ClipboardList },
  { key: 'medications', label: 'Medications', icon: Pill },
  { key: 'daily-logs', label: 'Daily Logs', icon: Activity },
  { key: 'family', label: 'Family', icon: UsersIcon },
  { key: 'access', label: 'Access Controls', icon: Shield },
  { key: 'alerts', label: 'Alerts', icon: Bell },
];

function PatientDetailContent() {
  const params = useParams();
  const router = useRouter();
  const patientUuid = params.id as string;
  const { canUpdate } = usePermissions();

  const [patient, setPatient] = useState<Patient | null>(null);
  const [activeTab, setActiveTab] = useState<TabKey>('overview');
  const [isLoading, setIsLoading] = useState(true);
  const [editOpen, setEditOpen] = useState(false);

  // Tab data
  const [carePlans, setCarePlans] = useState<CarePlan[]>([]);
  const [medications, setMedications] = useState<Medication[]>([]);
  const [dailyLogs, setDailyLogs] = useState<DailyLog[]>([]);
  const [family, setFamily] = useState<FamilyMember[]>([]);
  const [accessList, setAccessList] = useState<PatientAccessControl[]>([]);
  const [alerts, setAlerts] = useState<PatientAlert[]>([]);

  const loadPatient = useCallback(async () => {
    setIsLoading(true);
    try {
      const p = await patientsService.getPatient(patientUuid);
      setPatient(p);
    } catch (error) {
      console.error('Failed to load patient:', error);
      toast.error('Failed to load patient details');
    } finally {
      setIsLoading(false);
    }
  }, [patientUuid]);

  useEffect(() => {
    loadPatient();
  }, [loadPatient]);

  const loadTabData = useCallback(
    async (tab: TabKey) => {
      if (!patientUuid) return;
      try {
        switch (tab) {
          case 'care-plans': {
            const res = await carePlansService.list(patientUuid, { perPage: 50 });
            setCarePlans(res.data || []);
            break;
          }
          case 'medications': {
            const res = await medicationsService.list(patientUuid, { perPage: 50 });
            setMedications(res.data || []);
            break;
          }
          case 'daily-logs': {
            const res = await dailyLogsService.list(patientUuid, { perPage: 30 });
            setDailyLogs(res.data || []);
            break;
          }
          case 'family': {
            const res = await familyMembersService.list(patientUuid, { perPage: 50 });
            setFamily(res.data || []);
            break;
          }
          case 'access': {
            const res = await accessControlsService.list(patientUuid, { perPage: 50 });
            setAccessList(res.data || []);
            break;
          }
          case 'alerts': {
            const res = await alertsService.list(patientUuid, { perPage: 50 });
            setAlerts(res.data || []);
            break;
          }
        }
      } catch (error) {
        console.error(`Failed to load ${tab}:`, error);
      }
    },
    [patientUuid]
  );

  useEffect(() => {
    if (activeTab !== 'overview') {
      loadTabData(activeTab);
    }
  }, [activeTab, loadTabData]);

  const handleRevokeAccess = async (id: string) => {
    if (!confirm('Revoke this access grant?')) return;
    try {
      await accessControlsService.revoke(patientUuid, id);
      toast.success('Access revoked');
      loadTabData('access');
    } catch {
      toast.error('Failed to revoke access');
    }
  };

  const handleAcknowledgeAlert = async (id: string) => {
    try {
      await alertsService.acknowledge(patientUuid, id);
      toast.success('Alert acknowledged');
      loadTabData('alerts');
    } catch {
      toast.error('Failed to acknowledge alert');
    }
  };

  const handleResolveAlert = async (id: string) => {
    const notes = prompt('Resolution notes (optional):') || '';
    try {
      await alertsService.resolve(patientUuid, id, notes);
      toast.success('Alert resolved');
      loadTabData('alerts');
    } catch {
      toast.error('Failed to resolve alert');
    }
  };

  if (isLoading) {
    return (
      <div className="space-y-4">
        <div className="h-8 bg-secondary-100 rounded animate-pulse w-1/3" />
        <div className="h-40 bg-secondary-100 rounded animate-pulse" />
        <div className="h-60 bg-secondary-100 rounded animate-pulse" />
      </div>
    );
  }

  if (!patient) {
    return (
      <div className="text-center py-12">
        <User className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
        <p className="text-secondary-500">Patient not found</p>
        <Button
          variant="ghost"
          onClick={() => router.push('/dashboard/patients')}
          leftIcon={<ArrowLeft className="w-4 h-4" />}
          className="mt-4"
        >
          Back to patients
        </Button>
      </div>
    );
  }

  const calcAge = (dob: string): number | null => {
    if (!dob) return null;
    try {
      const birth = new Date(dob);
      const now = new Date();
      let age = now.getFullYear() - birth.getFullYear();
      const m = now.getMonth() - birth.getMonth();
      if (m < 0 || (m === 0 && now.getDate() < birth.getDate())) age--;
      return age;
    } catch {
      return null;
    }
  };

  const parseJsonArray = (val: unknown): string[] => {
    if (Array.isArray(val)) return val as string[];
    if (typeof val === 'string') {
      try {
        const parsed = JSON.parse(val);
        return Array.isArray(parsed) ? parsed : [];
      } catch {
        return [];
      }
    }
    return [];
  };

  const allergies = parseJsonArray(patient.allergies);
  const conditions = parseJsonArray(patient.medical_conditions);
  const age = calcAge(patient.date_of_birth);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div className="flex items-start gap-4">
          <button
            onClick={() => router.push('/dashboard/patients')}
            className="mt-2 p-2 text-secondary-500 hover:text-secondary-900 hover:bg-secondary-100 rounded-lg transition-colors"
          >
            <ArrowLeft className="w-5 h-5" />
          </button>
          <div className="flex items-center gap-4">
            <div className="w-16 h-16 gradient-primary rounded-xl flex items-center justify-center text-white text-lg font-bold shadow-lg shadow-primary-500/25">
              {getInitials(patient.first_name, patient.last_name)}
            </div>
            <div>
              <div className="flex items-center gap-3">
                <h1 className="text-2xl font-bold text-secondary-900">
                  {patient.first_name} {patient.last_name}
                </h1>
                <Badge variant={patient.status === 'active' ? 'success' : 'secondary'}>
                  {patient.status}
                </Badge>
              </div>
              <p className="text-sm text-secondary-500 mt-1">
                ID: {patient.patient_id}
                {age !== null ? ` · ${age} years old` : ''}
                {' · '}
                <span className="capitalize">{patient.gender}</span>
                {patient.blood_type ? ` · Blood ${patient.blood_type}` : ''}
                {patient.room_number ? ` · Room ${patient.room_number}` : ''}
              </p>
            </div>
          </div>
        </div>

        {canUpdate('patients') && (
          <Button leftIcon={<Edit className="w-4 h-4" />} onClick={() => setEditOpen(true)}>
            Edit
          </Button>
        )}
      </div>

      {/* Tabs */}
      <div className="border-b border-secondary-200">
        <div className="flex items-center gap-1 overflow-x-auto">
          {TABS.map((tab) => {
            const Icon = tab.icon;
            const active = activeTab === tab.key;
            return (
              <button
                key={tab.key}
                onClick={() => setActiveTab(tab.key)}
                className={`flex items-center gap-2 px-4 py-3 text-sm font-medium border-b-2 transition-colors whitespace-nowrap ${
                  active
                    ? 'border-primary-500 text-primary-600'
                    : 'border-transparent text-secondary-500 hover:text-secondary-700'
                }`}
              >
                <Icon className="w-4 h-4" />
                {tab.label}
              </button>
            );
          })}
        </div>
      </div>

      {/* Tab content */}
      {activeTab === 'overview' && (
        <div className="space-y-4">
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <Card padding="md">
              <h3 className="text-sm font-semibold text-secondary-900 mb-4">Contact</h3>
              <div className="space-y-2 text-sm">
                {patient.phone && (
                  <div className="flex items-center gap-3">
                    <Phone className="w-4 h-4 text-secondary-400" />
                    <span className="text-secondary-700">{patient.phone}</span>
                  </div>
                )}
                {patient.email && (
                  <div className="flex items-center gap-3">
                    <Mail className="w-4 h-4 text-secondary-400" />
                    <span className="text-secondary-700">{patient.email}</span>
                  </div>
                )}
                {(patient.address || patient.city) && (
                  <div className="flex items-start gap-3">
                    <MapPin className="w-4 h-4 text-secondary-400 mt-0.5" />
                    <div className="text-secondary-700">
                      {patient.address && <p>{patient.address}</p>}
                      <p>{[patient.city, patient.state, patient.postal_code].filter(Boolean).join(', ')}</p>
                    </div>
                  </div>
                )}
              </div>
            </Card>

            <Card padding="md">
              <h3 className="text-sm font-semibold text-secondary-900 mb-4">Emergency Contact</h3>
              {patient.emergency_contact_name ? (
                <div className="space-y-2 text-sm">
                  <div>
                    <p className="text-secondary-900 font-medium">{patient.emergency_contact_name}</p>
                    {patient.emergency_contact_relation && (
                      <p className="text-xs text-secondary-500 capitalize">
                        {patient.emergency_contact_relation}
                      </p>
                    )}
                  </div>
                  {patient.emergency_contact_phone && (
                    <div className="flex items-center gap-3">
                      <Phone className="w-4 h-4 text-secondary-400" />
                      <span className="text-secondary-700">{patient.emergency_contact_phone}</span>
                    </div>
                  )}
                </div>
              ) : (
                <p className="text-sm text-secondary-400">No emergency contact set</p>
              )}
            </Card>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <Card padding="md">
              <h3 className="text-sm font-semibold text-secondary-900 mb-4 flex items-center gap-2">
                <AlertTriangle className="w-4 h-4 text-warning-500" />
                Allergies
              </h3>
              {allergies.length === 0 ? (
                <p className="text-sm text-secondary-400">None recorded</p>
              ) : (
                <div className="flex flex-wrap gap-1.5">
                  {allergies.map((a, i) => (
                    <Badge key={i} variant="error" size="sm">
                      {a}
                    </Badge>
                  ))}
                </div>
              )}
            </Card>

            <Card padding="md">
              <h3 className="text-sm font-semibold text-secondary-900 mb-4 flex items-center gap-2">
                <Heart className="w-4 h-4 text-error-500" />
                Medical Conditions
              </h3>
              {conditions.length === 0 ? (
                <p className="text-sm text-secondary-400">None recorded</p>
              ) : (
                <div className="flex flex-wrap gap-1.5">
                  {conditions.map((c, i) => (
                    <Badge key={i} variant="warning" size="sm">
                      {c}
                    </Badge>
                  ))}
                </div>
              )}
            </Card>
          </div>

          <Card padding="md">
            <h3 className="text-sm font-semibold text-secondary-900 mb-4">Admission Details</h3>
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm">
              <div>
                <p className="text-xs text-secondary-500">Admission Date</p>
                <p className="text-secondary-900">{formatDate(patient.admission_date || '')}</p>
              </div>
              <div>
                <p className="text-xs text-secondary-500">Room</p>
                <p className="text-secondary-900">{patient.room_number || '—'}</p>
              </div>
              <div>
                <p className="text-xs text-secondary-500">Bed</p>
                <p className="text-secondary-900">{patient.bed_number || '—'}</p>
              </div>
              <div>
                <p className="text-xs text-secondary-500">Insurance</p>
                <p className="text-secondary-900">{patient.insurance_provider || '—'}</p>
              </div>
            </div>
            {patient.notes && (
              <div className="mt-4 pt-4 border-t border-secondary-100">
                <p className="text-xs text-secondary-500 mb-1">Notes</p>
                <p className="text-sm text-secondary-700">{patient.notes}</p>
              </div>
            )}
          </Card>
        </div>
      )}

      {activeTab === 'care-plans' && (
        <Card padding="md">
          <div className="flex items-center justify-between mb-4">
            <h3 className="text-sm font-semibold text-secondary-900">Care Plans</h3>
            <p className="text-xs text-secondary-500">
              Create care plans via API (form coming soon)
            </p>
          </div>
          {carePlans.length === 0 ? (
            <p className="text-sm text-secondary-400 text-center py-8">No care plans yet</p>
          ) : (
            <div className="space-y-3">
              {carePlans.map((plan) => (
                <div
                  key={plan.uuid}
                  className="p-4 border border-secondary-200 rounded-lg hover:bg-secondary-50 transition-colors"
                >
                  <div className="flex items-start justify-between">
                    <div>
                      <div className="flex items-center gap-2">
                        <h4 className="font-medium text-secondary-900">{plan.title}</h4>
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
                      {plan.description && (
                        <p className="text-sm text-secondary-600 mt-1">{plan.description}</p>
                      )}
                      <p className="text-xs text-secondary-500 mt-2">
                        {formatDate(plan.start_date)}
                        {plan.end_date ? ` → ${formatDate(plan.end_date)}` : ''}
                        {plan.review_date ? ` · Review: ${formatDate(plan.review_date)}` : ''}
                      </p>
                    </div>
                    <Badge variant={plan.status === 'active' ? 'success' : 'secondary'} size="sm">
                      {plan.status}
                    </Badge>
                  </div>
                </div>
              ))}
            </div>
          )}
        </Card>
      )}

      {activeTab === 'medications' && (
        <Card padding="md">
          <h3 className="text-sm font-semibold text-secondary-900 mb-4">Medications</h3>
          {medications.length === 0 ? (
            <p className="text-sm text-secondary-400 text-center py-8">No medications prescribed</p>
          ) : (
            <div className="space-y-3">
              {medications.map((m) => (
                <div
                  key={m.uuid}
                  className="p-4 border border-secondary-200 rounded-lg hover:bg-secondary-50 transition-colors"
                >
                  <div className="flex items-start justify-between">
                    <div className="flex items-start gap-3">
                      <div className="w-10 h-10 rounded-lg bg-info-500/10 flex items-center justify-center">
                        <Pill className="w-5 h-5 text-info-600" />
                      </div>
                      <div>
                        <h4 className="font-medium text-secondary-900">{m.name}</h4>
                        {m.generic_name && (
                          <p className="text-xs text-secondary-500">{m.generic_name}</p>
                        )}
                        <p className="text-sm text-secondary-600 mt-1">
                          {m.dosage} {m.unit} · {m.frequency}
                          {m.route ? ` · ${m.route}` : ''}
                        </p>
                        {m.instructions && (
                          <p className="text-xs text-secondary-500 mt-1">{m.instructions}</p>
                        )}
                      </div>
                    </div>
                    <div className="text-right">
                      <Badge variant={m.status === 'active' ? 'success' : 'secondary'} size="sm">
                        {m.status}
                      </Badge>
                      {m.is_prn && (
                        <Badge variant="warning" size="sm" className="ml-1">
                          PRN
                        </Badge>
                      )}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </Card>
      )}

      {activeTab === 'daily-logs' && (
        <Card padding="md">
          <h3 className="text-sm font-semibold text-secondary-900 mb-4">Daily Logs</h3>
          {dailyLogs.length === 0 ? (
            <p className="text-sm text-secondary-400 text-center py-8">No daily logs recorded</p>
          ) : (
            <div className="space-y-3">
              {dailyLogs.map((log) => (
                <div
                  key={log.uuid}
                  className="p-4 border border-secondary-200 rounded-lg"
                >
                  <div className="flex items-center justify-between mb-2">
                    <p className="text-sm font-medium text-secondary-900">
                      {formatDate(log.log_date)} {log.shift && `· ${log.shift}`}
                    </p>
                    {log.overall_mood && (
                      <Badge variant="info" size="sm">
                        {log.overall_mood}
                      </Badge>
                    )}
                  </div>
                  <div className="grid grid-cols-2 md:grid-cols-4 gap-3 text-xs">
                    {log.sleep_quality && (
                      <div>
                        <p className="text-secondary-500">Sleep</p>
                        <p className="text-secondary-900">{log.sleep_quality}</p>
                      </div>
                    )}
                    {log.breakfast_intake && (
                      <div>
                        <p className="text-secondary-500">Breakfast</p>
                        <p className="text-secondary-900">{log.breakfast_intake}</p>
                      </div>
                    )}
                    {log.mobility_level && (
                      <div>
                        <p className="text-secondary-500">Mobility</p>
                        <p className="text-secondary-900">{log.mobility_level}</p>
                      </div>
                    )}
                    {log.pain_level !== undefined && log.pain_level !== null && (
                      <div>
                        <p className="text-secondary-500">Pain (0-10)</p>
                        <p className="text-secondary-900">{log.pain_level}</p>
                      </div>
                    )}
                  </div>
                  {log.concerns && (
                    <p className="text-xs text-warning-600 mt-2">⚠ {log.concerns}</p>
                  )}
                </div>
              ))}
            </div>
          )}
        </Card>
      )}

      {activeTab === 'family' && (
        <Card padding="md">
          <h3 className="text-sm font-semibold text-secondary-900 mb-4">Family Members</h3>
          {family.length === 0 ? (
            <p className="text-sm text-secondary-400 text-center py-8">
              No family members registered
            </p>
          ) : (
            <div className="divide-y divide-secondary-100">
              {family.map((f) => (
                <div key={f.uuid} className="py-3 flex items-center justify-between">
                  <div>
                    <div className="flex items-center gap-2">
                      <p className="font-medium text-secondary-900">
                        {f.first_name} {f.last_name}
                      </p>
                      {f.is_next_of_kin && (
                        <Badge variant="info" size="sm">
                          Next of Kin
                        </Badge>
                      )}
                      {f.is_emergency_contact && (
                        <Badge variant="warning" size="sm">
                          Emergency
                        </Badge>
                      )}
                      {f.is_power_of_attorney && (
                        <Badge variant="error" size="sm">
                          POA
                        </Badge>
                      )}
                    </div>
                    <p className="text-xs text-secondary-500 capitalize">
                      {f.relationship}
                      {f.phone ? ` · ${f.phone}` : ''}
                      {f.email ? ` · ${f.email}` : ''}
                    </p>
                  </div>
                  {f.verified ? (
                    <CheckCircle2 className="w-4 h-4 text-success-500" />
                  ) : (
                    <Badge variant="secondary" size="sm">
                      Unverified
                    </Badge>
                  )}
                </div>
              ))}
            </div>
          )}
        </Card>
      )}

      {activeTab === 'access' && (
        <Card padding="md">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h3 className="text-sm font-semibold text-secondary-900">
                Patient-Controlled Access
              </h3>
              <p className="text-xs text-secondary-500">
                Who has been granted access to this patient&apos;s data
              </p>
            </div>
          </div>
          {accessList.length === 0 ? (
            <p className="text-sm text-secondary-400 text-center py-8">
              No access grants. The patient has not shared their data.
            </p>
          ) : (
            <div className="space-y-3">
              {accessList.map((a) => {
                const scope = typeof a.scope === 'string' ? JSON.parse(a.scope || '[]') : a.scope || [];
                return (
                  <div
                    key={a.uuid}
                    className="p-4 border border-secondary-200 rounded-lg"
                  >
                    <div className="flex items-start justify-between">
                      <div>
                        <p className="font-medium text-secondary-900">{a.granted_to}</p>
                        <p className="text-xs text-secondary-500 capitalize mt-0.5">
                          {a.role} · {a.access_level}
                          {a.relationship ? ` · ${a.relationship}` : ''}
                        </p>
                        {Array.isArray(scope) && scope.length > 0 && (
                          <div className="flex flex-wrap gap-1 mt-2">
                            {scope.map((s: string, i: number) => (
                              <Badge key={i} variant="info" size="sm">
                                {s}
                              </Badge>
                            ))}
                          </div>
                        )}
                        <p className="text-xs text-secondary-400 mt-2">
                          Granted {formatDate(a.created_at || '')}
                          {a.expires_at ? ` · Expires ${formatDate(a.expires_at)}` : ''}
                          {a.access_count ? ` · Accessed ${a.access_count}×` : ''}
                        </p>
                      </div>
                      <div className="flex items-center gap-2">
                        <Badge
                          variant={a.status === 'active' ? 'success' : 'secondary'}
                          size="sm"
                        >
                          {a.status}
                        </Badge>
                        {a.status === 'active' && (
                          <button
                            onClick={() => handleRevokeAccess(a.uuid)}
                            className="text-xs text-error-600 hover:text-error-700 font-medium"
                          >
                            Revoke
                          </button>
                        )}
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </Card>
      )}

      {activeTab === 'alerts' && (
        <Card padding="md">
          <h3 className="text-sm font-semibold text-secondary-900 mb-4">Alerts</h3>
          {alerts.length === 0 ? (
            <p className="text-sm text-secondary-400 text-center py-8">No alerts</p>
          ) : (
            <div className="space-y-3">
              {alerts.map((alert) => {
                const severityColor: Record<string, 'info' | 'warning' | 'error'> = {
                  info: 'info',
                  warning: 'warning',
                  critical: 'error',
                  emergency: 'error',
                };
                return (
                  <div
                    key={alert.uuid}
                    className={`p-4 border-l-4 border border-secondary-200 rounded-lg ${
                      alert.severity === 'critical' || alert.severity === 'emergency'
                        ? 'border-l-error-500 bg-error-500/5'
                        : alert.severity === 'warning'
                        ? 'border-l-warning-500 bg-warning-500/5'
                        : 'border-l-info-500'
                    }`}
                  >
                    <div className="flex items-start justify-between">
                      <div className="flex items-start gap-3">
                        <AlertTriangle
                          className={`w-5 h-5 mt-0.5 ${
                            alert.severity === 'critical' || alert.severity === 'emergency'
                              ? 'text-error-500'
                              : alert.severity === 'warning'
                              ? 'text-warning-500'
                              : 'text-info-500'
                          }`}
                        />
                        <div>
                          <div className="flex items-center gap-2">
                            <h4 className="font-medium text-secondary-900">{alert.title}</h4>
                            <Badge variant={severityColor[alert.severity] || 'info'} size="sm">
                              {alert.severity}
                            </Badge>
                          </div>
                          <p className="text-sm text-secondary-600 mt-1">{alert.message}</p>
                          <p className="text-xs text-secondary-400 mt-1">
                            {formatDate(alert.created_at || '')}
                            {alert.assigned_to ? ` · Assigned to ${alert.assigned_to}` : ''}
                          </p>
                        </div>
                      </div>
                      <div className="flex items-center gap-2">
                        <Badge
                          variant={
                            alert.status === 'resolved'
                              ? 'success'
                              : alert.status === 'active'
                              ? 'warning'
                              : 'secondary'
                          }
                          size="sm"
                        >
                          {alert.status}
                        </Badge>
                        {alert.status === 'active' && (
                          <>
                            <button
                              onClick={() => handleAcknowledgeAlert(alert.uuid)}
                              className="text-xs text-info-600 hover:text-info-700 font-medium"
                            >
                              Ack
                            </button>
                            <button
                              onClick={() => handleResolveAlert(alert.uuid)}
                              className="text-xs text-success-600 hover:text-success-700 font-medium"
                            >
                              Resolve
                            </button>
                          </>
                        )}
                      </div>
                    </div>
                    {alert.resolution_notes && (
                      <p className="text-xs text-secondary-600 mt-2 pt-2 border-t border-secondary-100">
                        Resolution: {alert.resolution_notes}
                      </p>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </Card>
      )}

      <AddPatientModal
        isOpen={editOpen}
        onClose={() => setEditOpen(false)}
        patient={patient}
        onSuccess={loadPatient}
      />
    </div>
  );
}

export default function PatientDetailPage() {
  return (
    <ProtectedPage module="patients" title="Patient Details">
      <PatientDetailContent />
    </ProtectedPage>
  );
}
