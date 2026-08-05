'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowLeft, Plus, Trash2, Save, User } from 'lucide-react';
import { Button } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  academyService,
  type InstructorProfile,
  type Achievement,
  type Education,
} from '@/services/academy.service';
import toast from 'react-hot-toast';

const input =
  'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500';
const label = 'block text-sm font-medium text-secondary-700 mb-1';
const card = 'bg-surface rounded-xl border border-secondary-200 p-5 space-y-4';

function InstructorProfileEditor(): React.ReactElement {
  const router = useRouter();
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState<InstructorProfile>({});
  const [skillsText, setSkillsText] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const p = await academyService.getInstructorProfile();
      setForm({
        headline: p.headline ?? '',
        bio: p.bio ?? '',
        avatar_url: p.avatar_url ?? '',
        location: p.location ?? '',
        website: p.website ?? '',
        socials: p.socials ?? {},
        achievements: Array.isArray(p.achievements) ? p.achievements : [],
        education: Array.isArray(p.education) ? p.education : [],
        skills: Array.isArray(p.skills) ? p.skills : [],
      });
      setSkillsText((Array.isArray(p.skills) ? p.skills : []).join(', '));
    } catch (err) {
      console.error('Load profile failed:', err);
      toast.error('Could not load your profile');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const set = <K extends keyof InstructorProfile>(key: K, value: InstructorProfile[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }));

  const setSocial = (key: string, value: string) =>
    setForm((prev) => ({ ...prev, socials: { ...(prev.socials ?? {}), [key]: value } }));

  // Achievements ------------------------------------------------------------
  const addAchievement = () =>
    set('achievements', [...(form.achievements ?? []), { title: '', issuer: '', year: '' }]);
  const updateAchievement = (i: number, patch: Partial<Achievement>) =>
    set(
      'achievements',
      (form.achievements ?? []).map((a, idx) => (idx === i ? { ...a, ...patch } : a)),
    );
  const removeAchievement = (i: number) =>
    set('achievements', (form.achievements ?? []).filter((_, idx) => idx !== i));

  // Education ---------------------------------------------------------------
  const addEducation = () =>
    set('education', [...(form.education ?? []), { degree: '', institution: '', year: '' }]);
  const updateEducation = (i: number, patch: Partial<Education>) =>
    set(
      'education',
      (form.education ?? []).map((e, idx) => (idx === i ? { ...e, ...patch } : e)),
    );
  const removeEducation = (i: number) =>
    set('education', (form.education ?? []).filter((_, idx) => idx !== i));

  const save = async () => {
    setSaving(true);
    try {
      const skills = skillsText
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean);
      const payload: InstructorProfile = {
        ...form,
        skills,
        achievements: (form.achievements ?? []).filter((a) => a.title.trim()),
        education: (form.education ?? []).filter((e) => e.degree.trim()),
      };
      await academyService.saveInstructorProfile(payload);
      toast.success('Profile saved');
    } catch (err) {
      console.error('Save profile failed:', err);
      toast.error('Failed to save profile');
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return <div className="p-6"><div className="h-64 animate-pulse rounded-xl bg-secondary-100" /></div>;
  }

  return (
    <div className="space-y-6 max-w-3xl">
      <button
        onClick={() => router.push('/dashboard/academy')}
        className="inline-flex items-center gap-1.5 text-sm text-secondary-500 hover:text-secondary-900"
      >
        <ArrowLeft size={16} /> Back to courses
      </button>

      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-11 h-11 rounded-xl bg-primary-50 text-primary-600 flex items-center justify-center">
            <User size={22} />
          </div>
          <div>
            <h1 className="text-xl font-bold text-secondary-900">Your instructor profile</h1>
            <p className="text-sm text-secondary-500">Shown to learners on your public profile page.</p>
          </div>
        </div>
        <Button leftIcon={<Save size={16} />} isLoading={saving} onClick={() => void save()}>
          Save profile
        </Button>
      </div>

      {/* Basics */}
      <div className={card}>
        <h2 className="text-sm font-semibold text-secondary-800">Basics</h2>
        <div>
          <label className={label}>Headline</label>
          <input className={input} value={form.headline ?? ''} onChange={(e) => set('headline', e.target.value)} placeholder="e.g. Senior Software Engineer & Educator" />
        </div>
        <div>
          <label className={label}>Bio</label>
          <textarea className={input} rows={5} value={form.bio ?? ''} onChange={(e) => set('bio', e.target.value)} placeholder="Tell learners about your background and what you teach…" />
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className={label}>Avatar URL</label>
            <input className={input} value={form.avatar_url ?? ''} onChange={(e) => set('avatar_url', e.target.value)} placeholder="https://…/photo.jpg" />
          </div>
          <div>
            <label className={label}>Location</label>
            <input className={input} value={form.location ?? ''} onChange={(e) => set('location', e.target.value)} placeholder="e.g. London, UK" />
          </div>
          <div>
            <label className={label}>Website</label>
            <input className={input} value={form.website ?? ''} onChange={(e) => set('website', e.target.value)} placeholder="https://your-site.com" />
          </div>
        </div>
      </div>

      {/* Socials */}
      <div className={card}>
        <h2 className="text-sm font-semibold text-secondary-800">Social links</h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          {(['twitter', 'linkedin', 'github', 'youtube'] as const).map((k) => (
            <div key={k}>
              <label className={`${label} capitalize`}>{k}</label>
              <input
                className={input}
                value={form.socials?.[k] ?? ''}
                onChange={(e) => setSocial(k, e.target.value)}
                placeholder={`https://${k}.com/…`}
              />
            </div>
          ))}
        </div>
      </div>

      {/* Skills */}
      <div className={card}>
        <h2 className="text-sm font-semibold text-secondary-800">Skills</h2>
        <input
          className={input}
          value={skillsText}
          onChange={(e) => setSkillsText(e.target.value)}
          placeholder="Comma separated, e.g. JavaScript, React, Node.js, System Design"
        />
        <p className="text-xs text-secondary-400">Separate skills with commas.</p>
      </div>

      {/* Achievements */}
      <div className={card}>
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-semibold text-secondary-800">Achievements &amp; certifications</h2>
          <Button size="sm" variant="outline" leftIcon={<Plus size={14} />} onClick={addAchievement}>Add</Button>
        </div>
        {(form.achievements ?? []).length === 0 ? (
          <p className="text-sm text-secondary-400">No achievements yet.</p>
        ) : (
          (form.achievements ?? []).map((a, i) => (
            <div key={i} className="grid grid-cols-1 sm:grid-cols-[1fr_1fr_100px_auto] gap-2 items-start">
              <input className={input} value={a.title} onChange={(e) => updateAchievement(i, { title: e.target.value })} placeholder="Title (e.g. AWS Certified)" />
              <input className={input} value={a.issuer ?? ''} onChange={(e) => updateAchievement(i, { issuer: e.target.value })} placeholder="Issuer" />
              <input className={input} value={a.year ?? ''} onChange={(e) => updateAchievement(i, { year: e.target.value })} placeholder="Year" />
              <button onClick={() => removeAchievement(i)} className="p-2 rounded-md text-secondary-400 hover:bg-error-50 hover:text-error-600" title="Remove"><Trash2 size={16} /></button>
            </div>
          ))
        )}
      </div>

      {/* Education */}
      <div className={card}>
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-semibold text-secondary-800">Education &amp; degrees</h2>
          <Button size="sm" variant="outline" leftIcon={<Plus size={14} />} onClick={addEducation}>Add</Button>
        </div>
        {(form.education ?? []).length === 0 ? (
          <p className="text-sm text-secondary-400">No education entries yet.</p>
        ) : (
          (form.education ?? []).map((e, i) => (
            <div key={i} className="grid grid-cols-1 sm:grid-cols-[1fr_1fr_100px_auto] gap-2 items-start">
              <input className={input} value={e.degree} onChange={(ev) => updateEducation(i, { degree: ev.target.value })} placeholder="Degree (e.g. BSc Computer Science)" />
              <input className={input} value={e.institution ?? ''} onChange={(ev) => updateEducation(i, { institution: ev.target.value })} placeholder="Institution" />
              <input className={input} value={e.year ?? ''} onChange={(ev) => updateEducation(i, { year: ev.target.value })} placeholder="Year" />
              <button onClick={() => removeEducation(i)} className="p-2 rounded-md text-secondary-400 hover:bg-error-50 hover:text-error-600" title="Remove"><Trash2 size={16} /></button>
            </div>
          ))
        )}
      </div>

      <div className="flex justify-end">
        <Button leftIcon={<Save size={16} />} isLoading={saving} onClick={() => void save()}>Save profile</Button>
      </div>
    </div>
  );
}

export default function InstructorProfilePage(): React.ReactElement {
  return (
    <ProtectedPage module="courses" action="read" title="Instructor profile">
      <InstructorProfileEditor />
    </ProtectedPage>
  );
}
