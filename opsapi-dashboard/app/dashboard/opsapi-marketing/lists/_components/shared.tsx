"use client";

import React from "react";
import { isAxiosError } from "axios";
import { AlertTriangle, CheckCircle2, Info, RotateCw, X } from "lucide-react";

export type MktList = {
  id: number;
  uuid: string;
  name: string;
  list_type?: string;
  channel?: string;
  segment_rule?: unknown;
};

export type Member = {
  contact_uuid: string;
  first_name?: string;
  last_name?: string;
  email?: string;
  phone?: string;
  company?: string;
  source?: string;
  added_at?: string;
};

export const people = (n: number) =>
  `${n.toLocaleString("en-GB")} ${n === 1 ? "person" : "people"}`;

export const CARD =
  "rounded-2xl border border-secondary-200 bg-surface shadow-sm";
export const FIELD =
  "w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2.5 text-base text-secondary-900 " +
  "placeholder:text-secondary-400 focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20 " +
  "disabled:cursor-not-allowed disabled:opacity-60";

/** An error a non-technical person can act on; the server's own message when it gave one. */
export function friendlyError(e: unknown, fallback: string): string {
  if (isAxiosError(e)) {
    if (!e.response) {
      return e.code === "ECONNABORTED"
        ? "This is taking too long. Check your internet connection and try again."
        : "Can’t reach the server. Check your internet connection and try again.";
    }
    const status = e.response.status;
    const data = e.response.data as
      { error?: string; message?: string } | undefined;
    if (status === 401) return "Your session has ended. Please sign in again.";
    if (status === 403)
      return "You don’t have permission to do this. Ask your workspace owner for access.";
    if (status === 413)
      return "That file is too big. Try a smaller file, or save it as CSV.";
    if (status === 429)
      return "Too many tries in a short time. Wait a minute and try again.";
    if (status >= 500)
      return `${fallback}. Something went wrong on our side — please try again in a moment.`;
    if (data?.error) return String(data.error);
    if (data?.message) return String(data.message);
  }
  if (e instanceof Error && e.message) return e.message;
  return fallback;
}

/** File → base64 (without the data: prefix). */
export function readBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () =>
      resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
    reader.onerror = () =>
      reject(
        new Error("Could not read that file. Is it open in another program?"),
      );
    reader.readAsDataURL(file);
  });
}

/** Text → base64 (UTF-8), in chunks so a long paste can't overflow the stack. */
export function textBase64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000)
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

const EMAIL_RE = /[^\s,;<>"'()[\]]+@[^\s,;<>"'()[\]]+\.[a-z]{2,}/gi;

/** The distinct email addresses in some typed or pasted text. */
export function findEmails(text: string): string[] {
  return [...new Set((text.match(EMAIL_RE) || []).map((e) => e.toLowerCase()))];
}

export function fmtDate(iso?: string): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime())
    ? "—"
    : d.toLocaleDateString("en-GB", {
        day: "numeric",
        month: "short",
        year: "numeric",
      });
}

export const SOURCE_LABELS: Record<string, string> = {
  import: "Typed in or uploaded",
  csv: "Pasted in",
  manual: "Added by hand",
  segment: "Smart list rule",
};

/** An inline message inside the card where something happened (errors stay until dismissed). */
export function Alert({
  tone = "error",
  children,
  onRetry,
  onDismiss,
}: {
  tone?: "error" | "success" | "info";
  children: React.ReactNode;
  onRetry?: () => void;
  onDismiss?: () => void;
}) {
  const styles = {
    error: "border-error-500/40 bg-error-500/10 text-error-600",
    success: "border-success-500/40 bg-success-500/10 text-success-600",
    info: "border-primary-500/30 bg-primary-500/5 text-secondary-700 dark:text-secondary-200",
  }[tone];
  const Icon =
    tone === "error" ? AlertTriangle : tone === "success" ? CheckCircle2 : Info;
  return (
    <div
      role={tone === "error" ? "alert" : "status"}
      className={`flex items-start gap-3 rounded-xl border p-3.5 text-base ${styles}`}
    >
      <Icon className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" />
      <div className="min-w-0 flex-1">{children}</div>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="inline-flex shrink-0 items-center gap-1.5 rounded-lg px-2.5 py-1 text-sm font-semibold hover:bg-black/5 dark:hover:bg-white/10"
        >
          <RotateCw className="h-4 w-4" aria-hidden="true" /> Try again
        </button>
      )}
      {onDismiss && (
        <button
          type="button"
          onClick={onDismiss}
          aria-label="Dismiss"
          className="shrink-0 rounded-lg p-1 hover:bg-black/5 dark:hover:bg-white/10"
        >
          <X className="h-4 w-4" />
        </button>
      )}
    </div>
  );
}

/** A grey placeholder bar while something loads. */
export const Skeleton = ({ className = "" }: { className?: string }) => (
  <div
    className={`animate-pulse rounded-lg bg-secondary-200/70 dark:bg-secondary-800 ${className}`}
    aria-hidden="true"
  />
);
