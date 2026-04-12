'use client';

import React, { useState, useCallback, memo, useEffect } from 'react';
import Modal from '@/components/ui/Modal';
import { Input, Button, Select, Textarea } from '@/components/ui';
import { patientsService, hospitalsService } from '@/services';
import toast from 'react-hot-toast';
import type {
  Patient,
  CreatePatientDto,
  Hospital,
  Gender,
  PatientStatus,
} from '@/types';

interface AddPatientModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: (patient: Patient) => void;
  patient?: Patient | null;
  defaultHospitalId?: number;
}

interface FormData {
  hospital_id: string;
  patient_id: string;
  first_name: string;
  last_name: string;
  date_of_birth: string;
  gender: Gender;
  phone: string;
  email: string;
  blood_type: string;
  room_number: string;
  bed_number: string;
  admission_date: string;
  emergency_contact_name: string;
  emergency_contact_phone: string;
  emergency_contact_relation: string;
  status: PatientStatus;
  notes: string;
}

const INITIAL_FORM_DATA: FormData = {
  hospital_id: '',
  patient_id: '',
  first_name: '',
  last_name: '',
  date_of_birth: '',
  gender: 'male',
  phone: '',
  email: '',
  blood_type: '',
  room_number: '',
  bed_number: '',
  admission_date: '',
  emergency_contact_name: '',
  emergency_contact_phone: '',
  emergency_contact_relation: '',
  status: 'active',
  notes: '',
};

function LabeledSelect({
  label,
  name,
  value,
  onChange,
  children,
}: {
  label: string;
  name: string;
  value: string;
  onChange: (e: React.ChangeEvent<HTMLSelectElement>) => void;
  children: React.ReactNode;
}) {
  return (
    <div className="w-full">
      <label className="block text-sm font-medium text-secondary-700 mb-1.5">{label}</label>
      <Select name={name} value={value} onChange={onChange}>
        {children}
      </Select>
    </div>
  );
}

const AddPatientModal: React.FC<AddPatientModalProps> = memo(function AddPatientModal({
  isOpen,
  onClose,
  onSuccess,
  patient = null,
  defaultHospitalId,
}) {
  const isEdit = Boolean(patient);
  const [formData, setFormData] = useState<FormData>(INITIAL_FORM_DATA);
  const [hospitals, setHospitals] = useState<Hospital[]>([]);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [errors, setErrors] = useState<Partial<Record<keyof FormData, string>>>({});
  const [activeSection, setActiveSection] = useState<'basic' | 'medical' | 'emergency'>('basic');

  useEffect(() => {
    if (!isOpen) return;
    hospitalsService
      .getHospitals({ perPage: 100, status: 'active' })
      .then((res) => setHospitals(res.data || []))
      .catch(() => setHospitals([]));
  }, [isOpen]);

  useEffect(() => {
    if (patient && isOpen) {
      setFormData({
        hospital_id: String(patient.hospital_id ?? ''),
        patient_id: patient.patient_id || '',
        first_name: patient.first_name || '',
        last_name: patient.last_name || '',
        date_of_birth: patient.date_of_birth?.slice(0, 10) || '',
        gender: patient.gender || 'male',
        phone: patient.phone || '',
        email: patient.email || '',
        blood_type: patient.blood_type || '',
        room_number: patient.room_number || '',
        bed_number: patient.bed_number || '',
        admission_date: patient.admission_date?.slice(0, 10) || '',
        emergency_contact_name: patient.emergency_contact_name || '',
        emergency_contact_phone: patient.emergency_contact_phone || '',
        emergency_contact_relation: patient.emergency_contact_relation || '',
        status: patient.status || 'active',
        notes: patient.notes || '',
      });
    } else if (!isOpen) {
      setFormData({
        ...INITIAL_FORM_DATA,
        hospital_id: defaultHospitalId ? String(defaultHospitalId) : '',
      });
      setErrors({});
      setActiveSection('basic');
    } else if (isOpen && defaultHospitalId && !patient) {
      setFormData((prev) => ({ ...prev, hospital_id: String(defaultHospitalId) }));
    }
  }, [patient, isOpen, defaultHospitalId]);

  const handleChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => {
      const { name, value } = e.target;
      setFormData((prev) => ({ ...prev, [name]: value }));
      if (errors[name as keyof FormData]) {
        setErrors((prev) => ({ ...prev, [name]: undefined }));
      }
    },
    [errors]
  );

  const validate = (): boolean => {
    const newErrors: Partial<Record<keyof FormData, string>> = {};
    if (!formData.hospital_id) newErrors.hospital_id = 'Hospital is required';
    if (!formData.patient_id.trim()) newErrors.patient_id = 'Patient ID is required';
    if (!formData.first_name.trim()) newErrors.first_name = 'First name is required';
    if (!formData.last_name.trim()) newErrors.last_name = 'Last name is required';
    if (!formData.date_of_birth) newErrors.date_of_birth = 'Date of birth is required';
    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validate()) {
      setActiveSection('basic');
      return;
    }

    setIsSubmitting(true);
    try {
      const payload: CreatePatientDto = {
        hospital_id: parseInt(formData.hospital_id, 10),
        patient_id: formData.patient_id.trim(),
        first_name: formData.first_name.trim(),
        last_name: formData.last_name.trim(),
        date_of_birth: formData.date_of_birth,
        gender: formData.gender,
        phone: formData.phone.trim() || undefined,
        email: formData.email.trim() || undefined,
        blood_type: formData.blood_type.trim() || undefined,
        room_number: formData.room_number.trim() || undefined,
        bed_number: formData.bed_number.trim() || undefined,
        admission_date: formData.admission_date || undefined,
        emergency_contact_name: formData.emergency_contact_name.trim() || undefined,
        emergency_contact_phone: formData.emergency_contact_phone.trim() || undefined,
        emergency_contact_relation: formData.emergency_contact_relation.trim() || undefined,
        status: formData.status,
        notes: formData.notes.trim() || undefined,
      };

      const result = isEdit && patient
        ? await patientsService.updatePatient(patient.uuid, payload)
        : await patientsService.createPatient(payload);

      toast.success(isEdit ? 'Patient updated' : 'Patient created');
      onClose();
      onSuccess?.(result);
    } catch (error: unknown) {
      const msg = error instanceof Error ? error.message : 'Failed to save patient';
      toast.error(msg);
      console.error('Patient save error:', error);
    } finally {
      setIsSubmitting(false);
    }
  };

  const sectionButton = (section: typeof activeSection, label: string) => (
    <button
      type="button"
      onClick={() => setActiveSection(section)}
      className={`px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
        activeSection === section
          ? 'border-primary-500 text-primary-600'
          : 'border-transparent text-secondary-500 hover:text-secondary-700'
      }`}
    >
      {label}
    </button>
  );

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEdit ? 'Edit Patient' : 'Add New Patient'}
      size="lg"
    >
      <form onSubmit={handleSubmit} className="space-y-5">
        <div className="flex border-b border-secondary-200">
          {sectionButton('basic', 'Basic Info')}
          {sectionButton('medical', 'Medical & Admission')}
          {sectionButton('emergency', 'Emergency Contact')}
        </div>

        {activeSection === 'basic' && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <LabeledSelect
              label="Hospital"
              name="hospital_id"
              value={formData.hospital_id}
              onChange={handleChange}
            >
              <option value="">Select a hospital</option>
              {hospitals.map((h) => (
                <option key={h.uuid} value={h.id}>
                  {h.name}
                </option>
              ))}
            </LabeledSelect>
            <Input
              label="Patient ID (internal)"
              name="patient_id"
              value={formData.patient_id}
              onChange={handleChange}
              error={errors.patient_id}
              required
            />
            <Input
              label="First Name"
              name="first_name"
              value={formData.first_name}
              onChange={handleChange}
              error={errors.first_name}
              required
            />
            <Input
              label="Last Name"
              name="last_name"
              value={formData.last_name}
              onChange={handleChange}
              error={errors.last_name}
              required
            />
            <Input
              label="Date of Birth"
              name="date_of_birth"
              type="date"
              value={formData.date_of_birth}
              onChange={handleChange}
              error={errors.date_of_birth}
              required
            />
            <LabeledSelect
              label="Gender"
              name="gender"
              value={formData.gender}
              onChange={handleChange}
            >
              <option value="male">Male</option>
              <option value="female">Female</option>
              <option value="other">Other</option>
            </LabeledSelect>
            <Input
              label="Phone"
              name="phone"
              value={formData.phone}
              onChange={handleChange}
            />
            <Input
              label="Email"
              name="email"
              type="email"
              value={formData.email}
              onChange={handleChange}
            />
          </div>
        )}

        {activeSection === 'medical' && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <Input
              label="Blood Type"
              name="blood_type"
              value={formData.blood_type}
              onChange={handleChange}
              placeholder="e.g., A+, O-, AB+"
            />
            <LabeledSelect
              label="Status"
              name="status"
              value={formData.status}
              onChange={handleChange}
            >
              <option value="active">Active</option>
              <option value="discharged">Discharged</option>
              <option value="transferred">Transferred</option>
              <option value="deceased">Deceased</option>
            </LabeledSelect>
            <Input
              label="Admission Date"
              name="admission_date"
              type="date"
              value={formData.admission_date}
              onChange={handleChange}
            />
            <div />
            <Input
              label="Room Number"
              name="room_number"
              value={formData.room_number}
              onChange={handleChange}
            />
            <Input
              label="Bed Number"
              name="bed_number"
              value={formData.bed_number}
              onChange={handleChange}
            />
            <div className="md:col-span-2">
              <Textarea
                label="Notes"
                name="notes"
                value={formData.notes}
                onChange={handleChange}
                rows={3}
              />
            </div>
          </div>
        )}

        {activeSection === 'emergency' && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <Input
              label="Contact Name"
              name="emergency_contact_name"
              value={formData.emergency_contact_name}
              onChange={handleChange}
            />
            <Input
              label="Contact Phone"
              name="emergency_contact_phone"
              value={formData.emergency_contact_phone}
              onChange={handleChange}
            />
            <Input
              label="Relationship"
              name="emergency_contact_relation"
              value={formData.emergency_contact_relation}
              onChange={handleChange}
              placeholder="e.g., Spouse, Daughter"
            />
          </div>
        )}

        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <Button type="button" variant="ghost" onClick={onClose} disabled={isSubmitting}>
            Cancel
          </Button>
          <Button type="submit" isLoading={isSubmitting}>
            {isEdit ? 'Save Changes' : 'Create Patient'}
          </Button>
        </div>
      </form>
    </Modal>
  );
});

export default AddPatientModal;
