# Build stage
FROM node:20-alpine AS builder

WORKDIR /app

# Build argument for API URL (passed from docker-compose)
ARG NEXT_PUBLIC_API_URL=http://localhost:4010
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci

# Copy source code
COPY . .

# Build the application
RUN npm run build

# Production stage
FROM node:20-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production

# Install PM2 globally for process management, clustering, and auto-restart
RUN npm install -g pm2

# Create non-root user
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

# Copy built assets from builder
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# Copy PM2 ecosystem config
COPY --chown=nextjs:nodejs ecosystem.config.js ./

USER nextjs

EXPOSE 8039

ENV PORT=8039
ENV HOSTNAME="0.0.0.0"

# Use PM2 to run with clustering for better concurrency and auto-restart on crash
CMD ["pm2-runtime", "ecosystem.config.js"]
