# syntax=docker/dockerfile:1
# Eigen armv7 (32-bit ARM) build van Audiobookshelf voor de QNAP TS-431P3.
# Upstream ondersteunt armv7 niet meer; dit is een best-effort build.
#
# Bouwstrategie: alles wat pure JS oplevert (client + server) wordt NATIEF
# op de Actions-runner gebouwd (snel, geen QEMU). Alleen de prod-dependencies
# en libnusqlite3 worden voor armv7 gebouwd.
#
# Runtime-basis: Alpine (musl). Debian bookworm gebruikt glibc 2.36; binaries
# daarvan crashen op de oude QNAP-kernel met "ELF load command address/offset
# not page-aligned". musl heeft dat probleem niet. Node 22 is de laatste Node
# met officiele armv7-images.

ARG NODE_IMAGE=node:22-bookworm-slim
ARG NODE_IMAGE_ARM=node:22-alpine

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

# STAGE 2: productie-node_modules voor armv7 (musl/alpine)
FROM --platform=linux/arm/v7 ${NODE_IMAGE_ARM} AS build-server
RUN apk add --no-cache git python3 make g++
WORKDIR /server
COPY --from=compile-server /server /server
RUN npm ci --omit=dev && npm cache clean --force

# STAGE 3: libnusqlite3 compileren voor armv7/musl (geen upstream-binary).
# Procedure volgens de eigen build-workflow van mikiher/nunicode-sqlite:
# nunicode-broncode van Bitbucket (tag 1.11) + aangepaste CMakeLists.txt uit
# mikiher/nunicode-sqlite + sqlite3-headers in de source-tree, dan cmake+make.
FROM --platform=linux/arm/v7 ${NODE_IMAGE_ARM} AS nusqlite
RUN apk add --no-cache git cmake make g++ sqlite-dev
RUN git clone https://bitbucket.org/alekseyt/nunicode.git /tmp/nu && \
    cd /tmp/nu && git checkout 1.11 && \
    git clone --depth 1 https://github.com/mikiher/nunicode-sqlite.git /tmp/nusq && \
    cp /tmp/nusq/CMakeLists.txt /tmp/nu/ && \
    mkdir -p /tmp/nu/include && cp /usr/include/sqlite3*.h /tmp/nu/include/ && \
    mkdir -p /tmp/nu/staging/build && cd /tmp/nu/staging/build && \
    cmake -DCMAKE_BUILD_TYPE=Release ../.. && \
    make -j2 nusqlite3 && \
    mkdir -p /usr/local/lib/nusqlite3 && \
    cp /tmp/nu/staging/build/sqlite3/libnusqlite3.so /usr/local/lib/nusqlite3/

# STAGE 4: minimale runtime (alpine/musl)
FROM --platform=linux/arm/v7 ${NODE_IMAGE_ARM}
RUN apk add --no-cache ffmpeg tini tzdata

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
