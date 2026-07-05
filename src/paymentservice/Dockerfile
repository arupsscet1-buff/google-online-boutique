FROM node:24-alpine3.24

WORKDIR /usr/src/app

COPY package*.json ./
RUN npm ci --omit=dev

FROM gcr.io/distroless/nodejs24-debian12
WORKDIR /usr/src/app
COPY --from=builder /usr/src/app/node_modules ./node_modules
COPY . .
USER 65532
EXPOSE 50051
CMD ["index.js"]
