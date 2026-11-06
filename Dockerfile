# syntax=docker/dockerfile:1
# Eigen armv7-build van Audiobookshelf voor de QNAP TS-431P3.
# Upstream ondersteunt armv7 niet meer; dit is een best-effort build.
# Werkt voor ABS-versies met nusqlite3 (gebouwd uit source). Voor oudere
# tags zonder nusqlite3 kan de NUSQLITE3-stap blijven staan (wordt niet geladen).

ARG NODE_IMAGE=node:22-bullseye-slim

FROM --platform=linux/arm/v7 ${NODE_IMAGE} AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 make g++ cmake ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# libnusqlite3: geen armv7-binary van upstream, dus zelf compileren
RUN git clone --depth 1 https://github.com/mikiher/nunicode-sqlite.git /tmp/nusq && \
    cd /tmp/nusq && make && \
    mkdir -p /usr/local/lib/nusqlite3 && \
    cp libnusqlite3.so /usr/local/lib/nusqlite3/

WORKDIR /src
COPY ./abs-src /src
# Client (Nuxt) en server (tsc) zijn pure JS: compileren onder Node 22
RUN cd client && npm ci && npm run generate && cd /src
RUN npm ci --include=dev --ignore-scripts && npm run build:server
RUN npm ci --omit=dev

FROM --platform=linux/arm/v7 ${NODE_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg tini tzdata && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/lib/nusqlite3/libnusqlite3.so /usr/local/lib/nusqlite3/libnusqlite3.so
WORKDIR /app
COPY --from=build /src/client/dist /app/client/dist
COPY --from=build /src/index.js /src/package.json /app/
COPY --from=build /src/server /app/server
COPY --from=build /src/dist-server /app/dist-server
COPY --from=build /src/node_modules /app/node_modules

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
