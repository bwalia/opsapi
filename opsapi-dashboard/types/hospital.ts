/**
 * Hospital & Care Home Patient Management System - Type Definitions
 *
 * Types for the hospital CRM, patient management, care plans, medications,
 * daily logs, family members, and patient-controlled access sharing.
 */

// =============================================================================
// HOSPITAL
// =============================================================================

export type HospitalType = 'hospital' | 'care_home' | 'clinic';
export type HospitalStatus = 'active' | 'inactive' | 'suspended';

export interface Hospital {
  id: number;
  uuid: string;
  name: string;
  type: HospitalType;
  license_number: string;
  address?: string;
  city?: string;
  state?: string;
  postal_code?: string;
  country?: string;
  phone?: string;
  email?: string;
  website?: string;
  capacity?: number;
  specialties?: string[] | string;
  services?: string[] | string;
  facilities?: string[] | string;
  emergency_services?: boolean;
  operating_hours?: Record<string, unknown> | string;
  contact_person?: string;
  contact_phone?: string;
  status: HospitalStatus;
  created_at?: string;
  updated_at?: string;
}

export interface CreateHospitalDto {
  name: string;
  type: HospitalType;
  license_number: string;
  address?: string;
  city?: string;
  state?: string;
  postal_code?: string;
  country?: string;
  phone?: string;
  email?: string;
  website?: string;
  capacity?: number;
  specialties?: string[];
  services?: string[];
  facilities?: string[];
  emergency_services?: boolean;
  operating_hours?: Record<string, unknown>;
  contact_person?: string;
  contact_phone?: string;
  status?: HospitalStatus;
}

// =============================================================================
// PATIENT
// =============================================================================

export type PatientStatus = 'active' | 'discharged' | 'transferred' | 'deceased';
export type Gender = 'male' | 'female' | 'other';

export interface Patient {
  id: number;
  uuid: string;
  hospital_id: number;
  patient_id: string;
  first_name: string;
  last_name: string;
  date_of_birth: string;
  gender: Gender;
  phone?: string;
  email?: string;
  address?: string;
  city?: string;
  state?: string;
  postal_code?: string;
  country?: string;
  emergency_contact_name?: string;
  emergency_contact_phone?: string;
  emergency_contact_relation?: string;
  blood_type?: string;
  allergies?: string[] | string;
  medical_conditions?: string[] | string;
  medications?: string[] | string;
  insurance_provider?: string;
  insurance_number?: string;
  admission_date?: string;
  discharge_date?: string;
  room_number?: string;
  bed_number?: string;
  status: PatientStatus;
  notes?: string;
  created_at?: string;
  updated_at?: string;
}

export interface CreatePatientDto {
  hospital_id: number;
  patient_id: string;
  first_name: string;
  last_name: string;
  date_of_birth: string;
  gender: Gender;
  phone?: string;
  email?: string;
  address?: string;
  city?: string;
  state?: string;
  postal_code?: string;
  country?: string;
  emergency_contact_name?: string;
  emergency_contact_phone?: string;
  emergency_contact_relation?: string;
  blood_type?: string;
  allergies?: string[];
  medical_conditions?: string[];
  medications?: string[];
  insurance_provider?: string;
  insurance_number?: string;
  admission_date?: string;
  room_number?: string;
  bed_number?: string;
  status?: PatientStatus;
  notes?: string;
}

// =============================================================================
// CARE PLAN
// =============================================================================

export type CarePlanType =
  | 'general'
  | 'medication'
  | 'rehabilitation'
  | 'dementia'
  | 'palliative'
  | 'nutrition';
export type CarePlanStatus = 'draft' | 'active' | 'completed' | 'cancelled';
export type CarePlanPriority = 'low' | 'normal' | 'high' | 'urgent';

export interface CarePlan {
  id: number;
  uuid: string;
  patient_id: number;
  hospital_id: number;
  plan_type: CarePlanType;
  title: string;
  description?: string;
  goals?: string[] | string;
  interventions?: string[] | string;
  medication_schedule?: unknown;
  daily_routines?: unknown;
  risk_assessments?: unknown;
  dietary_requirements?: unknown;
  mobility_aids?: string[] | string;
  communication_needs?: unknown;
  created_by?: string;
  approved_by?: string;
  review_date?: string;
  start_date: string;
  end_date?: string;
  status: CarePlanStatus;
  priority: CarePlanPriority;
  notes?: string;
  created_at?: string;
  updated_at?: string;
}

export interface CreateCarePlanDto {
  plan_type: CarePlanType;
  title: string;
  description?: string;
  goals?: string[];
  interventions?: string[];
  start_date: string;
  end_date?: string;
  review_date?: string;
  priority?: CarePlanPriority;
  status?: CarePlanStatus;
  notes?: string;
}

// =============================================================================
// MEDICATION
// =============================================================================

export type MedicationStatus = 'active' | 'paused' | 'discontinued' | 'completed';

export interface Medication {
  id: number;
  uuid: string;
  patient_id: number;
  care_plan_id?: number;
  name: string;
  generic_name?: string;
  dosage: string;
  unit?: string;
  route?: string;
  frequency: string;
  schedule_times?: string[] | string;
  instructions?: string;
  purpose?: string;
  prescriber?: string;
  pharmacy?: string;
  start_date: string;
  end_date?: string;
  is_prn?: boolean;
  max_daily_doses?: number;
  side_effects?: string[] | string;
  interactions?: string[] | string;
  allergies_check?: boolean;
  status: MedicationStatus;
  discontinued_reason?: string;
  notes?: string;
  created_at?: string;
  updated_at?: string;
}

export interface CreateMedicationDto {
  name: string;
  generic_name?: string;
  dosage: string;
  unit?: string;
  route?: string;
  frequency: string;
  schedule_times?: string[];
  instructions?: string;
  purpose?: string;
  prescriber?: string;
  start_date: string;
  end_date?: string;
  is_prn?: boolean;
  max_daily_doses?: number;
  status?: MedicationStatus;
  notes?: string;
}

// =============================================================================
// CARE LOG (shift-based staff updates)
// =============================================================================

export type CareLogType =
  | 'feeding'
  | 'medication'
  | 'personal_care'
  | 'observation'
  | 'incident'
  | 'handover';
export type Shift = 'morning' | 'afternoon' | 'night';
export type CareLogStatus = 'draft' | 'completed' | 'reviewed' | 'flagged';

export interface CareLog {
  id: number;
  uuid: string;
  patient_id: number;
  care_plan_id?: number;
  staff_id?: number;
  log_type: CareLogType;
  log_date: string;
  log_time?: string;
  shift?: Shift;
  summary: string;
  details?: unknown;
  medication_name?: string;
  medication_dose?: string;
  medication_administered?: boolean;
  meal_type?: string;
  intake_amount?: string;
  mood?: string;
  behaviour_notes?: string;
  incident_type?: string;
  incident_severity?: string;
  action_taken?: string;
  follow_up_required?: boolean;
  status: CareLogStatus;
  created_at?: string;
  updated_at?: string;
}

export interface CreateCareLogDto {
  log_type: CareLogType;
  log_date: string;
  log_time?: string;
  shift?: Shift;
  summary: string;
  medication_name?: string;
  medication_dose?: string;
  medication_administered?: boolean;
  meal_type?: string;
  intake_amount?: string;
  mood?: string;
  behaviour_notes?: string;
  incident_type?: string;
  incident_severity?: string;
  action_taken?: string;
  status?: CareLogStatus;
}

// =============================================================================
// DAILY LOG
// =============================================================================

export interface DailyLog {
  id: number;
  uuid: string;
  patient_id: number;
  log_date: string;
  shift?: Shift;
  recorded_by: string;
  sleep_quality?: string;
  sleep_hours?: number;
  sleep_notes?: string;
  breakfast_intake?: string;
  lunch_intake?: string;
  dinner_intake?: string;
  snack_intake?: string;
  fluid_intake_ml?: number;
  nutrition_notes?: string;
  mobility_level?: string;
  exercise_completed?: boolean;
  activity_notes?: string;
  overall_mood?: string;
  general_wellbeing?: string;
  pain_level?: number;
  weight?: number;
  concerns?: string;
  family_notified?: boolean;
  family_visit?: boolean;
  family_visit_notes?: string;
  status: string;
  created_at?: string;
  updated_at?: string;
}

export interface CreateDailyLogDto {
  log_date: string;
  shift?: Shift;
  sleep_quality?: string;
  sleep_hours?: number;
  breakfast_intake?: string;
  lunch_intake?: string;
  dinner_intake?: string;
  fluid_intake_ml?: number;
  mobility_level?: string;
  overall_mood?: string;
  general_wellbeing?: string;
  pain_level?: number;
  concerns?: string;
}

// =============================================================================
// FAMILY MEMBER
// =============================================================================

export type FamilyRelationship =
  | 'spouse'
  | 'daughter'
  | 'son'
  | 'sibling'
  | 'parent'
  | 'guardian'
  | 'other';

export interface FamilyMember {
  id: number;
  uuid: string;
  patient_id: number;
  user_id?: number;
  first_name: string;
  last_name: string;
  relationship: FamilyRelationship;
  is_next_of_kin?: boolean;
  is_emergency_contact?: boolean;
  is_power_of_attorney?: boolean;
  phone?: string;
  email?: string;
  address?: string;
  preferred_contact_method?: string;
  can_make_decisions?: boolean;
  verified?: boolean;
  status: string;
  notes?: string;
  created_at?: string;
  updated_at?: string;
}

export interface CreateFamilyMemberDto {
  first_name: string;
  last_name: string;
  relationship: FamilyRelationship;
  is_next_of_kin?: boolean;
  is_emergency_contact?: boolean;
  is_power_of_attorney?: boolean;
  phone?: string;
  email?: string;
  address?: string;
  preferred_contact_method?: string;
}

// =============================================================================
// PATIENT ACCESS CONTROL
// =============================================================================

export type AccessRole =
  | 'family_member'
  | 'caregiver'
  | 'doctor'
  | 'specialist'
  | 'social_worker';
export type AccessLevel = 'read' | 'read_write' | 'emergency_only';
export type AccessStatus = 'pending' | 'active' | 'expired' | 'revoked' | 'suspended';

export interface PatientAccessControl {
  id: number;
  uuid: string;
  patient_id: number;
  granted_to: string;
  granted_to_user_id?: number;
  role: AccessRole;
  relationship?: string;
  access_level: AccessLevel;
  scope?: string[] | string;
  granted_by?: string;
  expires_at?: string;
  revoked_at?: string;
  revoked_reason?: string;
  status: AccessStatus;
  consent_given?: boolean;
  consent_date?: string;
  last_accessed_at?: string;
  access_count?: number;
  notes?: string;
  created_at?: string;
  updated_at?: string;
}

export interface CreateAccessControlDto {
  granted_to: string;
  role: AccessRole;
  relationship?: string;
  access_level?: AccessLevel;
  scope?: string[];
  expires_at?: string;
  consent_given?: boolean;
  notes?: string;
}

// =============================================================================
// PATIENT ALERT
// =============================================================================

export type AlertType =
  | 'medication_reminder'
  | 'emergency'
  | 'fall'
  | 'wandering'
  | 'missed_care'
  | 'vital_sign'
  | 'appointment'
  | 'family_notification';
export type AlertSeverity = 'info' | 'warning' | 'critical' | 'emergency';
export type AlertStatus = 'active' | 'acknowledged' | 'resolved' | 'dismissed' | 'escalated';

export interface PatientAlert {
  id: number;
  uuid: string;
  patient_id: number;
  hospital_id: number;
  alert_type: AlertType;
  severity: AlertSeverity;
  title: string;
  message: string;
  details?: unknown;
  triggered_by?: string;
  assigned_to?: string;
  acknowledged_by?: string;
  acknowledged_at?: string;
  resolved_by?: string;
  resolved_at?: string;
  resolution_notes?: string;
  notify_family?: boolean;
  status: AlertStatus;
  created_at?: string;
  updated_at?: string;
}

export interface CreateAlertDto {
  alert_type: AlertType;
  severity: AlertSeverity;
  title: string;
  message: string;
  assigned_to?: string;
  notify_family?: boolean;
}

// =============================================================================
// DEMENTIA ASSESSMENT
// =============================================================================

export type DementiaSeverity = 'mild' | 'moderate' | 'severe';
export type RiskLevel = 'none' | 'low' | 'moderate' | 'high';

export interface DementiaAssessment {
  id: number;
  uuid: string;
  patient_id: number;
  assessor: string;
  assessment_type: string;
  assessment_date: string;
  score?: number;
  max_score?: number;
  severity_level?: DementiaSeverity;
  wandering_risk?: RiskLevel;
  fall_risk?: RiskLevel;
  communication_ability?: string;
  next_assessment_date?: string;
  status: string;
  notes?: string;
  created_at?: string;
  updated_at?: string;
}
