#!/bin/sh
# First-boot database setup for the lab. The postgres image runs this only when its data
# volume is empty; every later start skips it, so reset.sh has to drop the volume for a
# change here to take effect.
#
# NODUS_DB_PASSWORD is handed in by compose. The role is deliberately not a superuser:
# Nodus creates its own tables and extensions, and the migrations expect citext and
# pg_trgm to already exist because CREATE EXTENSION needs privileges the app role does not
# have in this cluster.
set -eu

: "${NODUS_DB_PASSWORD:?NODUS_DB_PASSWORD is required}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=nodus_password="$NODUS_DB_PASSWORD" <<'SQL'
CREATE ROLE nodus LOGIN PASSWORD :'nodus_password';
CREATE DATABASE nodus OWNER nodus;
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname nodus <<'SQL'
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL
