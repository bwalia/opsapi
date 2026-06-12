import type { NextConfig } from "next";

// In dev mode, Next.js 16 only serves dev assets (/_next/*) and the HMR
// WebSocket to requests whose Origin host is allow-listed. When the dashboard
// is reached through a reverse proxy / tunnel on a public host (e.g.
// dev-opsapi-remote.fictionally.org) rather than localhost, the page hangs and
// the webpack-hmr WebSocket is refused unless that host is listed here.
// We derive the hosts from the same env the deployment already sets
// (FRONTEND_URL / NEXT_PUBLIC_API_URL) plus an optional ALLOWED_DEV_ORIGINS
// override, so this needs no per-domain hardcoding.
function hostOf(url?: string): string | null {
  if (!url) return null;
  try {
    return new URL(url).host;
  } catch {
    return url.replace(/^https?:\/\//, "").replace(/\/.*$/, "") || null;
  }
}

const allowedDevOrigins = Array.from(
  new Set(
    [
      "localhost",
      "127.0.0.1",
      hostOf(process.env.FRONTEND_URL),
      hostOf(process.env.NEXT_PUBLIC_API_URL),
      ...(process.env.ALLOWED_DEV_ORIGINS || "")
        .split(",")
        .map((s) => s.trim())
        .map((s) => hostOf(s) || s),
    ].filter(Boolean) as string[]
  )
);

const nextConfig: NextConfig = {
  // Allow dev-server/HMR access from these hosts (see note above).
  allowedDevOrigins,

  // Poll the filesystem for changes. Required when the source is bind-mounted
  // into the container over Colima/virtiofs: native inotify events don't cross
  // that boundary, so Turbopack's watcher never sees host edits and hot reload
  // silently stops working. Polling makes edits reliably trigger a recompile.
  // (Only active in dev; ignored for production builds.)
  watchOptions: {
    pollIntervalMs: 1000,
  },

  // Enable standalone output for Docker deployment
  output: "standalone",

  // Disable image optimization for simpler Docker setup (can be enabled with proper loader)
  images: {
    unoptimized: true,
  },

  // Environment variables that will be available at runtime
  env: {
    NEXT_PUBLIC_API_URL: process.env.NEXT_PUBLIC_API_URL || "http://127.0.0.1:4010",
  },

  // Experimental features for better performance
  experimental: {
    // Reduce memory usage
    webpackMemoryOptimizations: true,
  },

  // Reduce aggressive prefetching which causes 503 errors under load
  // This prevents the browser from sending too many concurrent requests
  onDemandEntries: {
    // Keep pages in memory for longer (in ms)
    maxInactiveAge: 60 * 1000,
    // Number of pages to keep in memory
    pagesBufferLength: 5,
  },

  // Compress responses
  compress: true,

  // Remove powered by header for security
  poweredByHeader: false,

  // Generate ETags for caching
  generateEtags: true,

  // Optimize production builds
  productionBrowserSourceMaps: false, // Disable source maps in production for faster load
};

export default nextConfig;
