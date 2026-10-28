# Production image for the MusicSynq server.
#   docker build -t musicsynq-server .
#   docker run -p 8080:8080 -v musicsynq-data:/data musicsynq-server
FROM node:22-bookworm-slim

WORKDIR /app
ENV NODE_ENV=production

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY src ./src

# SQLite lives on a volume so accounts and friends survive redeploys.
RUN mkdir -p /data && chown node:node /data
ENV DATABASE_PATH=/data/musicsynq.db \
    HOST=0.0.0.0 \
    PORT=8080
VOLUME /data
EXPOSE 8080

USER node
CMD ["node", "src/index.js"]
