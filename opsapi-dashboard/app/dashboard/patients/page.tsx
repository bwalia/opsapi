'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Plus, Search, Trash2, Edit, User, Phone, Bed, Calendar } from 'lucide-react';
import { Button, Input, Table, Pagination, Card, Badge, ConfirmDialog } from '@/components/ui';
import { AddPatientModal } from '@/components/patients';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { patientsService } from '@/services';
import { formatDate, getInitials } from '@/lib/utils';
import type { Patient, TableColumn, PaginatedResponse } from '@/types';
import toast from 'react-hot-toast';

function PatientsPageContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [patients, setPatients] = useState<Patient[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const [statusFilter, setStatusFilter] = useState<string>('');
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [patientToDelete, setPatientToDelete] = useState<Patient | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [editingPatient, setEditingPatient] = useState<Patient | null>(null);
  const fetchIdRef = useRef(0);

  const perPage = 10;

  const fetchPatients = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response: PaginatedResponse<Patient> = await patientsService.getPatients({
        page: currentPage,
        perPage,
        orderBy: sortColumn,
        orderDir: sortDirection,
        status: statusFilter || undefined,
      });

      if (fetchId === fetchIdRef.current) {
        setPatients(response.data || []);
        setTotalPages(response.totalPages || 1);
        setTotalItems(response.total || 0);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch patients:', error);
        toast.error('Failed to load patients');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection, statusFilter]);

  useEffect(() => {
    fetchPatients();
  }, [fetchPatients]);

  const handleSort = (column: string) => {
    if (sortColumn === column) {
      setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    } else {
      setSortColumn(column);
      setSortDirection('asc');
    }
    setCurrentPage(1);
  };

  const handleDeleteConfirm = async () => {
    if (!patientToDelete) return;
    setIsDeleting(true);
    try {
      await patientsService.deletePatient(patientToDelete.uuid);
      toast.success('Patient deleted successfully');
      fetchPatients();
    } catch (error) {
      console.error('Delete error:', error);
      toast.error('Failed to delete patient');
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setPatientToDelete(null);
    }
  };

  const statusVariant = (status: Patient['status']) => {
    const map: Record<Patient['status'], 'success' | 'secondary' | 'info' | 'error'> = {
      active: 'success',
      discharged: 'secondary',
      transferred: 'info',
      deceased: 'error',
    };
    return map[status] || 'secondary';
  };

  const calculateAge = (dob: string): number | null => {
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

  const columns: TableColumn<Patient>[] = [
    {
      key: 'name',
      header: 'Patient',
      sortable: true,
      render: (p) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center text-white font-semibold text-sm shadow-md shadow-primary-500/25">
            {getInitials(p.first_name, p.last_name)}
          </div>
          <div>
            <p className="font-medium text-secondary-900">
              {p.first_name} {p.last_name}
            </p>
            <p className="text-xs text-secondary-500">ID: {p.patient_id}</p>
          </div>
        </div>
      ),
    },
    {
      key: 'demographics',
      header: 'Demographics',
      render: (p) => {
        const age = calculateAge(p.date_of_birth);
        return (
          <div className="text-sm">
            <p className="text-secondary-900 capitalize">
              {p.gender}
              {age !== null ? `, ${age}y` : ''}
            </p>
            <p className="text-xs text-secondary-500">{formatDate(p.date_of_birth)}</p>
          </div>
        );
      },
    },
    {
      key: 'room',
      header: 'Room',
      render: (p) =>
        p.room_number ? (
          <div className="flex items-center gap-2 text-sm text-secondary-600">
            <Bed className="w-3.5 h-3.5 text-secondary-400" />
            <span>
              {p.room_number}
              {p.bed_number ? ` / ${p.bed_number}` : ''}
            </span>
          </div>
        ) : (
          <span className="text-sm text-secondary-400">—</span>
        ),
    },
    {
      key: 'admission',
      header: 'Admission',
      sortable: true,
      render: (p) =>
        p.admission_date ? (
          <div className="flex items-center gap-2 text-sm text-secondary-600">
            <Calendar className="w-3.5 h-3.5 text-secondary-400" />
            <span>{formatDate(p.admission_date)}</span>
          </div>
        ) : (
          <span className="text-sm text-secondary-400">—</span>
        ),
    },
    {
      key: 'phone',
      header: 'Contact',
      render: (p) =>
        p.phone ? (
          <div className="flex items-center gap-2 text-sm text-secondary-600">
            <Phone className="w-3.5 h-3.5 text-secondary-400" />
            <span>{p.phone}</span>
          </div>
        ) : (
          <span className="text-sm text-secondary-400">—</span>
        ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (p) => <Badge variant={statusVariant(p.status)}>{p.status}</Badge>,
    },
    {
      key: 'actions',
      header: '',
      width: 'w-20',
      render: (p) => (
        <div className="flex items-center gap-2">
          {canUpdate('patients') && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                setEditingPatient(p);
                setIsModalOpen(true);
              }}
              className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
              title="Edit"
            >
              <Edit className="w-4 h-4" />
            </button>
          )}
          {canDelete('patients') && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                setPatientToDelete(p);
                setDeleteDialogOpen(true);
              }}
              className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
              title="Delete"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  const filteredPatients = React.useMemo(() => {
    if (!searchQuery) return patients;
    const q = searchQuery.toLowerCase();
    return patients.filter(
      (p) =>
        p.first_name?.toLowerCase().includes(q) ||
        p.last_name?.toLowerCase().includes(q) ||
        p.patient_id?.toLowerCase().includes(q) ||
        p.room_number?.toLowerCase().includes(q) ||
        p.phone?.includes(q)
    );
  }, [patients, searchQuery]);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Patients</h1>
          <p className="text-secondary-500 mt-1">
            Manage patient records, care plans, and medical history
          </p>
        </div>
        {canCreate('patients') && (
          <Button
            leftIcon={<Plus className="w-4 h-4" />}
            onClick={() => {
              setEditingPatient(null);
              setIsModalOpen(true);
            }}
          >
            Add Patient
          </Button>
        )}
      </div>

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[200px] max-w-sm">
            <Input
              placeholder="Search patients..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <div className="flex items-center gap-2">
            {['', 'active', 'discharged', 'transferred'].map((s) => (
              <button
                key={s || 'all'}
                onClick={() => {
                  setStatusFilter(s);
                  setCurrentPage(1);
                }}
                className={`px-3 py-1.5 text-xs rounded-lg transition-colors capitalize ${
                  statusFilter === s
                    ? 'bg-primary-500 text-white'
                    : 'bg-secondary-100 text-secondary-700 hover:bg-secondary-200'
                }`}
              >
                {s || 'All'}
              </button>
            ))}
          </div>
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={filteredPatients}
          keyExtractor={(p) => p.uuid}
          onRowClick={(p) => {
            window.location.href = `/dashboard/patients/${p.uuid}`;
          }}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No patients found."
        />
        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={perPage}
          onPageChange={setCurrentPage}
        />
      </div>

      <ConfirmDialog
        isOpen={deleteDialogOpen}
        onClose={() => setDeleteDialogOpen(false)}
        onConfirm={handleDeleteConfirm}
        title="Delete Patient"
        message={`Are you sure you want to delete "${patientToDelete?.first_name} ${patientToDelete?.last_name}"? All medical records will be cascade-deleted.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />

      <AddPatientModal
        isOpen={isModalOpen}
        onClose={() => {
          setIsModalOpen(false);
          setEditingPatient(null);
        }}
        patient={editingPatient}
        onSuccess={() => {
          fetchPatients();
          if (!editingPatient) setCurrentPage(1);
        }}
      />
    </div>
  );
}

export default function PatientsPage() {
  return (
    <ProtectedPage module="patients" title="Patients">
      <PatientsPageContent />
    </ProtectedPage>
  );
}
