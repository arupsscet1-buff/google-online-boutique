FROM node:22-bookworm AS builder

WORKDIR /usr/src/app

COPY package*.json ./

RUN npm ci --omit=dev

COPY . .

FROM gcr.io/distroless/nodejs22-debian12

WORKDIR /usr/src/app

COPY --from=builder /usr/src/app .

USER 65532

EXPOSE 7000

CMD ["server.js"]
