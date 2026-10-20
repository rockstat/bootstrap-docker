#!/usr/bin/env bash
#
# Rockstat single-host deploy (docker-compose edition of ../deploy.yml).
#
# Usage:
#   ./deploy.sh setup                # fresh host: install docker, compose, envsubst
#   ./deploy.sh init                 # preflight + dirs + networks + configs + front workers
#   ./deploy.sh cert-init            # obtain Let's Encrypt cert (needs DNS -> host)
#   ./deploy.sh up [compose args]    # up -d --pull always (core services)
#   ./deploy.sh up --profile devtools
#   ./deploy.sh create-db            # wait for clickhouse & create database
#   ./deploy.sh preflight            # run checks only
#   ./deploy.sh render               # re-render configs / regenerate front file
#   ./deploy.sh compose <args>       # raw docker compose with both files
#   ./deploy.sh down|ps|logs ...     # shortcuts to docker compose
#
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,16p' "$0"; }

##### host provisioning (no .env required) #####

setup() {
  echo "==> Installing prerequisites (docker, compose v2, gettext-base, curl)"
  if ! command -v apt-get >/dev/null; then
    echo "setup supports apt-based systems only; install docker, docker compose v2, gettext-base manually" >&2
    exit 1
  fi
  local SUDO=""
  [[ $EUID -ne 0 ]] && SUDO="sudo"
  $SUDO apt-get update -qq
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl gettext-base docker.io docker-compose-v2
  $SUDO systemctl enable --now docker
  if [[ $EUID -ne 0 && -n "${USER:-}" ]]; then
    $SUDO usermod -aG docker "$USER" \
      && echo "    added $USER to docker group (re-login, or keep using sudo)"
  fi
  echo "Done. Next: cp .env.example .env, edit it, then ./deploy.sh init"
}

cmd=${1:-help}
shift || true

case "$cmd" in
  setup) setup; exit 0 ;;
  help|-h|--help) usage; exit 0 ;;
esac

##### everything below needs .env #####

if [[ ! -f .env ]]; then
  echo "No .env found. Copy .env.example to .env and edit it first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

COMPOSE_FILES=(-f docker-compose.yml -f compose.front.yml)

ch_local() { [[ "${CLICKHOUSE_LOCAL:-1}" == "1" ]]; }

# resolve a (possibly relative) dir to an absolute path, creating it
abs_path() { mkdir -p "$1"; (cd "$1" && pwd); }

compose() {
  local pf=()
  ch_local && pf=(--profile clickhouse)
  docker compose "${COMPOSE_FILES[@]}" ${pf[@]+"${pf[@]}"} "$@"
}

preflight() {
  echo "==> Preflight checks"
  local fail=0

  command -v docker >/dev/null \
    || { echo " [x] docker not installed — run: ./deploy.sh setup"; fail=1; }
  if command -v docker >/dev/null && ! docker info >/dev/null 2>&1; then
    echo " [x] cannot talk to the docker daemon — run via sudo, or add user to the docker group"
    fail=1
  fi
  docker compose version >/dev/null 2>&1 \
    || { echo " [x] docker compose v2 missing — run: ./deploy.sh setup"; fail=1; }
  command -v envsubst >/dev/null \
    || { echo " [x] envsubst missing — run: ./deploy.sh setup (gettext-base)"; fail=1; }
  command -v curl >/dev/null \
    || { echo " [x] curl missing — run: ./deploy.sh setup"; fail=1; }

  local v
  for v in DOMAIN EMAIL DATA_DIR ETC_DIR BIND_IP DOCKER_NET DOCKER_NET_NAME \
           CLICKHOUSE_HOST CLICKHOUSE_PASSWORD PUID PGID FRONT_SCALE; do
    [[ -n "${!v:-}" ]] || { echo " [x] $v is empty in .env"; fail=1; }
  done
  [[ "${DOMAIN:-}" != "example.com" ]] \
    || { echo " [x] DOMAIN is still example.com — edit .env"; fail=1; }
  if ! ch_local && [[ "${CLICKHOUSE_HOST:-}" == "${BIND_IP:-}" ]]; then
    echo " [!] CLICKHOUSE_LOCAL=0, but CLICKHOUSE_HOST still points to BIND_IP — set the external server address"
  fi

  # memory limits vs host RAM (warning only)
  if [[ -r /proc/meminfo && "${MEM_LIMIT_CLICKHOUSE:-}" =~ ^([0-9]+)g$ ]]; then
    local ch_g=${BASH_REMATCH[1]} mem_kb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    if (( ch_g * 1024 * 1024 > mem_kb )); then
      echo " [!] MEM_LIMIT_CLICKHOUSE=${MEM_LIMIT_CLICKHOUSE} exceeds host RAM" \
           "($(awk '/MemTotal/{printf "%.1fG", $2/1048576}' /proc/meminfo)) — lower it in .env"
    fi
  fi

  # a bind-mounted file that does not exist becomes a DIRECTORY at the source,
  # and caddy/chproxy then crash with "read /cert.pem: is a directory"
  for v in SSL_CERT SSL_CERT_KEY; do
    local p="${!v:-}"
    if [[ -n "$p" && -d "$p" ]]; then
      echo " [x] $v=$p is a directory (docker created it in place of a missing file) — remove it, fix the path and recreate the containers"
      fail=1
    elif [[ -n "$p" && ! -f "$p" ]]; then
      echo " [!] $v=$p — file does not exist (wrong domain in the path?); chproxy/caddy will not start until cert-init creates it"
    fi
  done

  # DNS must point at this host for Let's Encrypt (warning only)
  if command -v curl >/dev/null; then
    local dns_ip pub_ip
    dns_ip=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
    pub_ip=$(curl -fsS -4 --max-time 5 https://ifconfig.me 2>/dev/null || true)
    if [[ -z "$dns_ip" ]]; then
      echo " [!] $DOMAIN does not resolve — cert-init will fail until DNS is set up"
    elif [[ -n "$pub_ip" && "$dns_ip" != "$pub_ip" ]]; then
      echo " [!] DNS: $DOMAIN -> $dns_ip, host public IP: $pub_ip — cert-init will fail"
    fi
  fi

  if (( fail )); then
    echo "Preflight failed." >&2
    exit 1
  fi
  echo "    OK"
}

init_dirs() {
  echo "==> Creating directories"
  local dirs=(
    "$DATA_DIR" "$ETC_DIR"
    "$DATA_DIR/front_custom_config" "$DATA_DIR/front_selected_events"
    "$DATA_DIR/chwriter_custom_config" "$DATA_DIR/chwriter_custom_migrations"
    "$DATA_DIR/chwriter_emergency"
    "$DATA_DIR/kafkastream_custom_config"
    "$DATA_DIR/uploads" "$DATA_DIR/public" "$DATA_DIR/workspace" "$DATA_DIR/shared"
    "$DATA_DIR/certs" "$DATA_DIR/enrichers_dbs"
    "$DATA_DIR/caddy_home" "$DATA_DIR/caddy_home/data"
    "$DATA_DIR/jupyter_home/data" "$DATA_DIR/grafana/data"
    "$DATA_DIR/telegraf_config"
    "$DATA_DIR/nginx/conf.d" "$DATA_DIR/nginx/includes"
    "$DATA_DIR/certbot/conf" "$DATA_DIR/certbot/www"
    "$REDIS_DATA_DIR"
  )
  if ch_local; then
    dirs+=(
      "$DATA_DIR/clickhouse_config" "$DATA_DIR/clickhouse_scripts"
      "$CLICKHOUSE_DATA_DIR" "$CLICKHOUSE_TMP_DIR" "$CLICKHOUSE_LOG_DIR"
    )
  fi
  mkdir -p "${dirs[@]}"
  if ! chown "${PUID}:${PGID}" "${dirs[@]}" 2>/dev/null; then
    echo "    (!) could not chown to ${PUID}:${PGID} — run as root if needed"
  fi
}

init_networks() {
  echo "==> Creating docker networks"
  if ! docker network inspect "$DOCKER_NET_NAME" >/dev/null 2>&1; then
    docker network create --driver=bridge --subnet="$DOCKER_NET" \
      -o "com.docker.network.bridge.name=$DOCKER_NET_NAME" "$DOCKER_NET_NAME"
  fi
  if ! docker network inspect "$DOCKER_DEV_NET_NAME" >/dev/null 2>&1; then
    docker network create --driver=bridge --subnet="$DOCKER_DEV_NET" \
      -o "com.docker.network.bridge.name=$DOCKER_DEV_NET_NAME" "$DOCKER_DEV_NET_NAME"
  fi
}

render_tmpl() { # render_tmpl <src.tmpl> <dst> '<var list for envsubst>'
  envsubst "$3" < "$1" > "$2"
  echo "    $1 -> $2"
}

render_configs() {
  echo "==> Rendering configs"
  command -v envsubst >/dev/null || {
    echo "envsubst not found (apt install gettext-base)" >&2; exit 1; }

  mkdir -p generated "$DATA_DIR/telegraf_config" "$DATA_DIR/caddy_home" "$ETC_DIR"

  if ch_local; then
    mkdir -p "$DATA_DIR/clickhouse_config"
    cp configs/clickhouse/001_server.xml configs/clickhouse/003_drop_limits.xml "$DATA_DIR/clickhouse_config/"
    render_tmpl configs/clickhouse/002_users.xml.tmpl "$DATA_DIR/clickhouse_config/002_users.xml" \
      '${CLICKHOUSE_PASSWORD} ${CLICKHOUSE_RO_PASSWORD}'
  fi
  render_tmpl configs/chproxy/config.yml.tmpl "$ETC_DIR/chproxy.yml" \
    '${CLICKHOUSE_PASSWORD} ${CLICKHOUSE_RO_PASSWORD} ${CLICKHOUSE_HOST} ${CLICKHOUSE_HTTP_PORT}'
  render_tmpl configs/telegraf/telegraf.conf.tmpl "$DATA_DIR/telegraf_config/telegraf.conf" \
    '${DOMAIN} ${INFLUXDB_URL} ${INFLUXDB_TOKEN} ${INFLUXDB_ORG} ${INFLUXDB_BUCKET}'
  render_tmpl configs/caddy/Caddyfile.tmpl "$DATA_DIR/caddy_home/Caddyfile" \
    '${DOMAIN} ${CADDY_PORT}'

  mkdir -p "$DATA_DIR/nginx/conf.d" "$DATA_DIR/nginx/includes"
  render_tmpl configs/nginx/rockstat.conf.tmpl "$DATA_DIR/nginx/conf.d/rockstat.conf" \
    '${DOMAIN}'
  cp -f configs/nginx/includes/*.conf "$DATA_DIR/nginx/includes/" 2>/dev/null || true

  # service custom configs (ansible: templates/priv_<group>/*)
  cp -f custom/front/*.yml          "$DATA_DIR/front_custom_config/"           2>/dev/null || true
  cp -f custom/chwriter/*.yml       "$DATA_DIR/chwriter_custom_config/"        2>/dev/null || true
  cp -f custom/kafkastream/*.yml    "$DATA_DIR/kafkastream_custom_config/"     2>/dev/null || true

  echo "==> Writing generated/common.env"
  cat > generated/common.env <<EOF
JSON_LOGS=1
LOG_LEVEL=${LOG_LEVEL:-info}
DOMAIN=${DOMAIN}
HOST_ADDR=${BIND_IP}
STATSD_HOST=${BIND_IP}
NETWORK=${DOCKER_NET_NAME}
REDIS_DSN=redis://redis:6379
FULLNAME=${FULLNAME}
EMAIL=${EMAIL}
UPLOADS_DIR=$(abs_path "$DATA_DIR/uploads")
CH_DSN=http://${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}@${BIND_IP}:8443/${CLICKHOUSE_DB}
CHP_DSN=http://${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}@${BIND_IP}:8443/${CLICKHOUSE_DB}
CHS_DSN=http://${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}@${CLICKHOUSE_HOST}:${CLICKHOUSE_HTTP_PORT:-8123}/${CLICKHOUSE_DB}
TZ=${TZ:-UTC}
KAFKA_BROKERS=${KAFKA_BROKERS:-}
DATACENTER_ID=1
WORKER_ID=1
EOF
}

gen_front() {
  local n=${FRONT_SCALE:-5} base=${FRONT_PORT_BASE:-10001} out=compose.front.yml
  echo "==> Generating $out ($n front workers)"
  {
    echo "# Generated by deploy.sh — do not edit (FRONT_SCALE=$n)"
    echo "services:"
    for ((i = 1; i <= n; i++)); do
      local port=$((base + 2 * i))
      cat <<EOF
  front_${i}:
    image: \${IMAGE_FRONT}
    container_name: front_${i}
    hostname: front_${i}
    labels:
      inband: system
    restart: unless-stopped
    mem_limit: 500m
    networks:
      - custom
    extra_hosts:
      - "host:\${BIND_IP}"
    env_file:
      - generated/common.env
    environment:
      WORKER_ID: "${i}"
    ports:
      - "\${BIND_IP}:${port}:8080"
    volumes:
      - \${DATA_DIR}/front_custom_config:/app/front/config/custom
      - \${DATA_DIR}/front_selected_events:/front_selected_events
      - \${DATA_DIR}/public:/app/front/public
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "10"
EOF
    done
    echo "  nginx:"
    echo "    depends_on:"
    for ((i = 1; i <= n; i++)); do
      echo "      - front_${i}"
    done
  } > "$out"

  echo "==> Generating nginx upstream for $n front workers"
  mkdir -p "$DATA_DIR/nginx/conf.d"
  {
    echo "# Generated by deploy.sh — do not edit (FRONT_SCALE=$n)"
    echo "upstream ufront {"
    echo "    least_conn;"
    for ((i = 1; i <= n; i++)); do
      echo "    server front_${i}:8080 max_fails=3 fail_timeout=30s;"
    done
    echo "    keepalive 32;"
    echo "}"
  } > "$DATA_DIR/nginx/conf.d/upstream_front.conf"
}

make_dummy_cert() { # temporary self-signed cert so nginx can start
  local conf
  conf=$(abs_path "$DATA_DIR/certbot/conf") # docker run -v needs an absolute path
  mkdir -p "$conf/live/$DOMAIN"
  docker run --rm -v "$conf:/etc/letsencrypt" \
    --entrypoint sh "$IMAGE_CERTBOT" -c \
    "openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
      -keyout '/etc/letsencrypt/live/$DOMAIN/privkey.pem' \
      -out '/etc/letsencrypt/live/$DOMAIN/fullchain.pem' \
      -subj '/CN=$DOMAIN'" >/dev/null 2>&1
}

wait_nginx_http() {
  echo "==> Waiting for nginx to serve on :80"
  local i
  for i in $(seq 1 30); do
    if curl -so /dev/null --max-time 3 http://localhost/; then return 0; fi
    sleep 2
  done
  return 1
}

cert_init() {
  local live="$DATA_DIR/certbot/conf/live/$DOMAIN"
  mkdir -p "$DATA_DIR/certbot/conf" "$DATA_DIR/certbot/www"

  if [[ -e "$live/fullchain.pem" ]] && \
     [[ -e "$DATA_DIR/certbot/conf/renewal/$DOMAIN.conf" ]]; then
    echo "==> Certificate for $DOMAIN already exists, starting nginx"
    compose up -d nginx certbot
    return
  fi

  echo "==> Creating temporary self-signed cert so nginx can start"
  make_dummy_cert

  compose up -d nginx
  if ! wait_nginx_http; then
    echo "nginx is not serving on :80, aborting (logs below)" >&2
    docker logs nginx --tail 20 >&2 || true
    exit 1
  fi

  echo "==> Requesting Let's Encrypt certificate for $DOMAIN"
  # nginx keeps the dummy cert in memory, so removing it here is safe
  rm -rf "$live" "$DATA_DIR/certbot/conf/archive/$DOMAIN" \
    "$DATA_DIR/certbot/conf/renewal/$DOMAIN.conf"
  local staging=()
  [[ "${LETSENCRYPT_STAGING:-0}" == "1" ]] && staging=(--staging)
  if ! compose run --rm --entrypoint certbot certbot certonly \
      --webroot -w /var/www/certbot "${staging[@]}" \
      -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email \
      --rsa-key-size 4096; then
    echo "==> certbot failed; restoring temporary cert so nginx survives restarts" >&2
    make_dummy_cert
    exit 1
  fi

  compose exec nginx nginx -s reload
  compose up -d certbot
  echo "==> Done: certificate obtained, auto-renewal is handled by the certbot container"
}

create_db() {
  local ch="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_HTTP_PORT:-8123}"
  echo "==> Waiting for ClickHouse on ${ch}"
  for _ in $(seq 1 120); do
    curl -fsS "${ch}/ping" >/dev/null 2>&1 && break
    sleep 5
  done
  curl -fsS "${ch}/ping" >/dev/null
  # stats_ui is the ui service's own database
  local db
  for db in "${CLICKHOUSE_DB}" stats_ui; do
    echo "==> CREATE DATABASE IF NOT EXISTS ${db}"
    curl -fsS "${ch}/" \
      -H "X-ClickHouse-User: ${CLICKHOUSE_USER}" \
      -H "X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" \
      --data-binary "CREATE DATABASE IF NOT EXISTS ${db}"
  done
}

case "$cmd" in
  preflight)
    preflight
    ;;
  init)
    preflight
    init_dirs
    init_networks
    render_configs
    gen_front
    echo "Done. Next: ./deploy.sh cert-init && ./deploy.sh up"
    ;;
  render)
    render_configs
    gen_front
    ;;
  gen-front)
    gen_front
    ;;
  up)
    preflight
    [[ -f generated/common.env && -f compose.front.yml ]] || { echo "Run ./deploy.sh init first" >&2; exit 1; }
    # docker compose takes --profile before the subcommand — move them there
    pre=() post=()
    while (($#)); do
      case "$1" in
        --profile) pre+=(--profile "${2:?--profile needs a value}"); shift 2 ;;
        --profile=*) pre+=("$1"); shift ;;
        *) post+=("$1"); shift ;;
      esac
    done
    compose ${pre[@]+"${pre[@]}"} up -d --pull always ${post[@]+"${post[@]}"}
    ;;
  create-db)
    create_db
    ;;
  cert-init)
    preflight
    cert_init
    ;;
  compose)
    compose "$@"
    ;;
  down|ps|logs|pull|stop|start|restart|config)
    compose "$cmd" "$@"
    ;;
  *)
    usage
    ;;
esac
