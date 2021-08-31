#!/bin/sh

set -e

log() {
    TIMESTAMP=$(date -u "+%Y-%m-%dT%H:%M:%S.000+0000")
    LOGKIND=$1
    MESSAGE=$2
    echo "{\"timestamp\":\"$TIMESTAMP\",\"level\":\"info\",\"type\":\"startup\",\"detail\":{\"kind\":\"$LOGKIND\",\"info\":\"$MESSAGE\"}}"
}

DEFAULT_MIGRATIONS_DIR="/hasura-migrations"
DEFAULT_METADATA_DIR="/hasura-metadata"
DEFAULT_SEEDS_DIR="/hasura-seeds"
TEMP_PROJECT_DIR="/tmp/hasura-project"

# Use 9691 port for running temporary instance. 
# In case 9691 is occupied (according to docker networking), then this will fail.
# override with another port in that case
# TODO: Find a proper random port
if [ -z ${HASURA_GRAPHQL_MIGRATIONS_SERVER_PORT+x} ]; then
    log "migrations-startup" "migrations server port env var is not set, defaulting to 9691"
    HASURA_GRAPHQL_MIGRATIONS_SERVER_PORT=9691
fi

if [ -z ${HASURA_GRAPHQL_MIGRATIONS_SERVER_TIMEOUT+x} ]; then
    log "migrations-startup" "server timeout is not set, defaulting to 30 seconds"
    HASURA_GRAPHQL_MIGRATIONS_SERVER_TIMEOUT=30
fi

# wait for a port to be ready
wait_for_port() {
    local PORT=$1
    log "migrations-startup" "waiting $HASURA_GRAPHQL_MIGRATIONS_SERVER_TIMEOUT for $PORT to be ready"
    for i in `seq 1 $HASURA_GRAPHQL_MIGRATIONS_SERVER_TIMEOUT`;
    do
        nc -z localhost $PORT > /dev/null 2>&1 && log "migrations-startup" "port $PORT is ready" && return
        sleep 1
    done
    log "migrations-startup" "failed waiting for $PORT, try increasing HASURA_GRAPHQL_MIGRATIONS_SERVER_TIMEOUT (default: 30)" && exit 1
}

log "migrations-startup" "starting graphql engine temporarily on port $HASURA_GRAPHQL_MIGRATIONS_SERVER_PORT"

# start graphql engine with metadata api enabled
graphql-engine serve --enabled-apis="metadata" \
               --server-port=${HASURA_GRAPHQL_MIGRATIONS_SERVER_PORT}  &
# store the pid to kill it later
PID=$!

# wait for port to be ready
wait_for_port $HASURA_GRAPHQL_MIGRATIONS_SERVER_PORT

# check if migration directory is set, default otherwise
if [ -z ${HASURA_GRAPHQL_MIGRATIONS_DIR+x} ]; then
    log "migrations-startup" "env var HASURA_GRAPHQL_MIGRATIONS_DIR is not set, defaulting to $DEFAULT_MIGRATIONS_DIR"
    HASURA_GRAPHQL_MIGRATIONS_DIR="$DEFAULT_MIGRATIONS_DIR"
fi

# check if metadata directory is set, default otherwise
if [ -z ${HASURA_GRAPHQL_METADATA_DIR+x} ]; then
    log "migrations-startup" "env var HASURA_GRAPHQL_METADATA_DIR is not set, defaulting to $DEFAULT_METADATA_DIR"
    HASURA_GRAPHQL_METADATA_DIR="$DEFAULT_METADATA_DIR"
fi

# check if seeds directory is set, default otherwise
if [ -z ${HASURA_GRAPHQL_SEEDS_DIR+x} ]; then
    log "migrations-startup" "env var HASURA_GRAPHQL_SEEDS_DIR is not set, defaulting to $DEFAULT_SEEDS_DIR"
    HASURA_GRAPHQL_SEEDS_DIR="$DEFAULT_SEEDS_DIR"
fi

# apply migrations if the directory exist
if [ -d "$HASURA_GRAPHQL_MIGRATIONS_DIR" ]; then
    log "migrations-apply" "applying migrations from $HASURA_GRAPHQL_MIGRATIONS_DIR"
    mkdir -p "$TEMP_PROJECT_DIR"
    cp -a "$HASURA_GRAPHQL_MIGRATIONS_DIR/." "$TEMP_PROJECT_DIR/migrations/"
    cd "$TEMP_PROJECT_DIR"
    echo "version: 3" > config.yaml
    echo "endpoint: http://localhost:$HASURA_GRAPHQL_MIGRATIONS_SERVER_PORT" >> config.yaml
    hasura-cli migrate apply --all-databases
    log "migrations-apply" "reloading metadata"
    hasura-cli metadata reload
else
    log "migrations-apply" "directory $HASURA_GRAPHQL_MIGRATIONS_DIR does not exist, skipping migrations"
fi

# apply metadata if the directory exist
if [ -d "$HASURA_GRAPHQL_METADATA_DIR" ]; then
    rm -rf "TEMP_PROJECT_DIR"
    log "migrations-apply" "applying metadata from $HASURA_GRAPHQL_METADATA_DIR"
    mkdir -p "$TEMP_PROJECT_DIR"
    cp -a "$HASURA_GRAPHQL_METADATA_DIR/." "$TEMP_PROJECT_DIR/metadata/"
    cd "$TEMP_PROJECT_DIR"
    echo "version: 3" > config.yaml
    echo "endpoint: http://localhost:$HASURA_GRAPHQL_MIGRATIONS_SERVER_PORT" >> config.yaml
    echo "metadata_directory: metadata" >> config.yaml
    hasura-cli metadata apply 
else
    log "migrations-apply" "directory $HASURA_GRAPHQL_METADATA_DIR does not exist, skipping metadata"
fi

# apply seeds if the directory exist
if [ -d "$HASURA_GRAPHQL_SEEDS_DIR" ]; then
    log "seeds-apply" "applying seeds from $HASURA_GRAPHQL_SEEDS_DIR"
    mkdir -p "$TEMP_PROJECT_DIR"
    cp -a "$HASURA_GRAPHQL_SEEDS_DIR/." "$TEMP_PROJECT_DIR/seeds/"
    cd "$TEMP_PROJECT_DIR"
    echo "version: 3" > config.yaml
    echo "endpoint: http://localhost:$HASURA_GRAPHQL_MIGRATIONS_SERVER_PORT" >> config.yaml
    hasura-cli seed apply --database-name default
    # log "seeds-apply" "reloading metadata"
    # hasura-cli metadata reload
else
    log "seeds-apply" "directory $HASURA_GRAPHQL_SEEDS_DIR does not exist, skipping seeds"
fi

# kill graphql engine that we started earlier
log "migrations-shutdown" "killing temporary server"
kill $PID

# pass control to CMD
log "migrations-shutdown" "graphql-engine will now start in normal mode"
exec "$@"
