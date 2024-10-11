FROM --platform=$BUILDPLATFORM golang:1.22.5 AS build
WORKDIR /src
COPY . .

ARG TARGETOS TARGETARCH

RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C api-gateway -o /out/api-gateway .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C file-indexer -o /out/file-indexer .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C file-provider-dir -o /out/file-provider-dir .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C file-provider-smb -o /out/file-provider-smb .
RUN --mount=type=cache,target=/go/pkg/mod GOOS=$TARGETOS GOARCH=$TARGETARCH go build -C log-viewer -o /out/log-viewer .

FROM gcr.io/distroless/base-debian12
COPY --from=build /out/api-gateway /out/file-indexer /out/file-provider-dir /out/file-provider-smb /out/log-viewer /bin
CMD ["api-gateway"]
