FROM golang:1.27-rc-alpine3.23 AS builder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .

RUN GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 go build -o /productcatalogservice .

FROM gcr.io/distroless/static-debian12
WORKDIR /src
COPY --from=builder /productcatalogservice ./server
COPY products.json .

ENV GOTRACEBACK=single

EXPOSE 3550
ENTRYPOINT ["/src/server"]

