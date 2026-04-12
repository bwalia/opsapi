'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Plus, Search, Trash2, Edit, Building2, MapPin, Phone, Bed } from 'lucide-react';
import { Button, Input, Table, Pagination, Card, Badge, ConfirmDialog } from '@/components/ui';
import { AddHospitalModal } from '@/components/hospitals';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { hospitalsService } from '@/services';
import { formatDate } from '@/lib/utils';
import type { Hospital, TableColumn, PaginatedResponse } from '@/types';
import toast from 'react-hot-toast';

function HospitalsPageContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [hospitals, setHospitals] = useState<Hospital[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [hospitalToDelete, setHospitalToDelete] = useState<Hospital | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [editingHospital, setEditingHospital] = useState<Hospital | null>(null);
  const fetchIdRef = useRef(0);

  const perPage = 10;

  const fetchHospitals = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response: PaginatedResponse<Hospital> = await hospitalsService.getHospitals({
        page: currentPage,
        perPage,
        orderBy: sortColumn,
        orderDir: sortDirection,
      });

      if (fetchId === fetchIdRef.current) {
        setHospitals(response.data || []);
        setTotalPages(response.totalPages || 1);
        setTotalItems(response.total || 0);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch hospitals:', error);
        toast.error('Failed to load hospitals');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection]);

  useEffect(() => {
    fetchHospitals();
  }, [fetchHospitals]);

  const handleSort = (column: string) => {
    if (sortColumn === column) {
      setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    } else {
      setSortColumn(column);
      setSortDirection('asc');
    }
    setCurrentPage(1);
  };

  const handleDeleteClick = (hospital: Hospital) => {
    setHospitalToDelete(hospital);
    setDeleteDialogOpen(true);
  };

  const handleDeleteConfirm = async () => {
    if (!hospitalToDelete) return;

    setIsDeleting(true);
    try {
      await hospitalsService.deleteHospital(hospitalToDelete.uuid);
      toast.success('Hospital deleted successfully');
      fetchHospitals();
    } catch (error) {
      console.error('Delete hospital error:', error);
      toast.error('Failed to delete hospital');
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setHospitalToDelete(null);
    }
  };

  const getTypeBadge = (type: Hospital['type']) => {
    const map: Record<Hospital['type'], { label: string; variant: 'info' | 'success' | 'warning' }> = {
      hospital: { label: 'Hospital', variant: 'info' },
      care_home: { label: 'Care Home', variant: 'success' },
      clinic: { label: 'Clinic', variant: 'warning' },
    };
    const config = map[type] || map.hospital;
    return <Badge variant={config.variant}>{config.label}</Badge>;
  };

  const getStatusBadge = (status: Hospital['status']) => {
    const map: Record<Hospital['status'], 'success' | 'secondary' | 'error'> = {
      active: 'success',
      inactive: 'secondary',
      suspended: 'error',
    };
    return <Badge variant={map[status] || 'secondary'}>{status}</Badge>;
  };

  const columns: TableColumn<Hospital>[] = [
    {
      key: 'name',
      header: 'Hospital',
      sortable: true,
      render: (h) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center text-white shadow-md shadow-primary-500/25">
            <Building2 className="w-5 h-5" />
          </div>
          <div>
            <p className="font-medium text-secondary-900">{h.name}</p>
            <p className="text-xs text-secondary-500">{h.license_number}</p>
          </div>
        </div>
      ),
    },
    {
      key: 'type',
      header: 'Type',
      render: (h) => getTypeBadge(h.type),
    },
    {
      key: 'location',
      header: 'Location',
      render: (h) => (
        <div className="flex items-center gap-2 text-secondary-600">
          <MapPin className="w-4 h-4 text-secondary-400" />
          <span className="text-sm">
            {[h.city, h.state, h.country].filter(Boolean).join(', ') || '—'}
          </span>
        </div>
      ),
    },
    {
      key: 'capacity',
      header: 'Capacity',
      render: (h) => (
        <div className="flex items-center gap-2 text-sm text-secondary-600">
          <Bed className="w-3.5 h-3.5 text-secondary-400" />
          <span>{h.capacity || 0} beds</span>
        </div>
      ),
    },
    {
      key: 'phone',
      header: 'Contact',
      render: (h) =>
        h.phone ? (
          <div className="flex items-center gap-2 text-sm text-secondary-600">
            <Phone className="w-3.5 h-3.5 text-secondary-400" />
            <span>{h.phone}</span>
          </div>
        ) : (
          <span className="text-sm text-secondary-400">—</span>
        ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (h) => getStatusBadge(h.status),
    },
    {
      key: 'created_at',
      header: 'Added',
      sortable: true,
      render: (h) => <span className="text-sm text-secondary-600">{formatDate(h.created_at || '')}</span>,
    },
    {
      key: 'actions',
      header: '',
      width: 'w-20',
      render: (h) => (
        <div className="flex items-center gap-2">
          {canUpdate('hospitals') && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                setEditingHospital(h);
                setIsModalOpen(true);
              }}
              className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
              title="Edit"
            >
              <Edit className="w-4 h-4" />
            </button>
          )}
          {canDelete('hospitals') && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                handleDeleteClick(h);
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

  const filteredHospitals = React.useMemo(() => {
    if (!searchQuery) return hospitals;
    const q = searchQuery.toLowerCase();
    return hospitals.filter(
      (h) =>
        h.name?.toLowerCase().includes(q) ||
        h.license_number?.toLowerCase().includes(q) ||
        h.city?.toLowerCase().includes(q) ||
        h.type?.toLowerCase().includes(q)
    );
  }, [hospitals, searchQuery]);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Hospitals &amp; Care Homes</h1>
          <p className="text-secondary-500 mt-1">Manage facilities, departments, and wards</p>
        </div>
        {canCreate('hospitals') && (
          <Button
            leftIcon={<Plus className="w-4 h-4" />}
            onClick={() => {
              setEditingHospital(null);
              setIsModalOpen(true);
            }}
          >
            Add Hospital
          </Button>
        )}
      </div>

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[200px] max-w-sm">
            <Input
              placeholder="Search hospitals..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={filteredHospitals}
          keyExtractor={(h) => h.uuid}
          onRowClick={(h) => {
            window.location.href = `/dashboard/hospitals/${h.uuid}`;
          }}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No hospitals found. Click 'Add Hospital' to create one."
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
        title="Delete Hospital"
        message={`Are you sure you want to delete "${hospitalToDelete?.name}"? All associated patients, staff, and records will be cascade-deleted. This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />

      <AddHospitalModal
        isOpen={isModalOpen}
        onClose={() => {
          setIsModalOpen(false);
          setEditingHospital(null);
        }}
        hospital={editingHospital}
        onSuccess={() => {
          fetchHospitals();
          if (!editingHospital) setCurrentPage(1);
        }}
      />
    </div>
  );
}

export default function HospitalsPage() {
  return (
    <ProtectedPage module="hospitals" title="Hospitals">
      <HospitalsPageContent />
    </ProtectedPage>
  );
}
