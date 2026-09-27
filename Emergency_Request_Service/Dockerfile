FROM node:24-alpine

ENV NODE_ENV=production
WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

EXPOSE 3001
USER node
CMD ["node", "emergency_service.js"]
