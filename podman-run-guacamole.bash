#!/usr/bin/env bash
set -euxo pipefail

# Apache Guacamole with PostgreSQL, guacd, and the web application.

NETWORK="guacamole"
POSTGRES_CONTAINER="guacamole-postgres"
GUACD_CONTAINER="guacamole-guacd"
GUACAMOLE_CONTAINER="guacamole"
POSTGRES_USER="${POSTGRES_USER:-guacamole}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-guacamole}"
POSTGRES_DATABASE="${POSTGRES_DATABASE:-guacamole}"
GUACAMOLE_PORT="${GUACAMOLE_PORT:-8090}"
GUACAMOLE_CONNECTION_NAME="${GUACAMOLE_CONNECTION_NAME:-Local SSH}"
GUACAMOLE_CONNECTION_PROTOCOL="${GUACAMOLE_CONNECTION_PROTOCOL:-ssh}"
GUACAMOLE_CONNECTION_HOSTNAME="${GUACAMOLE_CONNECTION_HOSTNAME:-host.containers.internal}"
GUACAMOLE_CONNECTION_PORT="${GUACAMOLE_CONNECTION_PORT:-22}"
GUACAMOLE_CONNECTION_USERNAME="${GUACAMOLE_CONNECTION_USERNAME:-}"
GUACAMOLE_CONNECTION_PASSWORD="${GUACAMOLE_CONNECTION_PASSWORD:-}"

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
	echo "Waiting for PostgreSQL to become ready..."
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

# Create the connection once and grant guacadmin access to it.
podman exec -i "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 \
	-v conn_name="$GUACAMOLE_CONNECTION_NAME" \
	-v conn_protocol="$GUACAMOLE_CONNECTION_PROTOCOL" \
	-v conn_hostname="$GUACAMOLE_CONNECTION_HOSTNAME" \
	-v conn_port="$GUACAMOLE_CONNECTION_PORT" \
	-v conn_username="$GUACAMOLE_CONNECTION_USERNAME" \
	-v conn_password="$GUACAMOLE_CONNECTION_PASSWORD" \
	-U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" <<'SQL'
WITH connection AS (
	INSERT INTO guacamole_connection (connection_name, protocol_id)
	VALUES (:'conn_name', :'conn_protocol')
	ON CONFLICT (connection_name) DO UPDATE SET connection_name = EXCLUDED.connection_name
	RETURNING connection_id
), parameters(parameter_name, parameter_value) AS (
	VALUES
		('hostname', :'conn_hostname'),
		('port', :'conn_port'),
		('username', :'conn_username'),
		('password', :'conn_password')
)
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection.connection_id, parameters.parameter_name, parameters.parameter_value
FROM connection CROSS JOIN parameters
WHERE parameters.parameter_value <> ''
ON CONFLICT (connection_id, parameter_name) DO UPDATE
SET parameter_value = EXCLUDED.parameter_value;

INSERT INTO guacamole_connection_permission (user_id, connection_id, permission)
SELECT u.user_id, c.connection_id, 'READ'
FROM guacamole_user u
JOIN guacamole_connection c ON c.connection_name = :'conn_name'
WHERE u.username = 'guacadmin'
ON CONFLICT (user_id, connection_id, permission) DO NOTHING;
SQL

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

echo "Apache Guacamole is available at: http://localhost:${GUACAMOLE_PORT}/guacamole/ with guacadmin:guacadmin"
