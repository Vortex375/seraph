# Build the Go microservices
FROM --platform=$BUILDPLATFORM golang:1.26.5 AS build
WORKDIR /src
COPY . .

ARG TARGETOS TARGETARCH

# One go invocation builds every service in parallel; the go-build cache mount
# (shared with audio-metadata-build) keeps unchanged packages compiled.
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /out/ \
    ./api-gateway ./file-indexer ./thumbnailer ./shares ./spaces ./gallery ./jobs \
    ./file-provider-dir ./file-provider-smb ./log-viewer

# Build audio-metadata, the only cgo service: TagLib from Debian, built on the
# target platform so the binary matches the runtime image's glibc.
FROM golang:1.26.5 AS audio-metadata-build
RUN apt-get update && apt-get install -y --no-install-recommends libtag-dev zlib1g-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build CGO_ENABLED=1 go build -C audio-metadata -o /out/audio-metadata .
# TagLib and zlib for the final image, staged under the multiarch directory
# (x86_64-linux-gnu, aarch64-linux-gnu) they are loaded from.
RUN set -e; multiarch=$(gcc -print-multiarch); mkdir -p /out/lib/$multiarch; \
    cp -a /usr/lib/$multiarch/libtag.so.2* /usr/lib/$multiarch/libz.so.1* /out/lib/$multiarch/

# Build the flutter app for web
FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS flutter
RUN apt-get update && apt-get install -y --no-install-recommends git curl unzip xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
# ponytail: version pinned once here; no official arm64 tarball exists, so a
# shallow clone of the release tag + arch-native precache is the only
# multi-platform path. Swap back to the x64-only tarball if single-platform.
RUN git clone --depth 1 --branch 3.47.5 https://github.com/flutter/flutter.git /opt/flutter
ENV PATH=/opt/flutter/bin:$PATH
RUN git config --global --add safe.directory /opt/flutter && flutter precache --web --no-android --no-universal
WORKDIR /app
RUN flutter precache --web
# Copy the pubspec and the path-dependency plugin it references before pub get,
# so the path dep (plugins/seraph_local_media) resolves. Only pubspec.yaml/lock
# and the plugin's own pubspec are needed for dependency resolution; the rest
# of the app (and the plugin's sources) are copied below before the build.
COPY app/seraph_app/pubspec.yaml app/seraph_app/pubspec.lock ./
COPY app/seraph_app/plugins ./plugins
RUN --mount=type=cache,target=/root/.pub-cache flutter pub get
COPY app/seraph_app .
RUN --mount=type=cache,target=/root/.pub-cache flutter build web --release --base-href=/app/

# Build the webapp
FROM --platform=$BUILDPLATFORM node:20.18.0 AS webapp
WORKDIR /src
COPY webapp/seraph-web-app/package.json webapp/seraph-web-app/package-lock.json .
RUN npm install
COPY webapp/seraph-web-app .
RUN npm run build

# WebDAV requires mime information
FROM --platform=$BUILDPLATFORM alpine AS mime
RUN apk add mailcap

# Assemble everything. Debian 13 runtime (glibc 2.41) for the Debian 13
# audio-metadata build, with cc for its libstdc++ and TagLib's libraries.
FROM gcr.io/distroless/cc-debian13
COPY --from=mime /etc/mime.types /etc/mime.types
COPY --from=build /out/api-gateway /out/file-indexer /out/thumbnailer /out/shares /out/spaces /out/gallery /out/jobs /out/file-provider-dir /out/file-provider-smb /out/log-viewer /bin
COPY --from=audio-metadata-build /out/audio-metadata /bin/audio-metadata
COPY --from=audio-metadata-build /out/lib/ /usr/lib/
COPY --from=flutter /app/build/web /srv/app
COPY --from=webapp /src/dist/seraph-web-app/browser /srv/webapp
CMD ["api-gateway"]
