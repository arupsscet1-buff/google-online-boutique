ARG TARGETOS
ARG TARGETARCH

# Stage 1: Compile the application
FROM golang:1.27-rc-trixie AS builder
WORKDIR /src
COPY . ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o frontend .

# Stage 2: Assembly the production runner layer
FROM gcr.io/distroless/static-debian12
WORKDIR /
ENV GOTRACEBACK=single

# 1. Copy the compiled executable
COPY --from=builder /src/frontend .

# 🌟 2. CRITICAL: Copy the required template asset files into the runner
COPY --from=builder /src/templates /templates
COPY --from=builder /src/static /static

USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/frontend"]

