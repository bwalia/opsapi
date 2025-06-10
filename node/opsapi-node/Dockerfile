# opsapi/node/opsapi-node/Dockerfile

FROM node:22

# Set the working directory in the container
WORKDIR /app
# Copy package.json and package-lock.json to the working directory
COPY node/opsapi-node/package*.json /app
# Install Node.js dependencies
RUN npm install
# Copy the rest of the application code to the working directory
COPY node/opsapi-node/. /app
# Expose the application port
EXPOSE 3000
# Start the Node.js application
CMD ["npm", "start"]