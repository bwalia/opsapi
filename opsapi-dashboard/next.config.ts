import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Enable standalone output for Docker deployment
  output: "standalone",

  // Disable image optimization for simpler Docker setup (can be enabled with proper loader)
  images: {
    unoptimized: true,
  },

  // Environment variables that will be available at runtime
  env: {
    NEXT_PUBLIC_API_URL: process.env.NEXT_PUBLIC_API_URL || "http://localhost:4010",
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
