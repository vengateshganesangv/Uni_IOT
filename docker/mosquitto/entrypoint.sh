#!/bin/sh
# Writes the TLS material passed in env vars to files, then starts Mosquitto in the foreground.
set -e
mkdir -p /tmp/certs
printf '%s\n' "$CA_CRT"     > /tmp/certs/ca.crt
printf '%s\n' "$SERVER_CRT" > /tmp/certs/server.crt
printf '%s\n' "$SERVER_KEY" > /tmp/certs/server.key
chmod 644 /tmp/certs/*
exec /usr/sbin/mosquitto -c /mosquitto/config/mosquitto.conf
