'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Plus, Search, Trash2, Edit, Mail, Phone, MapPin } from 'lucide-react';
import { Button, Input, Table, Pagination, Card, ConfirmDialog } from '@/components/ui';
import { customersService } from '@/services';
import { formatDate, getInitials, getFullName } from '@/lib/utils';
import type { Customer, TableColumn, PaginatedResponse } from '@/types';
import toast from 'react-hot-toast';

export default function CustomersPage() {
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [customerToDelete, setCustomerToDelete] = useState<Customer | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const fetchIdRef = useRef(0);

  const perPage = 10;

  const fetchCustomers = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response: PaginatedResponse<Customer> = await customersService.getCustomers({
        page: currentPage,
        perPage,
        orderBy: sortColumn,
        orderDir: sortDirection,
      });

      // Only update state if this is still the latest fetch
      if (fetchId === fetchIdRef.current) {
        setCustomers(response.data || []);
        setTotalPages(response.totalPages || 1);
        setTotalItems(response.total || 0);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch customers:', error);
        toast.error('Failed to load customers');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection]);

  useEffect(() => {
    fetchCustomers();
  }, [fetchCustomers]);

  const handleSort = (column: string) => {
    if (sortColumn === column) {
      setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    } else {
      setSortColumn(column);
      setSortDirection('asc');
    }
    setCurrentPage(1);
  };

  const handleDeleteClick = (customer: Customer) => {
    setCustomerToDelete(customer);
    setDeleteDialogOpen(true);
  };

  const handleDeleteConfirm = async () => {
    if (!customerToDelete) return;

    setIsDeleting(true);
    try {
      await customersService.deleteCustomer(customerToDelete.uuid);
      toast.success('Customer deleted successfully');
      fetchCustomers();
    } catch (error) {
      toast.error('Failed to delete customer');
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setCustomerToDelete(null);
    }
  };

  const getLocation = (customer: Customer): string => {
    const parts = [customer.city, customer.state, customer.country].filter(Boolean);
    return parts.join(', ') || 'No location';
  };

  const columns: TableColumn<Customer>[] = [
    {
      key: 'name',
      header: 'Customer',
      sortable: true,
      render: (customer) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center text-white font-semibold text-sm shadow-md shadow-primary-500/25">
            {getInitials(customer.first_name, customer.last_name)}
          </div>
          <div>
            <p className="font-medium text-secondary-900">
              {getFullName(customer.first_name, customer.last_name)}
            </p>
            <p className="text-xs text-secondary-500">{customer.email}</p>
          </div>
        </div>
      ),
    },
    {
      key: 'contact',
      header: 'Contact',
      render: (customer) => (
        <div className="space-y-1">
          {customer.phone && (
            <div className="flex items-center gap-2 text-sm text-secondary-600">
              <Phone className="w-3.5 h-3.5 text-secondary-400" />
              <span>{customer.phone}</span>
            </div>
          )}
          {customer.email && (
            <div className="flex items-center gap-2 text-sm text-secondary-600">
              <Mail className="w-3.5 h-3.5 text-secondary-400" />
              <span className="truncate max-w-[180px]">{customer.email}</span>
            </div>
          )}
        </div>
      ),
    },
    {
      key: 'location',
      header: 'Location',
      render: (customer) => (
        <div className="flex items-center gap-2 text-secondary-600">
          <MapPin className="w-4 h-4 text-secondary-400" />
          <span className="text-sm">{getLocation(customer)}</span>
        </div>
      ),
    },
    {
      key: 'created_at',
      header: 'Joined',
      sortable: true,
      render: (customer) => (
        <span className="text-sm text-secondary-600">{formatDate(customer.created_at)}</span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-20',
      render: (customer) => (
        <div className="flex items-center gap-2">
          <button
            onClick={(e) => {
              e.stopPropagation();
              window.location.href = `/dashboard/customers/${customer.uuid}`;
            }}
            className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
          >
            <Edit className="w-4 h-4" />
          </button>
          <button
            onClick={(e) => {
              e.stopPropagation();
              handleDeleteClick(customer);
            }}
            className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
      ),
    },
  ];

  const filteredCustomers = React.useMemo(() => {
    if (!searchQuery) return customers;

    const query = searchQuery.toLowerCase();
    return customers.filter(
      (customer) =>
        customer.first_name?.toLowerCase().includes(query) ||
        customer.last_name?.toLowerCase().includes(query) ||
        customer.email?.toLowerCase().includes(query) ||
        customer.phone?.includes(query)
    );
  }, [customers, searchQuery]);

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Customers</h1>
          <p className="text-secondary-500 mt-1">Manage your customer database</p>
        </div>
        <Button leftIcon={<Plus className="w-4 h-4" />}>Add Customer</Button>
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[200px] max-w-sm">
            <Input
              placeholder="Search customers..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
        </div>
      </Card>

      {/* Customers Table */}
      <div>
        <Table
          columns={columns}
          data={filteredCustomers}
          keyExtractor={(customer) => customer.uuid}
          onRowClick={(customer) => {
            window.location.href = `/dashboard/customers/${customer.uuid}`;
          }}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No customers found"
        />

        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={perPage}
          onPageChange={setCurrentPage}
        />
      </div>

      {/* Delete Confirmation Dialog */}
      <ConfirmDialog
        isOpen={deleteDialogOpen}
        onClose={() => setDeleteDialogOpen(false)}
        onConfirm={handleDeleteConfirm}
        title="Delete Customer"
        message={`Are you sure you want to delete "${getFullName(customerToDelete?.first_name, customerToDelete?.last_name)}"? This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />
    </div>
  );
}
