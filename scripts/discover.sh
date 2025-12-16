#!/bin/sh
set -eu

#apk add --no-cache docker-cli jq coreutils grep sed

IMAGE_FILTER="${IMAGE_FILTER:-mysql|mariadb|postgres}"
TARGET_NETWORK="${TARGET_NETWORK:-ext_stack}"

DEFAULT_DB_NAME="${DEFAULT_DB_NAME:-ALL}"
DEFAULT_EXCLUDE="${DEFAULT_EXCLUDE:-information_schema,performance_schema,mysql,sys,pg_catalog,pg_toast}"
DEFAULT_PORT_MYSQL="${DEFAULT_PORT_MYSQL:-3306}"
DEFAULT_PORT_POSTGRES="${DEFAULT_PORT_POSTGRES:-5432}"

MYSQL_USER_KEYS="${MYSQL_USER_KEYS:-DB_USER,MYSQL_USER,MARIADB_USER,MYSQL_ROOT_USER}"
MYSQL_PASS_KEYS="${MYSQL_PASS_KEYS:-DB_PASS,MYSQL_PASSWORD,MARIADB_PASSWORD,MYSQL_ROOT_PASSWORD,MARIADB_ROOT_PASSWORD}"
PG_USER_KEYS="${PG_USER_KEYS:-POSTGRES_USER,PGUSER,DB_USER}"
PG_PASS_KEYS="${PG_PASS_KEYS:-POSTGRES_PASSWORD,PGPASSWORD,DB_PASS}"

ENV_FILE="${ENV_FILE:-/output/env_file}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

discover_once() {
  LOOP_NUM=0
  echo -e "#!/bin/sh\n# generated $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ENV_FILE"
  chmod +x "$ENV_FILE"
  # List containers
  docker ps --format '{{.ID}} {{.Image}} {{.Names}}' \
  | grep -E -i " (${IMAGE_FILTER})" \
  | while read -r ID IMAGE NAME; do
      # Inspect: env + networks
      INSPECT="$(docker inspect "$ID")"
      # Check if shared network with TARGET_NETWORK
      IN_NET="$(echo "$INSPECT" | jq -r --arg NET "$TARGET_NETWORK" '.[0].NetworkSettings.Networks[$NET] | if .==null then "no" else "yes" end')"
      if [ "$IN_NET" != "yes" ]; then
        log "[Warning] Skip $NAME (not in network $TARGET_NETWORK)"
        # TODO add mail or zabbix notification or elastic ?
        continue
      fi
      LOOP_NUM=$((LOOP_NUM+1))
      if [ $LOOP_NUM -lt 10 ]; then
        LOOP_STR=0${LOOP_NUM}
      else
        LOOP_STR=${LOOP_NUM}
      fi

      # Detect type
      TYPE="mysql"
      echo "$IMAGE" | grep -Eiq 'postgres' && TYPE="postgres"

      # Host = container name for dns resolution
      HOST="$NAME"
      PORT="$DEFAULT_PORT_MYSQL"
      [ "$TYPE" = "postgres" ] && PORT="$DEFAULT_PORT_POSTGRES"

      # Extract env from container
      # Check if one of the keyword exist for the DB type
      ENV_ARR=$(echo "$INSPECT" | jq -r '.[0].Config.Env[]')

      get_env_val() {
        KEYS_CSV="$1"
        echo "$KEYS_CSV" | tr ',' '\n' | while read -r K; do
          VAL="$(echo "$ENV_ARR" | grep -E "^${K}=" | tail -n1 | sed "s/^${K}=//")" || true
          [ -n "${VAL:-}" ] && { printf '%s' "$VAL"; return 0; }
        done
        return 1
      }

      USER=""
      PASS=""
      if [ "$TYPE" = "mysql" ]; then
        USER="$(get_env_val "$MYSQL_USER_KEYS" || true)"
        PASS="$(get_env_val "$MYSQL_PASS_KEYS" || true)"
      else
        USER="$(get_env_val "$PG_USER_KEYS" || true)"
        PASS="$(get_env_val "$PG_PASS_KEYS" || true)"
      fi

      if [ -z "$USER" ] || [ -z "$PASS" ]; then
        log "WARN $NAME: credentials not found in ENV (user='$USER' pass_len=${#PASS}). Skipping."
        continue
      fi

      # Generate docker-db-backup formated variables
      log "Generate data for: $NAME (type=$TYPE host=$HOST port=$PORT user=$USER)"
      case "$TYPE" in
        "mysql")
          echo "
export DB${LOOP_STR}_TYPE=mysql
export DB${LOOP_STR}_HOST=$HOST
export DB${LOOP_STR}_PORT=$PORT
export DB${LOOP_STR}_NAME=$DEFAULT_DB_NAME
export DB${LOOP_STR}_NAME_EXCLUDE=$DEFAULT_EXCLUDE
export DB${LOOP_STR}_USER=$USER
export DB${LOOP_STR}_PASS=$PASS
          " >> "$ENV_FILE"
          ;;
        "pgsql")
          echo "
export DB${LOOP_STR}_TYPE=pgsql
export DB${LOOP_STR}_HOST=$HOST
export DB${LOOP_STR}_PORT=$PORT
export DB${LOOP_STR}_NAME=$DEFAULT_DB_NAME
export DB${LOOP_STR}_NAME_EXCLUDE=$DEFAULT_EXCLUDE
export DB${LOOP_STR}_USER=$USER
export DB${LOOP_STR}_PASS=$PASS
          " >> "$ENV_FILE"
          ;;
        *)
          log "Impossible to dump $NAME - type $TYPE not managed"
          ;;
      esac
    done
}

while read -r CONTAINER_NAME; do
  log "triggered by $CONTAINER_NAME"
  discover_once
done
