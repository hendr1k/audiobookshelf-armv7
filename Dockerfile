# syntax=docker/dockerfile:1
# Eigen armv7 (32-bit ARM) build van Audiobookshelf voor de QNAP TS-431P3.
# Upstream ondersteunt armv7 niet meer; dit is een best-effort build.
#
# Bouwstrategie: alles wat pure JS oplevert (client + server) wordt NATIEF
# op de Actions-runner gebouwd (snel, geen QEMU). Alleen de prod-dependencies
# en libnusqlite3 worden voor armv7 gebouwd.

ARG NODE_IMAGE=node:22-bullseye-slim

# STAGE 0: client (Nuxt generate) -- native, output is arch-onafhankelijk
FROM ${NODE_IMAGE} AS build-client
WORKDIR /client
COPY abs-src/client /client
RUN npm ci && npm cache clean --force
RUN npm run generate

# STAGE 1: server (tsc) -- native, i.v.m. QEMU-traagheid/SIGILL (zoals upstream)
FROM ${NODE_IMAGE} AS compile-server
WORKDIR /server
COPY abs-src/index.js abs-src/package.json abs-src/package-lock.json abs-src/tsconfig.server.json /server/
COPY abs-src/server /server/server
RUN npm ci --include=dev --ignore-scripts && npm cache clean --force
RUN npm run build:server

# STAGE 2: productie-node_modules voor armv7 (draait onder QEMU, klein en snel)
FROM --platform=linux/arm/v7 ${NODE_IMAGE} AS build-server
RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 make g++ ca-certificates && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /server
COPY --from=compile-server /server /server
RUN npm ci --omit=dev && npm cache clean --force

# STAGE 3: libnusqlite3 compileren voor armv7 (geen upstream-binary)
FROM --platform=linux/arm/v7 ${NODE_IMAGE} AS nusqlite
RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 make g++ ca-certificates && \
    rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/mikiher/nunicode-sqlite.git /tmp/nusq && \
    cd /tmp/nusq && make && \
    mkdir -p /usr/local/lib/nusqlite3 && \
    cp libnusqlite3.so /usr/local/lib/nusqlite3/

# STAGE 4: minimale runtime
FROM --platform=linux/arm/v7 ${NODE_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg tini tzdata && \
    rm -rf /var/lib/apt/lists/*

COPY --from=nusqlite /usr/local/lib/nusqlite3/libnusqlite3.so /usr/local/lib/nusqlite3/libnusqlite3.so

WORKDIR /app
COPY --from=build-client /client/dist /app/client/dist
COPY --from=build-server /server /app

ENV PORT=80 \
    NODE_ENV=production \
    CONFIG_PATH=/config \
    METADATA_PATH=/metadata \
    SOURCE=docker \
    NUSQLITE3_DIR=/usr/local/lib/nusqlite3 \
    NUSQLITE3_PATH=/usr/local/lib/nusqlite3/libnusqlite3.so

EXPOSE 80
ENTRYPOINT ["tini", "--"]
CMD ["node", "dist-server/index.js"]
