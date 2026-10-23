#!/usr/bin/env bash
#
# Interactive installer: asks the questions, writes .env, sets up the
# devtools password and runs the deploy steps. Safe to re-run.
#
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '      %s\n' "$*"; }

ask() { # ask VAR "prompt" "default"
  local _v
  read -rp "  $2 [$3]: " _v
  printf -v "$1" '%s' "${_v:-$3}"
}

ask_required() { # ask_required VAR "prompt"
  local _v=""
  while [[ -z "$_v" ]]; do read -rp "  $2: " _v; done
  printf -v "$1" '%s' "$_v"
}

ask_yn() { # ask_yn "prompt" y|n  -> 0 = yes
  local _v _d=${2:-n} _hint
  [[ "$_d" == y ]] && _hint="[Y/n]" || _hint="[y/N]"
  read -rp "  $1 $_hint: " _v
  _v=${_v:-$_d}
  [[ "$_v" == [yY]* ]]
}

genpass() { openssl rand -hex 12; }

say "Rockstat installer"
echo "  Answers are written to .env; nothing is deployed until you confirm."

if [[ -f .env ]]; then
  ask_yn ".env already exists — overwrite it?" n || { echo "Aborted, existing .env kept."; exit 1; }
fi

##### 1. host #####

say "1/6 Host"
ask_required DOMAIN "Domain (DNS must point to this host)"
[[ "$DOMAIN" != "example.com" ]] || { echo "example.com is a placeholder, use a real domain" >&2; exit 1; }
ask_required EMAIL "Admin email (expiry notices from Let's Encrypt)"
[[ "$EMAIL" != *@example.com ]] || { echo "Let's Encrypt rejects example.com emails" >&2; exit 1; }
ask FULLNAME "Owner name" "Rockstat"

##### 2. ssl #####

say "2/6 SSL certificate"
SSL_MODE=letsencrypt SSL_CERT="" SSL_CERT_KEY=""
if ask_yn "Use an EXISTING certificate instead of Let's Encrypt?" n; then
  SSL_MODE=custom
  while :; do
    ask_required SSL_CERT "Path to the certificate (fullchain) file"
    [[ -f "$SSL_CERT" ]] && break || note "file not found: $SSL_CERT"
  done
  while :; do
    ask_required SSL_CERT_KEY "Path to the private key file"
    [[ -f "$SSL_CERT_KEY" ]] && break || note "file not found: $SSL_CERT_KEY"
  done
else
  note "certbot will obtain the certificate on port 80 (keep it free and open)"
fi

##### 3. clickhouse #####

say "3/6 ClickHouse"
CLICKHOUSE_LOCAL=1 CLICKHOUSE_HOST=172.16.25.1 CLICKHOUSE_HTTP_PORT=8123
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=$(genpass) CLICKHOUSE_RO_PASSWORD=$(genpass)
MEM_LIMIT_CLICKHOUSE=6g CPUS_CLICKHOUSE=4 MEM_LIMIT_REDIS=1g
if ask_yn "Use an EXTERNAL ClickHouse server (no local one installed)?" n; then
  CLICKHOUSE_LOCAL=0
  ask_required CLICKHOUSE_HOST "ClickHouse host"
  ask CLICKHOUSE_HTTP_PORT "ClickHouse HTTP port" 8123
  ask CLICKHOUSE_USER "ClickHouse user" default
  ask_required CLICKHOUSE_PASSWORD "ClickHouse password"
else
  if [[ -r /proc/meminfo ]]; then
    total_gb=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
    sug=$(( total_gb * 60 / 100 )); (( sug < 2 )) && sug=2
    ask MEM_LIMIT_CLICKHOUSE "ClickHouse memory limit (host has ${total_gb}G)" "${sug}g"
    (( total_gb >= 24 )) && MEM_LIMIT_REDIS=5g
  else
    ask MEM_LIMIT_CLICKHOUSE "ClickHouse memory limit" 6g
  fi
  ask CPUS_CLICKHOUSE "ClickHouse CPU limit" "$(nproc 2>/dev/null || echo 4)"
  note "passwords are generated and saved to .env (default / readonly)"
fi
ask CLICKHOUSE_DB "Events database name" stats
ask MEM_LIMIT_REDIS "Redis memory limit" "$MEM_LIMIT_REDIS"

##### 4. front #####

say "4/6 Front"
ask FRONT_SCALE "Number of front workers" 4

##### 5. optional services #####

say "5/6 Optional services"
PROFILES=() KAFKA_BROKERS=""
INFLUXDB_URL="" INFLUXDB_TOKEN="" INFLUXDB_ORG="" INFLUXDB_BUCKET=""
DEVTOOLS=0 DEVTOOLS_LOGIN=user DEVTOOLS_PASSWORD=""
UI_PASSWORD="" UI_SECRET=""

ask_yn "Enrichers mmgeo/uap/uapc — geo and user-agent (profile: enrich)?" n \
  && PROFILES+=(enrich)
if ask_yn "ip2lgeo enricher — needs an IP2Location DB file?" n; then
  PROFILES+=(ip2lgeo)
  note "put the IP2Location DB file into data/enrichers_dbs BEFORE starting it"
fi
if ask_yn "Kafka stream?" n; then
  PROFILES+=(kafkastream)
  ask_required KAFKA_BROKERS "Kafka brokers (host:9092,host:9092)"
fi
if ask_yn "Telegraf metrics (writes to InfluxDB)?" n; then
  PROFILES+=(telegraf)
  ask_required INFLUXDB_URL "InfluxDB URL"
  ask_required INFLUXDB_TOKEN "InfluxDB token"
  ask INFLUXDB_ORG "InfluxDB org" ""
  ask INFLUXDB_BUCKET "InfluxDB bucket" ""
fi
if ask_yn "Devtools — caddy, jupyter, grafana, ui (profile: devtools)?" n; then
  DEVTOOLS=1
  PROFILES+=(devtools)
  ask DEVTOOLS_LOGIN "Devtools login" user
  ask DEVTOOLS_PASSWORD "Devtools password" "$(genpass)"
  UI_PASSWORD=$(genpass) UI_SECRET=$(genpass)
fi
EXTRA_PROFILES=$(IFS=,; echo "${PROFILES[*]:-}")

##### 6. summary #####

say "6/6 Summary"
cat <<EOF
  Domain:           $DOMAIN  ($EMAIL)
  SSL:              $SSL_MODE${SSL_CERT:+ ($SSL_CERT)}
  ClickHouse:       $([[ $CLICKHOUSE_LOCAL == 1 ]] && echo "local, mem=$MEM_LIMIT_CLICKHOUSE cpus=$CPUS_CLICKHOUSE" || echo "external $CLICKHOUSE_HOST:$CLICKHOUSE_HTTP_PORT") db=$CLICKHOUSE_DB
  Front workers:    $FRONT_SCALE
  Extra services:   ${EXTRA_PROFILES:-none}
EOF
(( DEVTOOLS )) && echo "  Devtools auth:    $DEVTOOLS_LOGIN / $DEVTOOLS_PASSWORD  (save this password!)"

ask_yn "Write .env with these settings?" y || { echo "Aborted, nothing written."; exit 1; }

sed \
  -e "s|^DOMAIN=.*|DOMAIN=$DOMAIN|" \
  -e "s|^EMAIL=.*|EMAIL=$EMAIL|" \
  -e "s|^FULLNAME=.*|FULLNAME=\"$FULLNAME\"|" \
  -e "s|^SSL_MODE=.*|SSL_MODE=$SSL_MODE|" \
  ${SSL_CERT:+-e "s|^SSL_CERT=.*|SSL_CERT=$SSL_CERT|"} \
  ${SSL_CERT_KEY:+-e "s|^SSL_CERT_KEY=.*|SSL_CERT_KEY=$SSL_CERT_KEY|"} \
  -e "s|^CLICKHOUSE_LOCAL=.*|CLICKHOUSE_LOCAL=$CLICKHOUSE_LOCAL|" \
  -e "s|^CLICKHOUSE_HOST=.*|CLICKHOUSE_HOST=$CLICKHOUSE_HOST|" \
  -e "s|^CLICKHOUSE_HTTP_PORT=.*|CLICKHOUSE_HTTP_PORT=$CLICKHOUSE_HTTP_PORT|" \
  -e "s|^CLICKHOUSE_USER=.*|CLICKHOUSE_USER=$CLICKHOUSE_USER|" \
  -e "s|^CLICKHOUSE_PASSWORD=.*|CLICKHOUSE_PASSWORD=$CLICKHOUSE_PASSWORD|" \
  -e "s|^CLICKHOUSE_RO_PASSWORD=.*|CLICKHOUSE_RO_PASSWORD=$CLICKHOUSE_RO_PASSWORD|" \
  -e "s|^CLICKHOUSE_DB=.*|CLICKHOUSE_DB=$CLICKHOUSE_DB|" \
  -e "s|^MEM_LIMIT_CLICKHOUSE=.*|MEM_LIMIT_CLICKHOUSE=$MEM_LIMIT_CLICKHOUSE|" \
  -e "s|^CPUS_CLICKHOUSE=.*|CPUS_CLICKHOUSE=$CPUS_CLICKHOUSE|" \
  -e "s|^MEM_LIMIT_REDIS=.*|MEM_LIMIT_REDIS=$MEM_LIMIT_REDIS|" \
  -e "s|^FRONT_SCALE=.*|FRONT_SCALE=$FRONT_SCALE|" \
  -e "s|^EXTRA_PROFILES=.*|EXTRA_PROFILES=$EXTRA_PROFILES|" \
  -e "s|^KAFKA_BROKERS=.*|KAFKA_BROKERS=$KAFKA_BROKERS|" \
  -e "s|^INFLUXDB_URL=.*|INFLUXDB_URL=$INFLUXDB_URL|" \
  -e "s|^INFLUXDB_TOKEN=.*|INFLUXDB_TOKEN=$INFLUXDB_TOKEN|" \
  -e "s|^INFLUXDB_ORG=.*|INFLUXDB_ORG=$INFLUXDB_ORG|" \
  -e "s|^INFLUXDB_BUCKET=.*|INFLUXDB_BUCKET=$INFLUXDB_BUCKET|" \
  -e "s|^DEVTOOLS_LOGIN=.*|DEVTOOLS_LOGIN=$DEVTOOLS_LOGIN|" \
  -e "s|^UI_PASSWORD=.*|UI_PASSWORD=$UI_PASSWORD|" \
  -e "s|^UI_SECRET=.*|UI_SECRET=$UI_SECRET|" \
  .env.example > .env
echo "  .env written."

##### prerequisites #####

if ! command -v docker >/dev/null; then
  if ask_yn "docker is not installed — run ./deploy.sh setup now (apt, needs sudo)?" y; then
    ./deploy.sh setup
  else
    echo "Install docker first (./deploy.sh setup), then re-run ./install.sh" >&2
    exit 1
  fi
fi
DOCKER=docker
docker info >/dev/null 2>&1 || DOCKER="sudo docker"

##### devtools basic_auth hash #####

if (( DEVTOOLS )); then
  say "Generating devtools password hash"
  IMAGE_CADDY=$(grep '^IMAGE_CADDY=' .env | cut -d= -f2)
  HASH=$($DOCKER run --rm "$IMAGE_CADDY" hash-password --plaintext "$DEVTOOLS_PASSWORD" | tr -d '\r\n')
  sed "s|^\( *\)[^ ]* \$2[aby]\$.*|\1$DEVTOOLS_LOGIN $HASH|" \
    configs/caddy/Caddyfile.tmpl > configs/caddy/Caddyfile.tmpl.new
  mv configs/caddy/Caddyfile.tmpl.new configs/caddy/Caddyfile.tmpl
  echo "  configs/caddy/Caddyfile.tmpl updated ($DEVTOOLS_LOGIN)."
fi

##### deploy #####

SUDO=""
[[ "$DOCKER" == sudo* ]] && SUDO="sudo"

say "Install plan"
echo "  1. $SUDO ./deploy.sh init        (preflight, dirs, networks, configs)"
[[ "$SSL_MODE" == letsencrypt ]] \
  && echo "  2. $SUDO ./deploy.sh cert-init   (Let's Encrypt certificate)" \
  || echo "  2. $SUDO ./deploy.sh cert-init   (start nginx with the existing certificate)"
echo "  3. $SUDO ./deploy.sh up          (start everything${EXTRA_PROFILES:+ + $EXTRA_PROFILES})"
echo "  4. $SUDO ./deploy.sh create-db   (databases: $CLICKHOUSE_DB, stats_ui)"

if ask_yn "Run it now?" y; then
  $SUDO ./deploy.sh init
  $SUDO ./deploy.sh cert-init
  $SUDO ./deploy.sh up
  $SUDO ./deploy.sh create-db
  say "Done"
  echo "  Platform:  https://$DOMAIN/"
  (( DEVTOOLS )) && echo "  Devtools:  https://$DOMAIN:2083/ui  /grafana/  /jupyter  (login: $DEVTOOLS_LOGIN)"
  [[ "$CLICKHOUSE_LOCAL" == 1 ]] && echo "  ClickHouse (chproxy): https://$DOMAIN:8443/"
else
  say "Next steps"
  echo "  $SUDO ./deploy.sh init && $SUDO ./deploy.sh cert-init && $SUDO ./deploy.sh up && $SUDO ./deploy.sh create-db"
fi
