#!/bin/sh
# Generates a throwaway CA + server cert whose SAN is the HiveMQ hostname hard-coded in every service,
# so the unmodified services can TLS-connect to the local Mosquitto broker (network alias = that hostname).
set -e
HOST="1490e7aa531c43e6af66775dcb39171b.s1.eu.hivemq.cloud"
cd /certs
if [ -f server.crt ] && [ -f ca.crt ]; then echo "certs already exist"; exit 0; fi
openssl genrsa -out ca.key 2048
openssl req -x509 -new -key ca.key -sha256 -days 365 -subj "/CN=local-dev-ca" -out ca.crt
openssl genrsa -out server.key 2048
openssl req -new -key server.key -subj "/CN=$HOST" -out server.csr
printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\n" "$HOST" > san.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 365 -sha256 -extfile san.ext
chmod 644 ca.crt server.crt server.key
echo "certs generated for $HOST"
