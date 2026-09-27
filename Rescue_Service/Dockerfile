FROM node:24-alpine

ENV NODE_ENV=production
WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

USER node
CMD ["node", "rescue_service.js"]
