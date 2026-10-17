'use client';

/**
 * Kanban project AI settings: target repo, skills git URLs, MD refs, vault credentials, allowed executors.
 */
import React, { useEffect, useState } from 'react';
import { Bot, Plus } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Select, Textarea } from '@/components/ui';
import {
  aiRunner, aiError, type MdRef, type ProjectSettings, type SkillGitUrl,
} from '@/services/ai-runner.service';
import { useAiRunnerOn } from './ui';

const EXECUTORS = [
  { value: 'machine', label: 'Machine runner' },
  { value: 'builtin', label: 'Built-in' },
  { value: 'jobshout', label: 'JobShout' },
  { value: 'provider', label: 'Any workspace AI provider' },
];

export default function ProjectAiSettings({ projectUuid }: { projectUuid: string }) {
  const on = useAiRunnerOn();
  const [s, setS] = useState<ProjectSettings | null>(null);
  const [vaultToken, setVaultToken] = useState('');
  const [saving, setSaving] = useState(false);
  const [skillsText, setSkillsText] = useState('');
  const [mdText, setMdText] = useState('');

  useEffect(() => {
    if (!on) return;
    aiRunner.getProjectSettings(projectUuid).then((ps) => {
      setS({ ...ps, default_repo_paths: ps.default_repo_paths || {} });
      setSkillsText((ps.skills_git_urls || []).map((x) =>
        [x.url, x.ref, x.path, x.label].filter(Boolean).join(' | ')).join('\n'));
      setMdText((ps.md_refs || []).map((m) =>
        [m.path || m.url, m.label].filter(Boolean).join(' | ')).join('\n'));
    }, () => setS(null));
  }, [on, projectUuid]);

  if (!on) return null;
  if (!s) {
    return <p className="text-sm text-secondary-500 py-6">Loading AI project settings…</p>;
  }

  function parseSkills(text: string): SkillGitUrl[] {
    return text.split('\n').map((line) => line.trim()).filter(Boolean).map((line) => {
      const [url, ref, path, label] = line.split('|').map((p) => p.trim());
      return { url, ref: ref || undefined, path: path || undefined, label: label || undefined };
    });
  }
  function parseMd(text: string): MdRef[] {
    return text.split('\n').map((line) => line.trim()).filter(Boolean).map((line) => {
      const [loc, label] = line.split('|').map((p) => p.trim());
      if (loc.startsWith('http')) return { url: loc, label: label || undefined };
      return { path: loc, label: label || undefined };
    });
  }

  async function save() {
    const cur = s;
    if (!cur) return;
    setSaving(true);
    try {
      const next = await aiRunner.saveProjectSettings(projectUuid, {
        project_uuid: cur.project_uuid,
        default_repo_paths: cur.default_repo_paths || {},
        output_mode: cur.output_mode,
        base_branch: cur.base_branch,
        target_repo_url: cur.target_repo_url,
        vault_url: cur.vault_url,
        vault_secret_path: cur.vault_secret_path,
        vault_mount_path: cur.vault_mount_path,
        allowed_executors: cur.allowed_executors || [],
        executor_locked: cur.executor_locked,
        default_executor: cur.default_executor,
        skills_git_urls: parseSkills(skillsText),
        md_refs: parseMd(mdText),
        vault_token: vaultToken || undefined,
      });
      setS({ ...next, default_repo_paths: next.default_repo_paths || {} });
      setVaultToken('');
      toast.success('AI project settings saved');
    } catch (e) {
      toast.error(aiError(e).message);
    } finally {
      setSaving(false);
    }
  }

  function toggleExec(v: string) {
    const cur = s;
    if (!cur) return;
    const set = new Set(cur.allowed_executors || []);
    if (set.has(v)) set.delete(v); else set.add(v);
    setS({ ...cur, default_repo_paths: cur.default_repo_paths || {}, allowed_executors: [...set] });
  }

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-secondary-900 flex items-center gap-2">
          <Bot size={18} /> AI &amp; ways of working
        </h2>
        <p className="text-sm text-secondary-500 mt-1">
          Target repository for PRs, skills packs, reference MD, vault credentials, and which executors developers may use.
        </p>
      </div>

      <Input label="Target repository URL" value={s.target_repo_url || ''}
        onChange={(e) => setS({ ...s, target_repo_url: e.target.value })}
        placeholder="https://github.com/org/app.git" spellCheck={false}
        helperText="PRs open here (not the OpsAPI repo). Inherited by every task in this project." />

      <Input label="Base branch" value={s.base_branch || ''}
        onChange={(e) => setS({ ...s, base_branch: e.target.value })}
        placeholder="main" spellCheck={false} />

      <Textarea label="Skills git repositories (one per line)" rows={4} value={skillsText}
        onChange={(e) => setSkillsText(e.target.value)}
        className="font-mono text-xs"
        helperText="url | optional-ref | optional-path | optional-label — cloned/read before the agent starts."
        placeholder="https://github.com/org/skills.git | main | . | engineering-standards" />

      <Textarea label="Reference MD files (one per line)" rows={3} value={mdText}
        onChange={(e) => setMdText(e.target.value)}
        className="font-mono text-xs"
        helperText="path-in-repo or https URL | optional-label"
        placeholder="docs/WAYS_OF_WORKING.md | Ways of working" />

      <div className="grid gap-4 sm:grid-cols-2">
        <Input label="Vault URL (WSL / HashiCorp)" value={s.vault_url || ''}
          onChange={(e) => setS({ ...s, vault_url: e.target.value })}
          placeholder="https://vault.example.com" spellCheck={false} />
        <Input label="Vault secret path" value={s.vault_secret_path || ''}
          onChange={(e) => setS({ ...s, vault_secret_path: e.target.value })}
          placeholder="opsapi/github/app-repo" spellCheck={false}
          helperText="KV v2 path whose data includes github_token or token." />
        <Input label="Vault mount" value={s.vault_mount_path || 'secret'}
          onChange={(e) => setS({ ...s, vault_mount_path: e.target.value })} spellCheck={false} />
        <Input label={s.vault_token_set ? 'Vault token (leave blank to keep)' : 'Vault token'}
          type="password" value={vaultToken} onChange={(e) => setVaultToken(e.target.value)}
          autoComplete="new-password"
          helperText="Stored sealed in OpsAPI secrets. Used only to fetch the GitHub token at PR time." />
      </div>

      <div>
        <p className="text-sm font-medium text-secondary-700 mb-2">Allowed executors</p>
        <div className="flex flex-wrap gap-3">
          {EXECUTORS.map((e) => (
            <label key={e.value} className="inline-flex items-center gap-2 text-sm text-secondary-700">
              <input type="checkbox" checked={(s.allowed_executors || []).includes(e.value)}
                onChange={() => toggleExec(e.value)} />
              {e.label}
            </label>
          ))}
        </div>
        <p className="text-xs text-secondary-500 mt-1">Empty = all executors allowed. Developers cannot pick outside this list.</p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <Select label="Default executor" value={s.default_executor || 'machine'}
          onChange={(e) => setS({ ...s, default_executor: e.target.value })}>
          {EXECUTORS.map((e) => <option key={e.value} value={e.value}>{e.label}</option>)}
        </Select>
        <label className="flex items-center gap-2 text-sm text-secondary-700 mt-6">
          <input type="checkbox" checked={!!s.executor_locked}
            onChange={(e) => setS({ ...s, executor_locked: e.target.checked })} />
          Lock executor (only managers may change it at start)
        </label>
      </div>

      <div className="flex justify-end gap-2">
        <Button onClick={save} isLoading={saving} leftIcon={<Plus className="h-4 w-4" aria-hidden />}>
          Save AI settings
        </Button>
      </div>
    </div>
  );
}
