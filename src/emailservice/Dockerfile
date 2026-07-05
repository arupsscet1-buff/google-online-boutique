FROM python:3.14.6-alpine3.24 AS builder

# get packages
COPY requirements.txt .
RUN pip install -r requirements.txt

FROM gcr.io/distroless/python3-debian12
WORKDIR /email_server
# Grab packages from builder
COPY --from=builder /usr/local/lib/python3.14/ /usr/local/lib/python3.14/

# Add the application
COPY . .

EXPOSE 8080
ENTRYPOINT [ "email_server.py" ]
