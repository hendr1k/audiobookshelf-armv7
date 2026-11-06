# syntax=docker/dockerfile:1
# Eigen armv7 (32-bit ARM) build van Audiobookshelf voor de QNAP TS-431P3.
# Upstream ondersteunt armv7 niet meer; dit is een best-effort build.
#
# Bouwstrategie: ALLES wat npm/node-gyp nodig heeft, draait NATIEF op de
# Actions-runner ($BUILDPLATFORM; npm/node-gyp onder QEMU armv7 hangt
# urenlang). De native npm-module sqlite3 wordt daarom GECROSS-compileerd:
# op de amd64-runner met de musl.cc armv7l-toolchain (zelfde aanpak als de
# eigen linux-musl CI van node-sqlite3). Onder QEMU blijft alleen de kleine
# libnusqlite3-compilatie over (git/cmake/make onder QEMU werken prima).
#
# Runtime-basis: Alpine (musl). Debian bookworm gebruikt glibc 2.36; binaries
# daarvan crashen op de oude QNAP-kernel met "ELF load command address/offset
# not page-aligned". musl heeft dat probleem niet. Node 22 is de laatste Node
# met officiele armv7-images.

ARG NODE_IMAGE=node:22-bookworm-slim
ARG NODE_IMAGE_ARM=node:22-alpine

# STAGE 0: client (Nuxt generate) -- native op de runner
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS build-client
WORKDIR /client
COPY abs-src/client /client
RUN npm ci && npm cache clean --force
RUN npm run generate

# STAGE 1: server (tsc) -- native, i.v.m. QEMU-traagheid/SIGILL (zoals upstream)
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS compile-server
WORKDIR /server
COPY abs-src/index.js abs-src/package.json abs-src/package-lock.json abs-src/tsconfig.server.json /server/
COPY abs-src/server /server/server
RUN npm ci --include=dev --ignore-scripts && npm cache clean --force
RUN npm run build:server

# STAGE 2: productie-node_modules -- native; --ignore-scripts zodat er geen
# amd64-native binaries gebouwd worden. Fail-safe: als er toch .node-files
# verschijnen faalt de build expliciet.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS prod-deps
WORKDIR /server
COPY abs-src/index.js abs-src/package.json abs-src/package-lock.json /server/
RUN npm ci --omit=dev --no-audit --no-fund --ignore-scripts && npm cache clean --force
RUN if find node_modules -name "*.node" | grep -q .; then \
      echo "FOUT: native modules gevonden in prod-deps:" && \
      find node_modules -name "*.node" && exit 1; \
    fi

# STAGE 3: sqlite3-binding CROSS-compileren voor armv7/musl -- natief op de
# runner (amd64), met de musl.cc armv7l-cross-toolchain. De binding is pure C
# (N-API) en linkt niet tegen libnode, dus de node-headers (arch-onafhankelijk)
# plus de cross-gcc volstaan. Geen require-check hier: de x64-node kan een
# armv7-binding niet laden; in plaats daarvan controleert readelf of de output
# een ARM-binary is. De toolchain komt van de exacte GitHub-mirror van musl.cc
# (musl-cc/musl.cc): musl.cc zelf is niet altijd bereikbaar vanaf Actions-
# runners; GitHub-releases wel.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS sqlite3-armv7
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 make curl ca-certificates xz-utils && \
    rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --retry 3 \
      https://github.com/musl-cc/musl.cc/releases/download/v0.0.1/armv7l-linux-musleabihf-cross.tgz \
      | tar xz -C /opt
ENV PATH="/opt/armv7l-linux-musleabihf-cross/bin:$PATH" \
    CC=armv7l-linux-musleabihf-gcc \
    CXX=armv7l-linux-musleabihf-g++ \
    AR=armv7l-linux-musleabihf-ar
WORKDIR /server
COPY abs-src/package.json /server/package.json
COPY --from=prod-deps /server/node_modules /server/node_modules
RUN cd node_modules/sqlite3 && \
    npx --yes node-gyp rebuild --release && \
    find /server/node_modules -name "*.node" && \
    armv7l-linux-musleabihf-readelf -h build/Release/node_sqlite3.node | grep -q "Machine:.*ARM" || \
      (echo 'sqlite3 binding is geen ARM-binary' && exit 1)

# STAGE 4: libnusqlite3 compileren voor armv7/musl (geen upstream-binary).
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

# STAGE 5: minimale runtime (alpine/musl)
FROM --platform=linux/arm/v7 ${NODE_IMAGE_ARM}
RUN apk add --no-cache ffmpeg tini tzdata

COPY --from=nusqlite /usr/local/lib/nusqlite3/libnusqlite3.so /usr/local/lib/nusqlite3/libnusqlite3.so

WORKDIR /app
COPY --from=build-client /client/dist /app/client/dist
COPY --from=compile-server /server/dist-server /app/dist-server
COPY --from=sqlite3-armv7 /server/node_modules /app/node_modules
COPY --from=prod-deps /server/package.json /server/index.js /app/

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
