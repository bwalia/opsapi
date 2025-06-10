# opsapi/node/opsapi-node/Dockerfile

FROM node:22

# Set working directory
WORKDIR /usr/src/app

# Copy package.json and install dependencies
COPY package*.json ./
RUN npm install

# Copy the rest of the app code
COPY . .

# Expose the port your Node app runs on (change if needed)
EXPOSE 3000

# Run the app
CMD ["npm", "start"]
