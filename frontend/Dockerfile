# ── Stage 1: build React app ──────────────────────────────────────────────────
FROM node:20-alpine AS builder
WORKDIR /app

COPY package*.json ./
RUN npm install

COPY . .
ENV GENERATE_SOURCEMAP=false
RUN npm run build

# ── Stage 2: production Express server ────────────────────────────────────────
FROM node:20-alpine
WORKDIR /app

COPY package*.json ./
RUN npm install --omit=dev

COPY --from=builder /app/build ./build
COPY server.js ./

EXPOSE 5001
USER node
CMD ["node", "server.js"]
