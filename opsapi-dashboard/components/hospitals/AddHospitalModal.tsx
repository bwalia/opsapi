'use client';

import React, { useState, useCallback, memo, useEffect } from 'react';
import Modal from '@/components/ui/Modal';
import { Input, Button, Select, Textarea } from '@/components/ui';
import { hospitalsService } from '@/services';
import toast from 'react-hot-toast';
import type { Hospital, CreateHospitalDto, HospitalType, HospitalStatus } from '@/types';

interface AddHospitalModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: (hospital: Hospital) => void;
  hospital?: Hospital | null;
}

interface FormData {
  name: string;
  type: HospitalType;
  license_number: string;
  address: string;
  city: string;
  state: string;
  postal_code: string;
  country: string;
  phone: string;
  email: string;
  website: string;
  capacity: string;
  contact_person: string;
  contact_phone: string;
  status: HospitalStatus;
}

const INITIAL_FORM_DATA: FormData = {
  name: '',
  type: 'hospital',
  license_number: '',
  address: '',
  city: '',
  state: '',
  postal_code: '',
  country: '',
  phone: '',
  email: '',
  website: '',
  capacity: '',
  contact_person: '',
  contact_phone: '',
  status: 'active',
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

const AddHospitalModal: React.FC<AddHospitalModalProps> = memo(function AddHospitalModal({
  isOpen,
  onClose,
  onSuccess,
  hospital = null,
}) {
  const isEdit = Boolean(hospital);
  const [formData, setFormData] = useState<FormData>(INITIAL_FORM_DATA);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [errors, setErrors] = useState<Partial<Record<keyof FormData, string>>>({});

  useEffect(() => {
    if (hospital && isOpen) {
      setFormData({
        name: hospital.name || '',
        type: hospital.type || 'hospital',
        license_number: hospital.license_number || '',
        address: hospital.address || '',
        city: hospital.city || '',
        state: hospital.state || '',
        postal_code: hospital.postal_code || '',
        country: hospital.country || '',
        phone: hospital.phone || '',
        email: hospital.email || '',
        website: hospital.website || '',
        capacity: String(hospital.capacity ?? ''),
        contact_person: hospital.contact_person || '',
        contact_phone: hospital.contact_phone || '',
        status: hospital.status || 'active',
      });
    } else if (!isOpen) {
      setFormData(INITIAL_FORM_DATA);
      setErrors({});
    }
  }, [hospital, isOpen]);

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
    if (!formData.name.trim()) newErrors.name = 'Name is required';
    if (!formData.license_number.trim()) newErrors.license_number = 'License number is required';
    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validate()) return;

    setIsSubmitting(true);
    try {
      const payload: CreateHospitalDto = {
        name: formData.name.trim(),
        type: formData.type,
        license_number: formData.license_number.trim(),
        address: formData.address.trim() || undefined,
        city: formData.city.trim() || undefined,
        state: formData.state.trim() || undefined,
        postal_code: formData.postal_code.trim() || undefined,
        country: formData.country.trim() || undefined,
        phone: formData.phone.trim() || undefined,
        email: formData.email.trim() || undefined,
        website: formData.website.trim() || undefined,
        capacity: formData.capacity ? parseInt(formData.capacity, 10) : undefined,
        contact_person: formData.contact_person.trim() || undefined,
        contact_phone: formData.contact_phone.trim() || undefined,
        status: formData.status,
      };

      const result = isEdit && hospital
        ? await hospitalsService.updateHospital(hospital.uuid, payload)
        : await hospitalsService.createHospital(payload);

      toast.success(isEdit ? 'Hospital updated' : 'Hospital created');
      onClose();
      onSuccess?.(result);
    } catch (error: unknown) {
      const msg = error instanceof Error ? error.message : 'Failed to save hospital';
      toast.error(msg);
      console.error('Hospital save error:', error);
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEdit ? 'Edit Hospital' : 'Add New Hospital'}
      size="lg"
    >
      <form onSubmit={handleSubmit} className="space-y-5">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <Input
            label="Name"
            name="name"
            value={formData.name}
            onChange={handleChange}
            error={errors.name}
            required
          />
          <LabeledSelect
            label="Type"
            name="type"
            value={formData.type}
            onChange={handleChange}
          >
            <option value="hospital">Hospital</option>
            <option value="care_home">Care Home</option>
            <option value="clinic">Clinic</option>
          </LabeledSelect>
          <Input
            label="License Number"
            name="license_number"
            value={formData.license_number}
            onChange={handleChange}
            error={errors.license_number}
            required
          />
          <LabeledSelect
            label="Status"
            name="status"
            value={formData.status}
            onChange={handleChange}
          >
            <option value="active">Active</option>
            <option value="inactive">Inactive</option>
            <option value="suspended">Suspended</option>
          </LabeledSelect>
          <Input
            label="Capacity (beds)"
            name="capacity"
            type="number"
            value={formData.capacity}
            onChange={handleChange}
          />
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
          <Input
            label="Website"
            name="website"
            value={formData.website}
            onChange={handleChange}
          />
        </div>

        <Textarea
          label="Address"
          name="address"
          value={formData.address}
          onChange={handleChange}
          rows={2}
        />

        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <Input label="City" name="city" value={formData.city} onChange={handleChange} />
          <Input label="State" name="state" value={formData.state} onChange={handleChange} />
          <Input
            label="Postal Code"
            name="postal_code"
            value={formData.postal_code}
            onChange={handleChange}
          />
          <Input label="Country" name="country" value={formData.country} onChange={handleChange} />
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <Input
            label="Contact Person"
            name="contact_person"
            value={formData.contact_person}
            onChange={handleChange}
          />
          <Input
            label="Contact Phone"
            name="contact_phone"
            value={formData.contact_phone}
            onChange={handleChange}
          />
        </div>

        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <Button type="button" variant="ghost" onClick={onClose} disabled={isSubmitting}>
            Cancel
          </Button>
          <Button type="submit" isLoading={isSubmitting}>
            {isEdit ? 'Save Changes' : 'Create Hospital'}
          </Button>
        </div>
      </form>
    </Modal>
  );
});

export default AddHospitalModal;
