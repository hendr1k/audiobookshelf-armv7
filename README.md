# audiobookshelf-armv7

Eigen armv7 (32-bit ARM) Docker-build van [Audiobookshelf](https://github.com/advplyr/audiobookshelf), voor de QNAP TS-431P3. Upstream bouwt sinds v2.7.2 geen armv7-images meer; deze pipeline bouwt de laatste ABS-release op Node 22 (laatste armv7-LTS, EOL mei 2027) en compileert libnusqlite3 zelf.

## Gebruik

1. Zet in `.github/workflows/build.yml` de `ABS_VERSION` op de gewenste release.
2. Draai de workflow (Actions tabblad, "Build armv7 image", Run workflow). Duurt ~15-30 min onder QEMU.
3. Trek op de NAS: `docker compose pull && docker compose up -d` (zie `docker-compose.yml`).

## Kanttekeningen

- armv7 wordt upstream niet getest: faalt de build op een nieuwe versie, blijf op de vorige werkende tag.
- Node 22 EOL mei 2027: daarna rest een arm64-apparaat.
