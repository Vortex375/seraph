# Build the Go microservices
FROM --platform=$BUILDPLATFORM golang:1.23.2 AS build
WORKDIR /src
COPY . .

ARG TARGETOS TARGETARCH

RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C api-gateway -o /out/api-gateway .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C file-indexer -o /out/file-indexer .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C thumbnailer -o /out/thumbnailer .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C shares -o /out/shares-provider .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C file-provider-dir -o /out/file-provider-dir .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C file-provider-smb -o /out/file-provider-smb .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C log-viewer -o /out/log-viewer .

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
COPY --from=build /out/api-gateway /out/file-indexer /out/thumbnailer /out/shares-provider /out/file-provider-dir /out/file-provider-smb /out/log-viewer /bin
COPY --from=webapp /src/dist/seraph-web-app/browser /srv/webapp
CMD ["api-gateway"]
