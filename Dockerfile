# Build the Go microservices
FROM --platform=$BUILDPLATFORM golang:1.24.1 AS build
WORKDIR /src
COPY . .

ARG TARGETOS TARGETARCH

RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C api-gateway -o /out/api-gateway .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C file-indexer -o /out/file-indexer .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C thumbnailer -o /out/thumbnailer .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C shares -o /out/shares .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C spaces -o /out/spaces .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C jobs -o /out/jobs .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C file-provider-dir -o /out/file-provider-dir .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C file-provider-smb -o /out/file-provider-smb .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C log-viewer -o /out/log-viewer .

# Build the flutter app for web
FROM --platform=$BUILDPLATFORM ghcr.io/cirruslabs/flutter:3.29.2 AS flutter
WORKDIR /app
RUN flutter precache --web
COPY app/seraph_app/pubspec.yaml app/seraph_app/pubspec.lock ./
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

# Assemble everything
FROM gcr.io/distroless/base-debian12
COPY --from=mime /etc/mime.types /etc/mime.types
COPY --from=build /out/api-gateway /out/file-indexer /out/thumbnailer /out/shares /out/spaces /out/jobs /out/file-provider-dir /out/file-provider-smb /out/log-viewer /bin
COPY --from=flutter /app/build/web /srv/app
COPY --from=webapp /src/dist/seraph-web-app/browser /srv/webapp
CMD ["api-gateway"]
