ARG TARGETOS
ARG TARGETARCH

FROM golang:1.27-rc-trixie AS builder
WORKDIR /src
COPY . ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o frontend .

FROM gcr.io/distroless/static-debian12
WORKDIR /
ENV GOTRACEBACK=single
COPY --from=builder /src/frontend .
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/frontend"]
