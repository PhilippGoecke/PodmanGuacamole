#!/usr/bin/env bash
set -euo pipefail

# Apache Guacamole with PostgreSQL, guacd, and the web application.

NETWORK="guacamole"
POSTGRES_CONTAINER="guacamole-postgres"
GUACD_CONTAINER="guacamole-guacd"
GUACAMOLE_CONTAINER="guacamole"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-change-me}"
GUACAMOLE_PORT="${GUACAMOLE_PORT:-8080}"

podman network exists "$NETWORK" || podman network create "$NETWORK"
podman volume exists guacamole-postgres || podman volume create guacamole-postgres

podman container exists "$POSTGRES_CONTAINER" || podman run -d \
	--name "$POSTGRES_CONTAINER" \
	--network "$NETWORK" \
	-e POSTGRES_DB=guacamole_db \
	-e POSTGRES_USER=guacamole_user \
	-e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
	-v guacamole-postgres:/var/lib/postgresql/data \
	docker.io/library/postgres:16-alpine

until podman exec "$POSTGRES_CONTAINER" pg_isready -U guacamole_user -d guacamole_db >/dev/null 2>&1; do
	sleep 2
done

if ! podman volume exists guacamole-init; then
	podman volume create guacamole-init
	podman run --rm \
		-v guacamole-init:/init:Z \
		docker.io/guacamole/guacamole:1.5.5 \
		/opt/guacamole/bin/initdb.sh --postgresql > /tmp/guacamole-schema.sql
	podman cp /tmp/guacamole-schema.sql "$POSTGRES_CONTAINER":/tmp/guacamole-schema.sql
	podman exec "$POSTGRES_CONTAINER" psql -U guacamole_user -d guacamole_db -f /tmp/guacamole-schema.sql
	rm -f /tmp/guacamole-schema.sql
fi

podman container exists "$GUACD_CONTAINER" || podman run -d \
	--name "$GUACD_CONTAINER" \
	--network "$NETWORK" \
	docker.io/guacamole/guacd:1.5.5

podman container exists "$GUACAMOLE_CONTAINER" || podman run -d \
	--name "$GUACAMOLE_CONTAINER" \
	--network "$NETWORK" \
	-p "${GUACAMOLE_PORT}:8080" \
	-e GUACD_HOSTNAME="$GUACD_CONTAINER" \
	-e POSTGRESQL_ENABLED=true \
	-e POSTGRESQL_HOSTNAME="$POSTGRES_CONTAINER" \
	-e POSTGRESQL_DATABASE=guacamole_db \
	-e POSTGRESQL_USERNAME=guacamole_user \
	-e POSTGRESQL_PASSWORD="$POSTGRES_PASSWORD" \
	docker.io/guacamole/guacamole:1.5.5

echo "Apache Guacamole is available at: http://localhost:${GUACAMOLE_PORT}/guacamole/"
