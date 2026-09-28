#!/bin/sh
# Generates a local CA and TLS certificate for the Mosquitto broker.
set -e

cd /certs

if [ -f server.crt ] && [ -f ca.crt ]; then
    echo "certs already exist"
    exit 0
fi

# Create local Certificate Authority
openssl genrsa -out ca.key 2048

openssl req -x509 -new -key ca.key -sha256 -days 365 \
    -subj "/CN=smart-disaster-relief-local-ca" \
    -out ca.crt

# Create Mosquitto server certificate
openssl genrsa -out server.key 2048

openssl req -new -key server.key \
    -subj "/CN=broker" \
    -out server.csr

# Allow both Docker services and host applications to verify the broker
printf "subjectAltName=DNS:broker,DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n" > san.ext

openssl x509 -req \
    -in server.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out server.crt \
    -days 365 \
    -sha256 \
    -extfile san.ext

chmod 644 ca.crt server.crt server.key

echo "Mosquitto TLS certificates generated"