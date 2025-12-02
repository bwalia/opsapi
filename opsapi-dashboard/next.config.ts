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
};

export default nextConfig;
