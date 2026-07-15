FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
ENV SIDECAR_HOST=0.0.0.0
EXPOSE 4021
CMD ["node", "server.mjs"]
