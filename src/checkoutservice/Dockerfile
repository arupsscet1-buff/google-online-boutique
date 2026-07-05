FROM golang:1.26.4-alpine3.23 AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 go build -o /checkoutservice .

FROM gcr.io/distroless/static:debian12
WORKDIR /src
COPY --from=builder /checkoutservice /src/checkoutservice
ENV GOTRACEBACK=single

EXPOSE 5050
ENTRYPOINT ["/src/checkoutservice"]
