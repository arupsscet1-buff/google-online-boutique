FROM python:3.13-slim AS builder

WORKDIR /src

COPY requirements.txt .

RUN pip install \
    --no-cache-dir \
    --prefix=/install \
    -r requirements.txt

COPY locustfile.py .

FROM gcr.io/distroless/python3-debian12

WORKDIR /app

COPY --from=builder /install /usr/local
COPY --from=builder /src/locustfile.py .

ENV GEVENT_SUPPORT=True

ENTRYPOINT ["python","-m","locust"]