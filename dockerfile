FROM node:24-alpine AS dependencies

WORKDIR /app

RUN apk add --no-cache python3 make g++

COPY package.json package-lock.json ./

RUN npm ci --omit=dev

FROM node:24-alpine AS production

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

COPY --from=dependencies --chown=node:node /app/node_modules ./node_modules

COPY --chown=node:node . .

USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:3000/health').then(response => process.exit(response.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "index.js"]