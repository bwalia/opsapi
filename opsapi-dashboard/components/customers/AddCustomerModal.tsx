'use client';

import React, { useState, useCallback, memo } from 'react';
import Modal from '@/components/ui/Modal';
import { Input, Button, Textarea } from '@/components/ui';
import { User, Mail, Phone, MapPin, Building, Globe, Hash, Tag, Calendar, Check } from 'lucide-react';
import { customersService } from '@/services';
import toast from 'react-hot-toast';
import type { Customer, CreateCustomerDto, CustomerAddress } from '@/types';

// ============================================
// Types
// ============================================

export interface AddCustomerModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: (customer: Customer) => void;
}

interface FormData {
  first_name: string;
  last_name: string;
  email: string;
  phone: string;
  date_of_birth: string;
  // Address fields (stored as JSON array)
  address1: string;
  address2: string;
  city: string;
  province: string;
  country: string;
  zip: string;
  // Other fields
  notes: string;
  tags: string;
  accepts_marketing: boolean;
}

interface FormErrors {
  first_name?: string;
  last_name?: string;
  email?: string;
  phone?: string;
  date_of_birth?: string;
  zip?: string;
}

// ============================================
// Constants
// ============================================

const INITIAL_FORM_DATA: FormData = {
  first_name: '',
  last_name: '',
  email: '',
  phone: '',
  date_of_birth: '',
  address1: '',
  address2: '',
  city: '',
  province: '',
  country: '',
  zip: '',
  notes: '',
  tags: '',
  accepts_marketing: false,
};

const EMAIL_REGEX = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;
const PHONE_REGEX = /^[+]?[(]?[0-9]{1,4}[)]?[-\s./0-9]*$/;

// ============================================
// Component
// ============================================

const AddCustomerModal: React.FC<AddCustomerModalProps> = memo(function AddCustomerModal({
  isOpen,
  onClose,
  onSuccess,
}) {
  const [formData, setFormData] = useState<FormData>(INITIAL_FORM_DATA);
  const [errors, setErrors] = useState<FormErrors>({});
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [activeSection, setActiveSection] = useState<'basic' | 'address' | 'preferences'>('basic');

  // ============================================
  // Validation
  // ============================================

  const validateForm = useCallback((): boolean => {
    const newErrors: FormErrors = {};

    // Email is required
    if (!formData.email.trim()) {
      newErrors.email = 'Email is required';
    } else if (!EMAIL_REGEX.test(formData.email.trim())) {
      newErrors.email = 'Please enter a valid email address';
    }

    // Optional but validated fields
    if (formData.first_name.trim() && formData.first_name.trim().length < 2) {
      newErrors.first_name = 'First name must be at least 2 characters';
    }

    if (formData.last_name.trim() && formData.last_name.trim().length < 2) {
      newErrors.last_name = 'Last name must be at least 2 characters';
    }

    if (formData.phone.trim() && !PHONE_REGEX.test(formData.phone.trim())) {
      newErrors.phone = 'Please enter a valid phone number';
    }

    if (formData.zip.trim() && formData.zip.trim().length > 20) {
      newErrors.zip = 'Postal code is too long';
    }

    if (formData.date_of_birth.trim()) {
      const dob = new Date(formData.date_of_birth);
      const now = new Date();
      if (isNaN(dob.getTime()) || dob > now) {
        newErrors.date_of_birth = 'Please enter a valid date of birth';
      }
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  }, [formData]);

  // ============================================
  // Handlers
  // ============================================

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => {
      const { name, value, type } = e.target;
      const newValue = type === 'checkbox' ? (e.target as HTMLInputElement).checked : value;

      setFormData((prev) => ({ ...prev, [name]: newValue }));

      // Clear error when user starts typing
      if (errors[name as keyof FormErrors]) {
        setErrors((prev) => ({ ...prev, [name]: undefined }));
      }
    },
    [errors]
  );

  const handleCheckboxChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const { name, checked } = e.target;
      setFormData((prev) => ({ ...prev, [name]: checked }));
    },
    []
  );

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();

      if (!validateForm()) {
        // If there are errors, switch to the relevant section
        if (errors.email || errors.first_name || errors.last_name || errors.phone || errors.date_of_birth) {
          setActiveSection('basic');
        } else if (errors.zip) {
          setActiveSection('address');
        }
        return;
      }

      setIsSubmitting(true);

      try {
        // Build address array only if any address field has a value
        const hasAddress = formData.address1.trim() || formData.city.trim() ||
                          formData.province.trim() || formData.country.trim() || formData.zip.trim();

        const addresses: CustomerAddress[] = hasAddress ? [{
          address1: formData.address1.trim() || undefined,
          address2: formData.address2.trim() || undefined,
          city: formData.city.trim() || undefined,
          province: formData.province.trim() || undefined,
          country: formData.country.trim() || undefined,
          zip: formData.zip.trim() || undefined,
          is_default: true,
        }] : [];

        // Prepare data
        const customerData: CreateCustomerDto = {
          email: formData.email.trim().toLowerCase(),
        };

        // Add optional fields only if they have values
        if (formData.first_name.trim()) {
          customerData.first_name = formData.first_name.trim();
        }
        if (formData.last_name.trim()) {
          customerData.last_name = formData.last_name.trim();
        }
        if (formData.phone.trim()) {
          customerData.phone = formData.phone.trim();
        }
        if (formData.date_of_birth.trim()) {
          customerData.date_of_birth = formData.date_of_birth.trim();
        }
        if (addresses.length > 0) {
          customerData.addresses = addresses;
        }
        if (formData.notes.trim()) {
          customerData.notes = formData.notes.trim();
        }
        if (formData.tags.trim()) {
          customerData.tags = formData.tags.trim();
        }
        customerData.accepts_marketing = formData.accepts_marketing;

        const newCustomer = await customersService.createCustomer(customerData);

        const customerName = formData.first_name || formData.last_name
          ? `${formData.first_name} ${formData.last_name}`.trim()
          : formData.email;
        toast.success(`Customer "${customerName}" created successfully`);

        // Reset form
        setFormData(INITIAL_FORM_DATA);
        setErrors({});
        setActiveSection('basic');

        onClose();
        onSuccess?.(newCustomer);
      } catch (error: unknown) {
        const errorMessage = error instanceof Error
          ? error.message
          : 'Failed to create customer. Please try again.';

        toast.error(errorMessage);
        console.error('Create customer error:', error);
      } finally {
        setIsSubmitting(false);
      }
    },
    [formData, validateForm, errors, onClose, onSuccess]
  );

  const handleClose = useCallback(() => {
    if (isSubmitting) return;

    setFormData(INITIAL_FORM_DATA);
    setErrors({});
    setActiveSection('basic');
    onClose();
  }, [isSubmitting, onClose]);

  // ============================================
  // Render
  // ============================================

  return (
    <Modal
      isOpen={isOpen}
      onClose={handleClose}
      title="Add New Customer"
      size="lg"
    >
      <form onSubmit={handleSubmit} className="space-y-6">
        {/* Section Tabs */}
        <div className="flex border-b border-secondary-200">
          <button
            type="button"
            onClick={() => setActiveSection('basic')}
            className={`px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
              activeSection === 'basic'
                ? 'border-primary-500 text-primary-600'
                : 'border-transparent text-secondary-500 hover:text-secondary-700'
            }`}
          >
            Basic Info
          </button>
          <button
            type="button"
            onClick={() => setActiveSection('address')}
            className={`px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
              activeSection === 'address'
                ? 'border-primary-500 text-primary-600'
                : 'border-transparent text-secondary-500 hover:text-secondary-700'
            }`}
          >
            Address
          </button>
          <button
            type="button"
            onClick={() => setActiveSection('preferences')}
            className={`px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
              activeSection === 'preferences'
                ? 'border-primary-500 text-primary-600'
                : 'border-transparent text-secondary-500 hover:text-secondary-700'
            }`}
          >
            Preferences
          </button>
        </div>

        {/* Basic Information Section */}
        {activeSection === 'basic' && (
          <div className="space-y-4">
            {/* Email - Required */}
            <Input
              label="Email Address"
              name="email"
              type="email"
              value={formData.email}
              onChange={handleInputChange}
              placeholder="customer@example.com"
              leftIcon={<Mail className="w-4 h-4" />}
              error={errors.email}
              disabled={isSubmitting}
              required
              autoFocus
            />

            {/* Name Row */}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <Input
                label="First Name"
                name="first_name"
                value={formData.first_name}
                onChange={handleInputChange}
                placeholder="Enter first name"
                leftIcon={<User className="w-4 h-4" />}
                error={errors.first_name}
                disabled={isSubmitting}
              />
              <Input
                label="Last Name"
                name="last_name"
                value={formData.last_name}
                onChange={handleInputChange}
                placeholder="Enter last name"
                leftIcon={<User className="w-4 h-4" />}
                error={errors.last_name}
                disabled={isSubmitting}
              />
            </div>

            {/* Phone and DOB Row */}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <Input
                label="Phone Number"
                name="phone"
                type="tel"
                value={formData.phone}
                onChange={handleInputChange}
                placeholder="+1 (555) 123-4567"
                leftIcon={<Phone className="w-4 h-4" />}
                error={errors.phone}
                disabled={isSubmitting}
              />
              <Input
                label="Date of Birth"
                name="date_of_birth"
                type="date"
                value={formData.date_of_birth}
                onChange={handleInputChange}
                leftIcon={<Calendar className="w-4 h-4" />}
                error={errors.date_of_birth}
                disabled={isSubmitting}
              />
            </div>
          </div>
        )}

        {/* Address Section */}
        {activeSection === 'address' && (
          <div className="space-y-4">
            {/* Street Address */}
            <Input
              label="Address Line 1"
              name="address1"
              value={formData.address1}
              onChange={handleInputChange}
              placeholder="123 Main Street"
              leftIcon={<MapPin className="w-4 h-4" />}
              disabled={isSubmitting}
            />

            <Input
              label="Address Line 2"
              name="address2"
              value={formData.address2}
              onChange={handleInputChange}
              placeholder="Apt, Suite, Unit, etc."
              leftIcon={<Building className="w-4 h-4" />}
              disabled={isSubmitting}
            />

            {/* City and Province Row */}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <Input
                label="City"
                name="city"
                value={formData.city}
                onChange={handleInputChange}
                placeholder="New York"
                leftIcon={<Building className="w-4 h-4" />}
                disabled={isSubmitting}
              />
              <Input
                label="State / Province"
                name="province"
                value={formData.province}
                onChange={handleInputChange}
                placeholder="NY"
                leftIcon={<MapPin className="w-4 h-4" />}
                disabled={isSubmitting}
              />
            </div>

            {/* Country and Postal Code Row */}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <Input
                label="Country"
                name="country"
                value={formData.country}
                onChange={handleInputChange}
                placeholder="United States"
                leftIcon={<Globe className="w-4 h-4" />}
                disabled={isSubmitting}
              />
              <Input
                label="Postal / ZIP Code"
                name="zip"
                value={formData.zip}
                onChange={handleInputChange}
                placeholder="10001"
                leftIcon={<Hash className="w-4 h-4" />}
                error={errors.zip}
                disabled={isSubmitting}
              />
            </div>
          </div>
        )}

        {/* Preferences Section */}
        {activeSection === 'preferences' && (
          <div className="space-y-4">
            {/* Tags */}
            <Input
              label="Tags"
              name="tags"
              value={formData.tags}
              onChange={handleInputChange}
              placeholder="VIP, Wholesale, Returning"
              leftIcon={<Tag className="w-4 h-4" />}
              helperText="Comma-separated tags to categorize this customer"
              disabled={isSubmitting}
            />

            {/* Notes */}
            <Textarea
              label="Notes"
              name="notes"
              value={formData.notes}
              onChange={handleInputChange}
              placeholder="Any additional information about this customer..."
              rows={3}
              disabled={isSubmitting}
              helperText="Internal notes about the customer (not visible to customer)"
            />

            {/* Marketing Consent */}
            <div className="bg-secondary-50 rounded-lg p-4 border border-secondary-200">
              <label className="flex items-start gap-3 cursor-pointer">
                <div className="relative flex-shrink-0 mt-0.5">
                  <input
                    type="checkbox"
                    name="accepts_marketing"
                    checked={formData.accepts_marketing}
                    onChange={handleCheckboxChange}
                    disabled={isSubmitting}
                    className="sr-only peer"
                  />
                  <div className="w-5 h-5 border-2 border-secondary-300 rounded transition-colors peer-checked:bg-primary-500 peer-checked:border-primary-500 peer-focus:ring-2 peer-focus:ring-primary-500/20">
                    {formData.accepts_marketing && (
                      <Check className="w-4 h-4 text-white absolute top-0.5 left-0.5" />
                    )}
                  </div>
                </div>
                <div>
                  <span className="text-sm font-medium text-secondary-900">
                    Email Marketing
                  </span>
                  <p className="text-sm text-secondary-500 mt-0.5">
                    Customer has consented to receive marketing emails and promotional communications.
                  </p>
                </div>
              </label>
            </div>
          </div>
        )}

        {/* Form Summary */}
        {(formData.first_name || formData.last_name || formData.email) && (
          <div className="bg-secondary-50 rounded-lg p-4 border border-secondary-200">
            <div className="flex items-start gap-3">
              <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center text-white font-semibold text-sm shadow-md shadow-primary-500/25 flex-shrink-0">
                {getInitials(formData.first_name, formData.last_name)}
              </div>
              <div className="flex-1 min-w-0">
                <p className="font-medium text-secondary-900 truncate">
                  {formData.first_name || formData.last_name
                    ? `${formData.first_name} ${formData.last_name}`.trim()
                    : 'New Customer'}
                </p>
                <p className="text-sm text-secondary-500 truncate">
                  {formData.email || 'No email'}
                </p>
                {formData.phone && (
                  <p className="text-sm text-secondary-500 truncate">{formData.phone}</p>
                )}
                {formData.tags && (
                  <div className="flex flex-wrap gap-1 mt-1">
                    {formData.tags.split(',').slice(0, 3).map((tag, i) => (
                      <span key={i} className="inline-flex px-2 py-0.5 text-xs bg-primary-100 text-primary-700 rounded-full">
                        {tag.trim()}
                      </span>
                    ))}
                  </div>
                )}
              </div>
            </div>
          </div>
        )}

        {/* Actions */}
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <Button
            type="button"
            variant="ghost"
            onClick={handleClose}
            disabled={isSubmitting}
          >
            Cancel
          </Button>
          <Button
            type="submit"
            isLoading={isSubmitting}
          >
            Create Customer
          </Button>
        </div>
      </form>
    </Modal>
  );
});

// ============================================
// Helper Functions
// ============================================

function getInitials(firstName: string, lastName: string): string {
  const first = firstName.trim().charAt(0).toUpperCase();
  const last = lastName.trim().charAt(0).toUpperCase();
  return first + last || 'C';
}

export default AddCustomerModal;
