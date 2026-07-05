FROM python:3.14.6-alpine3.24 AS builder
# get packages
COPY requirements.txt .
RUN pip install -r requirements.txt

FROM gcr.io/distroless/python3-debian12
WORKDIR /recommendationservice
# Grab packages from builder
COPY --from=builder /usr/local/lib/python3.14/ /usr/local/lib/python3.14/

# Add the application
COPY . .

USER 65532
# set listen port
ENV PORT="8080"
EXPOSE 8080

ENTRYPOINT ["recommendation_server.py"]
