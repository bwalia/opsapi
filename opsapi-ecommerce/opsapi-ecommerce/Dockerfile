FROM node:22-alpine

RUN mkdir -p /kisaan

WORKDIR /kisaan

COPY package*.json ./
RUN npm ci --only=production

COPY opsapi-ecommerce/opsapi-ecommerce/ /kisaan/

RUN npm run build

EXPOSE 3000

CMD ["npm", "run", "dev"]