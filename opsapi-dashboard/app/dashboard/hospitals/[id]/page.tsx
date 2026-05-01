'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  Edit,
  Building2,
  MapPin,
  Phone,
  Mail,
  Globe,
  Bed,
  AlertTriangle,
  Users,
} from 'lucide-react';
import { Button, Card, Badge } from '@/components/ui';
import { AddHospitalModal } from '@/components/hospitals';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { hospitalsService, patientsService, alertsService } from '@/services';
import { formatDate } from '@/lib/utils';
import type { Hospital, Patient, PatientAlert } from '@/types';
import toast from 'react-hot-toast';

function HospitalDetailContent() {
  const params = useParams();
  const router = useRouter();
  const hospitalId = params.id as string;
  const { canUpdate } = usePermissions();

  const [hospital, setHospital] = useState<Hospital | null>(null);
  const [patients, setPatients] = useState<Patient[]>([]);
  const [activeAlerts, setActiveAlerts] = useState<PatientAlert[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [editOpen, setEditOpen] = useState(false);

  const load = useCallback(async () => {
    setIsLoading(true);
    try {
      const h = await hospitalsService.getHospital(hospitalId);
      setHospital(h);

      // Load patients for this hospital
      const patientsRes = await patientsService.getPatients({
        hospital_id: h.id,
        perPage: 50,
      });
      setPatients(patientsRes.data || []);

      // Load active alerts
      try {
        const alerts = await alertsService.activeForHospital(hospitalId);
        setActiveAlerts(alerts || []);
      } catch {
        // alerts endpoint is optional
      }
    } catch (error) {
      console.error('Failed to load hospital:', error);
      toast.error('Failed to load hospital details');
    } finally {
      setIsLoading(false);
    }
  }, [hospitalId]);

  useEffect(() => {
    load();
  }, [load]);

  if (isLoading) {
    return (
      <div className="space-y-4">
        <div className="h-8 bg-secondary-100 rounded animate-pulse w-1/3" />
        <div className="h-40 bg-secondary-100 rounded animate-pulse" />
        <div className="h-60 bg-secondary-100 rounded animate-pulse" />
      </div>
    );
  }

  if (!hospital) {
    return (
      <div className="text-center py-12">
        <Building2 className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
        <p className="text-secondary-500">Hospital not found</p>
        <Button
          variant="ghost"
          onClick={() => router.push('/dashboard/hospitals')}
          leftIcon={<ArrowLeft className="w-4 h-4" />}
          className="mt-4"
        >
          Back to hospitals
        </Button>
      </div>
    );
  }

  const parseJson = <T,>(val: unknown): T[] => {
    if (Array.isArray(val)) return val as T[];
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

  const specialties = parseJson<string>(hospital.specialties);
  const services = parseJson<string>(hospital.services);
  const facilities = parseJson<string>(hospital.facilities);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div className="flex items-start gap-4">
          <button
            onClick={() => router.push('/dashboard/hospitals')}
            className="mt-1 p-2 text-secondary-500 hover:text-secondary-900 hover:bg-secondary-100 rounded-lg transition-colors"
          >
            <ArrowLeft className="w-5 h-5" />
          </button>
          <div>
            <div className="flex items-center gap-3">
              <h1 className="text-2xl font-bold text-secondary-900">{hospital.name}</h1>
              <Badge variant={hospital.type === 'care_home' ? 'success' : 'info'}>
                {hospital.type === 'care_home'
                  ? 'Care Home'
                  : hospital.type === 'clinic'
                  ? 'Clinic'
                  : 'Hospital'}
              </Badge>
              <Badge variant={hospital.status === 'active' ? 'success' : 'secondary'}>
                {hospital.status}
              </Badge>
            </div>
            <p className="text-sm text-secondary-500 mt-1">
              License: {hospital.license_number}
            </p>
          </div>
        </div>

        {canUpdate('hospitals') && (
          <Button leftIcon={<Edit className="w-4 h-4" />} onClick={() => setEditOpen(true)}>
            Edit
          </Button>
        )}
      </div>

      {/* Overview cards */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <Card padding="md">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-info-500/10 flex items-center justify-center">
              <Bed className="w-5 h-5 text-info-600" />
            </div>
            <div>
              <p className="text-xs text-secondary-500">Capacity</p>
              <p className="text-xl font-bold text-secondary-900">{hospital.capacity || 0}</p>
            </div>
          </div>
        </Card>

        <Card padding="md">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-success-500/10 flex items-center justify-center">
              <Users className="w-5 h-5 text-success-600" />
            </div>
            <div>
              <p className="text-xs text-secondary-500">Active Patients</p>
              <p className="text-xl font-bold text-secondary-900">
                {patients.filter((p) => p.status === 'active').length}
              </p>
            </div>
          </div>
        </Card>

        <Card padding="md">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-warning-500/10 flex items-center justify-center">
              <AlertTriangle className="w-5 h-5 text-warning-600" />
            </div>
            <div>
              <p className="text-xs text-secondary-500">Active Alerts</p>
              <p className="text-xl font-bold text-secondary-900">{activeAlerts.length}</p>
            </div>
          </div>
        </Card>

        <Card padding="md">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-primary-500/10 flex items-center justify-center">
              <Building2 className="w-5 h-5 text-primary-600" />
            </div>
            <div>
              <p className="text-xs text-secondary-500">Total Patients</p>
              <p className="text-xl font-bold text-secondary-900">{patients.length}</p>
            </div>
          </div>
        </Card>
      </div>

      {/* Contact & Location */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <Card padding="md">
          <h3 className="text-sm font-semibold text-secondary-900 mb-4">Contact Information</h3>
          <div className="space-y-3 text-sm">
            {hospital.phone && (
              <div className="flex items-center gap-3">
                <Phone className="w-4 h-4 text-secondary-400" />
                <span className="text-secondary-700">{hospital.phone}</span>
              </div>
            )}
            {hospital.email && (
              <div className="flex items-center gap-3">
                <Mail className="w-4 h-4 text-secondary-400" />
                <span className="text-secondary-700">{hospital.email}</span>
              </div>
            )}
            {hospital.website && (
              <div className="flex items-center gap-3">
                <Globe className="w-4 h-4 text-secondary-400" />
                <a
                  href={hospital.website}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-primary-600 hover:underline"
                >
                  {hospital.website}
                </a>
              </div>
            )}
            {hospital.contact_person && (
              <div className="pt-3 border-t border-secondary-100">
                <p className="text-xs text-secondary-500">Primary Contact</p>
                <p className="text-secondary-900 font-medium">{hospital.contact_person}</p>
                {hospital.contact_phone && (
                  <p className="text-secondary-600 text-xs">{hospital.contact_phone}</p>
                )}
              </div>
            )}
          </div>
        </Card>

        <Card padding="md">
          <h3 className="text-sm font-semibold text-secondary-900 mb-4">Location</h3>
          <div className="flex items-start gap-3">
            <MapPin className="w-4 h-4 text-secondary-400 mt-0.5" />
            <div className="text-sm text-secondary-700">
              {hospital.address && <p>{hospital.address}</p>}
              <p>
                {[hospital.city, hospital.state, hospital.postal_code]
                  .filter(Boolean)
                  .join(', ')}
              </p>
              {hospital.country && <p>{hospital.country}</p>}
            </div>
          </div>
        </Card>
      </div>

      {/* Specialties / Services / Facilities */}
      {(specialties.length > 0 || services.length > 0 || facilities.length > 0) && (
        <Card padding="md">
          <h3 className="text-sm font-semibold text-secondary-900 mb-4">
            Capabilities &amp; Services
          </h3>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            {specialties.length > 0 && (
              <div>
                <p className="text-xs text-secondary-500 mb-2">Specialties</p>
                <div className="flex flex-wrap gap-1.5">
                  {specialties.map((s, i) => (
                    <Badge key={i} variant="info" size="sm">
                      {s}
                    </Badge>
                  ))}
                </div>
              </div>
            )}
            {services.length > 0 && (
              <div>
                <p className="text-xs text-secondary-500 mb-2">Services</p>
                <div className="flex flex-wrap gap-1.5">
                  {services.map((s, i) => (
                    <Badge key={i} variant="success" size="sm">
                      {s}
                    </Badge>
                  ))}
                </div>
              </div>
            )}
            {facilities.length > 0 && (
              <div>
                <p className="text-xs text-secondary-500 mb-2">Facilities</p>
                <div className="flex flex-wrap gap-1.5">
                  {facilities.map((s, i) => (
                    <Badge key={i} variant="secondary" size="sm">
                      {s}
                    </Badge>
                  ))}
                </div>
              </div>
            )}
          </div>
        </Card>
      )}

      {/* Recent patients */}
      <Card padding="md">
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-sm font-semibold text-secondary-900">Recent Patients</h3>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => router.push(`/dashboard/patients?hospital_id=${hospital.id}`)}
          >
            View all
          </Button>
        </div>
        {patients.length === 0 ? (
          <p className="text-sm text-secondary-500 text-center py-8">
            No patients registered at this hospital yet.
          </p>
        ) : (
          <div className="divide-y divide-secondary-100">
            {patients.slice(0, 10).map((p) => (
              <div
                key={p.uuid}
                onClick={() => router.push(`/dashboard/patients/${p.uuid}`)}
                className="flex items-center justify-between py-3 cursor-pointer hover:bg-secondary-50 -mx-2 px-2 rounded-lg transition-colors"
              >
                <div>
                  <p className="font-medium text-sm text-secondary-900">
                    {p.first_name} {p.last_name}
                  </p>
                  <p className="text-xs text-secondary-500">
                    ID: {p.patient_id}
                    {p.room_number ? ` · Room ${p.room_number}` : ''}
                    {p.admission_date ? ` · Admitted ${formatDate(p.admission_date)}` : ''}
                  </p>
                </div>
                <Badge variant={p.status === 'active' ? 'success' : 'secondary'} size="sm">
                  {p.status}
                </Badge>
              </div>
            ))}
          </div>
        )}
      </Card>

      <AddHospitalModal
        isOpen={editOpen}
        onClose={() => setEditOpen(false)}
        hospital={hospital}
        onSuccess={load}
      />
    </div>
  );
}

export default function HospitalDetailPage() {
  return (
    <ProtectedPage module="hospitals" title="Hospital Details">
      <HospitalDetailContent />
    </ProtectedPage>
  );
}
