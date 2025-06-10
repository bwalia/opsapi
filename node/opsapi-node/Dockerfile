# opsapi/node/opsapi-node/Dockerfile

FROM node:22

ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

# Install pnpm globally
RUN npm install -g pnpm
# Copy package.json and package-lock.json to the working directory
# Set the working directory in the container
WORKDIR /app

# Copy the rest of the application code to the working directory
COPY node/opsapi-node/package*.json /app/
COPY node/opsapi-node/. /app/

# Install Node.js dependencies
RUN pnpm install

# Expose the application port
EXPOSE 3000

RUN corepack enable
# Start the Node.js application
CMD ["pnpm", "start"]