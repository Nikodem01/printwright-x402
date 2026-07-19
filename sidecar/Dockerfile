FROM node:20-bookworm-slim

ENV NODE_ENV=production
WORKDIR /sidecar

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY app.mjs hedera.mjs instrument.mjs server.mjs ./

USER node
EXPOSE 4021
CMD ["node", "--import", "./instrument.mjs", "server.mjs"]
