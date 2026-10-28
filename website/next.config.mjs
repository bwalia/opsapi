/** @type {import('next').NextConfig} */
// Static export for GitHub Pages. No basePath: the wslproxy edge serves
// opsapi.org/* from bwalia.github.io/opsapi/*, so root-relative links work there.
const nextConfig = {
    output: 'export',
    trailingSlash: true,
    images: { unoptimized: true },
    reactStrictMode: true,
};

export default nextConfig;
