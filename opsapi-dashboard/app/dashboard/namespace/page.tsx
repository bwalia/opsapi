"use client";

import React, { useEffect, useState } from "react";
import {
  Building2,
  Users,
  ShieldCheck,
  Settings,
  Crown,
  Calendar,
  ExternalLink,
  Star,
  StarOff,
  Loader2,
} from "lucide-react";
import { Card, Badge, Button } from "@/components/ui";
import { useNamespace } from "@/contexts/NamespaceContext";
import { namespaceService } from "@/services";
import { formatDate } from "@/lib/utils";
import type { NamespaceStats } from "@/types";
import Link from "next/link";
import toast from "react-hot-toast";

export default function NamespacePage() {
  const {
    currentNamespace,
    isNamespaceOwner,
    namespaces,
    defaultNamespaceInfo,
    setDefaultNamespace,
  } = useNamespace();
  const [stats, setStats] = useState<NamespaceStats | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [settingDefault, setSettingDefault] = useState<string | null>(null);

  useEffect(() => {
    const loadStats = async () => {
      if (!currentNamespace) {
        setIsLoading(false);
        return;
      }

      try {
        const data = await namespaceService.getNamespaceStats();
        setStats(data);
      } catch (error) {
        console.error("Failed to load namespace stats:", error);
      } finally {
        setIsLoading(false);
      }
    };

    loadStats();
  }, [currentNamespace]);

  const handleSetDefault = async (
    namespaceId: number,
    namespaceUuid: string
  ) => {
    setSettingDefault(namespaceUuid);
    try {
      const success = await setDefaultNamespace(namespaceId);
      if (success) {
        toast.success("Default namespace updated");
      } else {
        toast.error("Failed to update default namespace");
      }
    } catch {
      toast.error("Failed to update default namespace");
    } finally {
      setSettingDefault(null);
    }
  };

  if (!currentNamespace) {
    return (
      <div className="space-y-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-bold text-secondary-900">Namespace</h1>
            <p className="text-secondary-500 mt-1">No namespace selected</p>
          </div>
        </div>

        <Card className="p-8 text-center">
          <Building2 className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            No Namespace Selected
          </h2>
          <p className="text-secondary-500 mb-4">
            Select a namespace from the header or create a new one to get
            started.
          </p>
        </Card>
      </div>
    );
  }

  const isCurrentDefault = defaultNamespaceInfo?.uuid === currentNamespace.uuid;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div className="flex items-center gap-4">
          <div className="w-14 h-14 rounded-xl bg-primary-500 flex items-center justify-center text-white text-xl font-bold shadow-lg shadow-primary-500/25">
            {currentNamespace.logo_url ? (
              <img
                src={currentNamespace.logo_url}
                alt={currentNamespace.name}
                className="w-full h-full object-cover rounded-xl"
              />
            ) : (
              currentNamespace.name.charAt(0).toUpperCase()
            )}
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-2xl font-bold text-secondary-900">
                {currentNamespace.name}
              </h1>
              {isNamespaceOwner && (
                <Badge variant="warning" className="flex items-center gap-1">
                  <Crown className="w-3 h-3" />
                  Owner
                </Badge>
              )}
              {isCurrentDefault && (
                <Badge variant="info" className="flex items-center gap-1">
                  <Star className="w-3 h-3 fill-current" />
                  Default
                </Badge>
              )}
            </div>
            <p className="text-secondary-500 mt-0.5">{currentNamespace.slug}</p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {!isCurrentDefault && (
            <Button
              variant="secondary"
              onClick={() =>
                handleSetDefault(currentNamespace.id, currentNamespace.uuid)
              }
              disabled={settingDefault === currentNamespace.uuid}
            >
              {settingDefault === currentNamespace.uuid ? (
                <Loader2 className="w-4 h-4 mr-2 animate-spin" />
              ) : (
                <Star className="w-4 h-4 mr-2" />
              )}
              Set as Default
            </Button>
          )}
          {isNamespaceOwner && (
            <Link
              href="/dashboard/namespace/settings"
              className="inline-flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
            >
              <Settings className="w-4 h-4" />
              Settings
            </Link>
          )}
        </div>
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <Card className="p-5">
          <div className="flex items-center gap-4">
            <div className="w-12 h-12 rounded-xl bg-primary-100 flex items-center justify-center">
              <Users className="w-6 h-6 text-primary-600" />
            </div>
            <div>
              <p className="text-sm text-secondary-500">Members</p>
              <p className="text-2xl font-bold text-secondary-900">
                {isLoading ? "..." : stats?.total_members || 0}
              </p>
            </div>
          </div>
        </Card>

        <Card className="p-5">
          <div className="flex items-center gap-4">
            <div className="w-12 h-12 rounded-xl bg-success-100 flex items-center justify-center">
              <Building2 className="w-6 h-6 text-success-600" />
            </div>
            <div>
              <p className="text-sm text-secondary-500">Stores</p>
              <p className="text-2xl font-bold text-secondary-900">
                {isLoading ? "..." : stats?.total_stores || 0}
              </p>
            </div>
          </div>
        </Card>

        <Card className="p-5">
          <div className="flex items-center gap-4">
            <div className="w-12 h-12 rounded-xl bg-warning-100 flex items-center justify-center">
              <ShieldCheck className="w-6 h-6 text-warning-600" />
            </div>
            <div>
              <p className="text-sm text-secondary-500">Products</p>
              <p className="text-2xl font-bold text-secondary-900">
                {isLoading ? "..." : stats?.total_products || 0}
              </p>
            </div>
          </div>
        </Card>

        <Card className="p-5">
          <div className="flex items-center gap-4">
            <div className="w-12 h-12 rounded-xl bg-error-100 flex items-center justify-center">
              <Calendar className="w-6 h-6 text-error-600" />
            </div>
            <div>
              <p className="text-sm text-secondary-500">Orders</p>
              <p className="text-2xl font-bold text-secondary-900">
                {isLoading ? "..." : stats?.total_orders || 0}
              </p>
            </div>
          </div>
        </Card>
      </div>

      {/* Quick Links */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <Link href="/dashboard/namespace/members">
          <Card className="p-5 hover:shadow-md transition-shadow cursor-pointer group">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 rounded-lg bg-primary-100 flex items-center justify-center group-hover:bg-primary-200 transition-colors">
                  <Users className="w-5 h-5 text-primary-600" />
                </div>
                <div>
                  <h3 className="font-semibold text-secondary-900">
                    Manage Members
                  </h3>
                  <p className="text-sm text-secondary-500">
                    Add or remove team members
                  </p>
                </div>
              </div>
              <ExternalLink className="w-4 h-4 text-secondary-400 group-hover:text-primary-500 transition-colors" />
            </div>
          </Card>
        </Link>

        <Link href="/dashboard/namespace/roles">
          <Card className="p-5 hover:shadow-md transition-shadow cursor-pointer group">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 rounded-lg bg-warning-100 flex items-center justify-center group-hover:bg-warning-200 transition-colors">
                  <ShieldCheck className="w-5 h-5 text-warning-600" />
                </div>
                <div>
                  <h3 className="font-semibold text-secondary-900">
                    Roles & Permissions
                  </h3>
                  <p className="text-sm text-secondary-500">
                    Configure access controls
                  </p>
                </div>
              </div>
              <ExternalLink className="w-4 h-4 text-secondary-400 group-hover:text-primary-500 transition-colors" />
            </div>
          </Card>
        </Link>

        {isNamespaceOwner && (
          <Link href="/dashboard/namespace/settings">
            <Card className="p-5 hover:shadow-md transition-shadow cursor-pointer group">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="w-10 h-10 rounded-lg bg-secondary-100 flex items-center justify-center group-hover:bg-secondary-200 transition-colors">
                    <Settings className="w-5 h-5 text-secondary-600" />
                  </div>
                  <div>
                    <h3 className="font-semibold text-secondary-900">
                      Settings
                    </h3>
                    <p className="text-sm text-secondary-500">
                      Configure namespace settings
                    </p>
                  </div>
                </div>
                <ExternalLink className="w-4 h-4 text-secondary-400 group-hover:text-primary-500 transition-colors" />
              </div>
            </Card>
          </Link>
        )}
      </div>

      {/* Namespace Info */}
      <Card className="p-6">
        <h2 className="text-lg font-semibold text-secondary-900 mb-4">
          Namespace Details
        </h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <p className="text-sm text-secondary-500">Name</p>
            <p className="text-secondary-900 font-medium">
              {currentNamespace.name}
            </p>
          </div>
          <div>
            <p className="text-sm text-secondary-500">Slug</p>
            <p className="text-secondary-900 font-medium">
              {currentNamespace.slug}
            </p>
          </div>
          {currentNamespace.description && (
            <div className="sm:col-span-2">
              <p className="text-sm text-secondary-500">Description</p>
              <p className="text-secondary-900">
                {currentNamespace.description}
              </p>
            </div>
          )}
          <div>
            <p className="text-sm text-secondary-500">Plan</p>
            <Badge variant="default" className="mt-1 capitalize">
              {currentNamespace.plan}
            </Badge>
          </div>
          <div>
            <p className="text-sm text-secondary-500">Status</p>
            <Badge
              variant={
                currentNamespace.status === "active" ? "success" : "warning"
              }
              className="mt-1 capitalize"
            >
              {currentNamespace.status}
            </Badge>
          </div>
          <div>
            <p className="text-sm text-secondary-500">Created</p>
            <p className="text-secondary-900">
              {formatDate(currentNamespace.created_at)}
            </p>
          </div>
          {currentNamespace.domain && (
            <div>
              <p className="text-sm text-secondary-500">Custom Domain</p>
              <p className="text-secondary-900">{currentNamespace.domain}</p>
            </div>
          )}
        </div>
      </Card>

      {/* Other Namespaces with Default Management */}
      {namespaces.length > 1 && (
        <Card className="p-6">
          <h2 className="text-lg font-semibold text-secondary-900 mb-4">
            Your Other Namespaces
          </h2>
          <p className="text-sm text-secondary-500 mb-4">
            Click the star icon to set a namespace as your default. Your default
            namespace will be automatically selected when you log in.
          </p>
          <div className="space-y-3">
            {namespaces
              .filter((ns) => ns.uuid !== currentNamespace.uuid)
              .map((ns) => {
                const isDefault = defaultNamespaceInfo?.uuid === ns.uuid;
                return (
                  <div
                    key={ns.uuid}
                    className="flex items-center justify-between p-3 bg-secondary-50 rounded-lg group"
                  >
                    <div className="flex items-center gap-3">
                      <div className="w-10 h-10 rounded-lg bg-secondary-200 flex items-center justify-center font-semibold text-secondary-600">
                        {ns.name.charAt(0).toUpperCase()}
                      </div>
                      <div>
                        <div className="flex items-center gap-2">
                          <p className="font-medium text-secondary-900">
                            {ns.name}
                          </p>
                          {ns.is_owner && (
                            <Crown className="w-3.5 h-3.5 text-amber-500" />
                          )}
                          {isDefault && (
                            <Star className="w-3.5 h-3.5 text-primary-500 fill-primary-500" />
                          )}
                        </div>
                        <p className="text-sm text-secondary-500">{ns.slug}</p>
                      </div>
                    </div>
                    <div className="flex items-center gap-2">
                      {settingDefault === ns.uuid ? (
                        <Loader2 className="w-4 h-4 animate-spin text-primary-500" />
                      ) : (
                        <button
                          onClick={() => handleSetDefault(ns.id, ns.uuid)}
                          title={
                            isDefault ? "Current default" : "Set as default"
                          }
                          className={`p-1.5 rounded-md transition-all ${
                            isDefault
                              ? "text-primary-500"
                              : "opacity-0 group-hover:opacity-100 text-secondary-400 hover:text-primary-500 hover:bg-secondary-200"
                          }`}
                        >
                          {isDefault ? (
                            <Star className="w-4 h-4 fill-current" />
                          ) : (
                            <StarOff className="w-4 h-4" />
                          )}
                        </button>
                      )}
                      <Badge
                        variant={ns.status === "active" ? "success" : "default"}
                        className="capitalize"
                      >
                        {ns.member_status}
                      </Badge>
                    </div>
                  </div>
                );
              })}
          </div>
        </Card>
      )}
    </div>
  );
}
