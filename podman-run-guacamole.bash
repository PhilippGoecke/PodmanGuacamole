#!/usr/bin/env bash
set -euo pipefail

# Apache Guacamole with PostgreSQL, guacd, and the web application.

NETWORK="guacamole"
POSTGRES_CONTAINER="guacamole-postgres"
GUACD_CONTAINER="guacamole-guacd"
GUACAMOLE_CONTAINER="guacamole"
POSTGRES_USER="${POSTGRES_USER:-guacamole}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-guacamole}"
POSTGRES_DATABASE="${POSTGRES_DATABASE:-guacamole}"
GUACAMOLE_PORT="${GUACAMOLE_PORT:-8090}"

podman network exists "$NETWORK" || podman network create "$NETWORK"
podman volume exists guacamole-postgres || podman volume create guacamole-postgres

podman container exists "$POSTGRES_CONTAINER" || podman run -d \
	--name "$POSTGRES_CONTAINER" \
	--network "$NETWORK" \
	-e POSTGRES_DB="$POSTGRES_DATABASE" \
	-e POSTGRES_USER="$POSTGRES_USER" \
	-e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
	-v guacamole-postgres:/var/lib/postgresql/data \
	docker.io/library/postgres:17-alpine

until podman exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" >/dev/null 2>&1; do
	sleep 2
done

if ! podman volume exists guacamole-init; then
	podman volume create guacamole-init
	podman run --rm \
		-v guacamole-init:/init:Z \
		docker.io/guacamole/guacamole:1.6.0 \
		/opt/guacamole/bin/initdb.sh --postgresql > /tmp/guacamole-schema.sql
	podman cp /tmp/guacamole-schema.sql "$POSTGRES_CONTAINER":/tmp/guacamole-schema.sql
	podman exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -f /tmp/guacamole-schema.sql
	rm -f /tmp/guacamole-schema.sql
fi

podman container exists "$GUACD_CONTAINER" || podman run -d \
	--name "$GUACD_CONTAINER" \
	--network "$NETWORK" \
	docker.io/guacamole/guacd:1.6.0

podman container exists "$GUACAMOLE_CONTAINER" || podman run -d \
	--name "$GUACAMOLE_CONTAINER" \
	--network "$NETWORK" \
	-p "${GUACAMOLE_PORT}:8080" \
	-e GUACD_HOSTNAME="$GUACD_CONTAINER" \
	-e POSTGRESQL_ENABLED=true \
	-e POSTGRESQL_HOSTNAME="$POSTGRES_CONTAINER" \
	-e POSTGRESQL_DATABASE="$POSTGRES_DATABASE" \
	-e POSTGRESQL_USERNAME="$POSTGRES_USER" \
	-e POSTGRESQL_PASSWORD="$POSTGRES_PASSWORD" \
	docker.io/guacamole/guacamole:1.6.0

echo "Apache Guacamole is available at: http://localhost:${GUACAMOLE_PORT}/guacamole/"
