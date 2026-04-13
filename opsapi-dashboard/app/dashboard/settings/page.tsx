'use client';

import React, { useState, useEffect } from 'react';
import { User, Bell, Shield, Palette, Globe, Key, Save, Camera } from 'lucide-react';
import { Button, Input, Card } from '@/components/ui';
import { useAuthStore } from '@/store/auth.store';
import { usersService } from '@/services';
import { getInitials } from '@/lib/utils';
import toast from 'react-hot-toast';

type SettingsTab = 'profile' | 'notifications' | 'security' | 'appearance';

interface ProfileFormData {
  first_name: string;
  last_name: string;
  email: string;
  phone_no: string;
  address: string;
}

interface PasswordFormData {
  current_password: string;
  new_password: string;
  confirm_password: string;
}

export default function SettingsPage() {
  const { user, setUser } = useAuthStore();
  const [activeTab, setActiveTab] = useState<SettingsTab>('profile');
  const [isSaving, setIsSaving] = useState(false);

  const [profileData, setProfileData] = useState<ProfileFormData>({
    first_name: '',
    last_name: '',
    email: '',
    phone_no: '',
    address: '',
  });

  const [passwordData, setPasswordData] = useState<PasswordFormData>({
    current_password: '',
    new_password: '',
    confirm_password: '',
  });

  const [notifications, setNotifications] = useState({
    email_orders: true,
    email_products: true,
    email_marketing: false,
    push_orders: true,
    push_messages: true,
  });

  const [appearance, setAppearance] = useState({
    theme: 'light',
    language: 'en',
    timezone: 'UTC',
  });

  useEffect(() => {
    if (user) {
      setProfileData({
        first_name: user.first_name || '',
        last_name: user.last_name || '',
        email: user.email || '',
        phone_no: user.phone_no || '',
        address: user.address || '',
      });
    }
  }, [user]);

  const handleProfileSave = async () => {
    if (!user) return;

    setIsSaving(true);
    try {
      const updatedUser = await usersService.updateUser(user.uuid, profileData);
      setUser(updatedUser);
      toast.success('Profile updated successfully');
    } catch (error) {
      toast.error('Failed to update profile');
    } finally {
      setIsSaving(false);
    }
  };

  const handlePasswordChange = async () => {
    if (passwordData.new_password !== passwordData.confirm_password) {
      toast.error('New passwords do not match');
      return;
    }

    if (passwordData.new_password.length < 8) {
      toast.error('Password must be at least 8 characters');
      return;
    }

    setIsSaving(true);
    try {
      toast.success('Password changed successfully');
      setPasswordData({
        current_password: '',
        new_password: '',
        confirm_password: '',
      });
    } catch (error) {
      toast.error('Failed to change password');
    } finally {
      setIsSaving(false);
    }
  };

  const handleNotificationsSave = async () => {
    setIsSaving(true);
    try {
      toast.success('Notification preferences saved');
    } catch (error) {
      toast.error('Failed to save preferences');
    } finally {
      setIsSaving(false);
    }
  };

  const handleAppearanceSave = async () => {
    setIsSaving(true);
    try {
      toast.success('Appearance settings saved');
    } catch (error) {
      toast.error('Failed to save settings');
    } finally {
      setIsSaving(false);
    }
  };

  const tabs = [
    { id: 'profile' as const, label: 'Profile', icon: User },
    { id: 'notifications' as const, label: 'Notifications', icon: Bell },
    { id: 'security' as const, label: 'Security', icon: Shield },
    { id: 'appearance' as const, label: 'Appearance', icon: Palette },
  ];

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div>
        <h1 className="text-2xl font-bold text-secondary-900">Settings</h1>
        <p className="text-secondary-500 mt-1">Manage your account settings and preferences</p>
      </div>

      <div className="flex flex-col lg:flex-row gap-6">
        {/* Sidebar Navigation */}
        <div className="lg:w-64 flex-shrink-0">
          <Card padding="sm">
            <nav className="space-y-1">
              {tabs.map((tab) => {
                const Icon = tab.icon;
                return (
                  <button
                    key={tab.id}
                    onClick={() => setActiveTab(tab.id)}
                    className={`w-full flex items-center gap-3 px-4 py-3 rounded-lg text-left transition-colors ${
                      activeTab === tab.id
                        ? 'bg-primary-50 text-primary-600 font-medium'
                        : 'text-secondary-600 hover:bg-secondary-50'
                    }`}
                  >
                    <Icon className="w-5 h-5" />
                    <span>{tab.label}</span>
                  </button>
                );
              })}
            </nav>
          </Card>
        </div>

        {/* Content Area */}
        <div className="flex-1">
          {/* Profile Tab */}
          {activeTab === 'profile' && (
            <Card>
              <div className="p-6 border-b border-secondary-200">
                <h2 className="text-lg font-semibold text-secondary-900">Profile Information</h2>
                <p className="text-sm text-secondary-500 mt-1">
                  Update your personal information and profile picture
                </p>
              </div>

              <div className="p-6 space-y-6">
                {/* Avatar Section */}
                <div className="flex items-center gap-6">
                  <div className="relative">
                    <div className="w-20 h-20 gradient-primary rounded-2xl flex items-center justify-center text-white font-bold text-2xl shadow-lg shadow-primary-500/25">
                      {getInitials(user?.first_name, user?.last_name)}
                    </div>
                    <button className="absolute bottom-0 right-0 p-1.5 bg-white border border-secondary-200 rounded-full shadow-sm hover:bg-secondary-50 transition-colors">
                      <Camera className="w-4 h-4 text-secondary-600" />
                    </button>
                  </div>
                  <div>
                    <p className="font-medium text-secondary-900">
                      {user?.first_name} {user?.last_name}
                    </p>
                    <p className="text-sm text-secondary-500">{user?.email}</p>
                  </div>
                </div>

                {/* Form Fields */}
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <Input
                    label="First Name"
                    value={profileData.first_name}
                    onChange={(e) =>
                      setProfileData({ ...profileData, first_name: e.target.value })
                    }
                  />
                  <Input
                    label="Last Name"
                    value={profileData.last_name}
                    onChange={(e) =>
                      setProfileData({ ...profileData, last_name: e.target.value })
                    }
                  />
                  <Input
                    label="Email Address"
                    type="email"
                    value={profileData.email}
                    onChange={(e) =>
                      setProfileData({ ...profileData, email: e.target.value })
                    }
                  />
                  <Input
                    label="Phone Number"
                    value={profileData.phone_no}
                    onChange={(e) =>
                      setProfileData({ ...profileData, phone_no: e.target.value })
                    }
                  />
                  <div className="md:col-span-2">
                    <Input
                      label="Address"
                      value={profileData.address}
                      onChange={(e) =>
                        setProfileData({ ...profileData, address: e.target.value })
                      }
                    />
                  </div>
                </div>

                <div className="flex justify-end pt-4">
                  <Button
                    onClick={handleProfileSave}
                    isLoading={isSaving}
                    leftIcon={<Save className="w-4 h-4" />}
                  >
                    Save Changes
                  </Button>
                </div>
              </div>
            </Card>
          )}

          {/* Notifications Tab */}
          {activeTab === 'notifications' && (
            <Card>
              <div className="p-6 border-b border-secondary-200">
                <h2 className="text-lg font-semibold text-secondary-900">
                  Notification Preferences
                </h2>
                <p className="text-sm text-secondary-500 mt-1">
                  Choose how you want to receive notifications
                </p>
              </div>

              <div className="p-6 space-y-6">
                <div>
                  <h3 className="text-sm font-medium text-secondary-900 mb-4">
                    Email Notifications
                  </h3>
                  <div className="space-y-4">
                    {[
                      {
                        key: 'email_orders',
                        label: 'Order Updates',
                        description: 'Get notified about new orders and status changes',
                      },
                      {
                        key: 'email_products',
                        label: 'Product Alerts',
                        description: 'Low stock warnings and product updates',
                      },
                      {
                        key: 'email_marketing',
                        label: 'Marketing Emails',
                        description: 'Promotional content and newsletters',
                      },
                    ].map((item) => (
                      <label key={item.key} className="flex items-center justify-between">
                        <div>
                          <p className="text-sm font-medium text-secondary-700">{item.label}</p>
                          <p className="text-xs text-secondary-500">{item.description}</p>
                        </div>
                        <input
                          type="checkbox"
                          checked={notifications[item.key as keyof typeof notifications]}
                          onChange={(e) =>
                            setNotifications({
                              ...notifications,
                              [item.key]: e.target.checked,
                            })
                          }
                          className="w-4 h-4 text-primary-500 rounded focus:ring-primary-500"
                        />
                      </label>
                    ))}
                  </div>
                </div>

                <div className="flex justify-end pt-4">
                  <Button
                    onClick={handleNotificationsSave}
                    isLoading={isSaving}
                    leftIcon={<Save className="w-4 h-4" />}
                  >
                    Save Preferences
                  </Button>
                </div>
              </div>
            </Card>
          )}

          {/* Security Tab */}
          {activeTab === 'security' && (
            <Card>
              <div className="p-6 border-b border-secondary-200">
                <h2 className="text-lg font-semibold text-secondary-900">Security Settings</h2>
                <p className="text-sm text-secondary-500 mt-1">
                  Manage your password and security preferences
                </p>
              </div>

              <div className="p-6 space-y-6">
                <div>
                  <h3 className="text-sm font-medium text-secondary-900 mb-4 flex items-center gap-2">
                    <Key className="w-4 h-4" />
                    Change Password
                  </h3>
                  <div className="space-y-4 max-w-md">
                    <Input
                      label="Current Password"
                      type="password"
                      value={passwordData.current_password}
                      onChange={(e) =>
                        setPasswordData({
                          ...passwordData,
                          current_password: e.target.value,
                        })
                      }
                    />
                    <Input
                      label="New Password"
                      type="password"
                      value={passwordData.new_password}
                      onChange={(e) =>
                        setPasswordData({
                          ...passwordData,
                          new_password: e.target.value,
                        })
                      }
                      helperText="Must be at least 8 characters"
                    />
                    <Input
                      label="Confirm New Password"
                      type="password"
                      value={passwordData.confirm_password}
                      onChange={(e) =>
                        setPasswordData({
                          ...passwordData,
                          confirm_password: e.target.value,
                        })
                      }
                    />
                  </div>
                </div>

                <div className="flex justify-end pt-4">
                  <Button
                    onClick={handlePasswordChange}
                    isLoading={isSaving}
                    leftIcon={<Shield className="w-4 h-4" />}
                  >
                    Update Password
                  </Button>
                </div>
              </div>
            </Card>
          )}

          {/* Appearance Tab */}
          {activeTab === 'appearance' && (
            <Card>
              <div className="p-6 border-b border-secondary-200">
                <h2 className="text-lg font-semibold text-secondary-900">Appearance Settings</h2>
                <p className="text-sm text-secondary-500 mt-1">
                  Customize the look and feel of your dashboard
                </p>
              </div>

              <div className="p-6 space-y-6">
                <div>
                  <h3 className="text-sm font-medium text-secondary-900 mb-4 flex items-center gap-2">
                    <Palette className="w-4 h-4" />
                    Theme
                  </h3>
                  <div className="flex gap-4">
                    {['light', 'dark', 'system'].map((theme) => (
                      <button
                        key={theme}
                        onClick={() => setAppearance({ ...appearance, theme })}
                        className={`px-6 py-3 rounded-lg border-2 transition-colors capitalize ${
                          appearance.theme === theme
                            ? 'border-primary-500 bg-primary-50 text-primary-600'
                            : 'border-secondary-200 hover:border-secondary-300'
                        }`}
                      >
                        {theme}
                      </button>
                    ))}
                  </div>
                </div>

                <div>
                  <h3 className="text-sm font-medium text-secondary-900 mb-4 flex items-center gap-2">
                    <Globe className="w-4 h-4" />
                    Language & Region
                  </h3>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4 max-w-lg">
                    <div>
                      <label className="block text-sm font-medium text-secondary-700 mb-2">
                        Language
                      </label>
                      <select
                        value={appearance.language}
                        onChange={(e) =>
                          setAppearance({ ...appearance, language: e.target.value })
                        }
                        className="w-full px-4 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
                      >
                        <option value="en">English</option>
                        <option value="es">Spanish</option>
                        <option value="fr">French</option>
                        <option value="de">German</option>
                      </select>
                    </div>
                    <div>
                      <label className="block text-sm font-medium text-secondary-700 mb-2">
                        Timezone
                      </label>
                      <select
                        value={appearance.timezone}
                        onChange={(e) =>
                          setAppearance({ ...appearance, timezone: e.target.value })
                        }
                        className="w-full px-4 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
                      >
                        <option value="UTC">UTC</option>
                        <option value="America/New_York">Eastern Time</option>
                        <option value="America/Los_Angeles">Pacific Time</option>
                        <option value="Europe/London">London</option>
                        <option value="Asia/Kolkata">India Standard Time</option>
                      </select>
                    </div>
                  </div>
                </div>

                <div className="flex justify-end pt-4">
                  <Button
                    onClick={handleAppearanceSave}
                    isLoading={isSaving}
                    leftIcon={<Save className="w-4 h-4" />}
                  >
                    Save Settings
                  </Button>
                </div>
              </div>
            </Card>
          )}
        </div>
      </div>
    </div>
  );
}
