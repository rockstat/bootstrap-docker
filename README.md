# Rockstat — docker-compose деплой (один хост)

Замена ansible-плейбука `../deploy.yml`. Вся конфигурация хоста — один файл
`.env`: домен, пароли, пути, лимиты памяти, количество front-воркеров.

## Структура

| Файл / папка | Назначение |
|---|---|
| `docker-compose.yml` | все сервисы платформы и devtools (опциональные — за profiles) |
| `deploy.sh` | установка зависимостей, preflight, каталоги, сети, рендер конфигов, генерация front-воркеров, SSL, запуск |
| `.env.example` | шаблон конфигурации хоста → скопировать в `.env` |
| `configs/` | шаблоны конфигов (`*.tmpl` рендерятся `envsubst` при `init`/`render`) |
| `configs/nginx/includes/` | опциональные сниппеты nginx (`cf_ips.conf` и т.п.), включаются в `location /` |
| `custom/` | кастомные конфиги сервисов front/chwriter/kafkastream (бывшие `templates/priv_<group>/`), копируются в каталоги данных |
| `compose.front.yml` | генерируется: front-воркеры + depends_on для nginx (в git не попадает) |
| `generated/common.env` | генерируется: общее окружение контейнеров (в git не попадает) |
| `data/`, `etc/` | данные и рендеренные конфиги — создаются при `init` (в git не попадают) |

Куда рендерятся конфиги:

- `configs/clickhouse/*` → `$DATA_DIR/clickhouse_config/`
- `configs/chproxy/config.yml.tmpl` → `$ETC_DIR/chproxy.yml`
- `configs/nginx/rockstat.conf.tmpl` → `$DATA_DIR/nginx/conf.d/rockstat.conf`
- `configs/telegraf/telegraf.conf.tmpl` → `$DATA_DIR/telegraf_config/telegraf.conf`
- `configs/caddy/Caddyfile.tmpl` → `$DATA_DIR/caddy_home/Caddyfile`
- `custom/front|chwriter|kafkastream/*.yml` → `$DATA_DIR/<service>_custom_config/`

## Быстрый старт

```bash
cd docker
./deploy.sh setup       # чистый хост: ставит docker, compose v2, envsubst (apt)
cp .env.example .env    # и отредактировать под хост
./deploy.sh init        # preflight + каталоги + сети + конфиги + front-воркеры
./deploy.sh cert-init   # Let's Encrypt сертификат (DNS домена должен указывать на хост)
./deploy.sh up          # ядро
./deploy.sh create-db   # дождаться ClickHouse и создать базу
```

После изменения `.env` или шаблонов: `./deploy.sh render && ./deploy.sh up`.

## Команды deploy.sh

| Команда | Что делает |
|---|---|
| `setup` | установка docker, docker compose v2, gettext-base, curl (apt); добавляет пользователя в группу docker. Не требует `.env` |
| `preflight` | проверки: docker/compose/envsubst/curl, доступ к docker-демону, обязательные переменные `.env`; предупреждает, если `MEM_LIMIT_CLICKHOUSE` > RAM хоста или DNS домена не совпадает с публичным IP. Выполняется автоматически перед `init`/`up`/`cert-init` |
| `init` | каталоги с chown, docker-сети `custom`/`dev`, рендер конфигов, `generated/common.env`, `compose.front.yml` |
| `render` | только перерендерить конфиги и перегенерировать front-файлы |
| `gen-front` | только перегенерировать front-воркеры и nginx upstream (после смены `FRONT_SCALE`) |
| `cert-init` | letsencrypt: первичное получение сертификата certbot'ом в standalone-режиме на :80, затем старт nginx+certbot (повторный запуск с существующим сертификатом просто поднимает их). custom: ничего не выпускает, стартует nginx с вашим сертификатом |
| `up [args]` | `docker compose up -d --pull always` + любые аргументы compose (`--profile`, имена сервисов) |
| `create-db` | ждёт ClickHouse (локальный или внешний — по `CLICKHOUSE_HOST`) и создаёт базы `$CLICKHOUSE_DB` и `stats_ui` (служебная база сервиса ui) |
| `compose <args>` | сырой `docker compose` с обоими файлами |
| `down / ps / logs / pull / stop / start / restart / config` | прокси в docker compose |

Запускать от root (`sudo ./deploy.sh ...`) или пользователем в группе docker
(root нужен и для `chown` каталогов данных на `PUID`/`PGID` при `init`).

Весь деплой самодостаточен: папка проекта содержит конфигурацию (`.env`,
шаблоны) и данные (`data/`, `etc/`) — бэкап или перенос на другой хост
= копия этой папки.

## Параметры .env

### Хост и идентификация

| Переменная | По умолчанию | Описание |
|---|---|---|
| `DOMAIN` | example.com | основной домен; используется в nginx, сертификате, caddy, env сервисов |
| `FULLNAME`, `EMAIL` | — | владелец; email также идёт в Let's Encrypt |
| `TZ` | UTC | таймзона контейнеров |
| `LOG_LEVEL` | info | уровень логов сервисов rockstat |
| `PUID` / `PGID` | 472 | uid/gid владельца каталогов данных (ansible: `_uid`/`_gid`) |

### Сети

| Переменная | По умолчанию | Описание |
|---|---|---|
| `DOCKER_NET_NAME` / `DOCKER_NET` | custom / 172.16.25.0/24 | основная сеть платформы (bridge-имя = имени сети) |
| `BIND_IP` | 172.16.25.1 | gateway основной сети; на него биндятся внутренние порты (ansible: `if_inner`) |
| `DOCKER_DEV_NET_NAME` / `DOCKER_DEV_NET` | dev / 172.16.26.0/24 | сеть devtools |

### Пути

По умолчанию все данные лежат **внутри папки проекта** (`./data`, `./etc`
рядом с `docker-compose.yml`; в git не попадают). Относительные пути
разрешаются от этой папки. Для хостов со старой ansible-раскладкой можно
указать прежние абсолютные пути.

| Переменная | По умолчанию | Описание |
|---|---|---|
| `DATA_DIR` / `ETC_DIR` | ./data, ./etc | данные и конфиги |
| `CLICKHOUSE_DATA_DIR` | ./data/clickhouse | данные ClickHouse (только при `CLICKHOUSE_LOCAL=1`) |
| `CLICKHOUSE_TMP_DIR` / `CLICKHOUSE_LOG_DIR` | ./data/clickhouse_tmp, ./data/clickhouse_log | tmp и логи CH (только локальный) |
| `REDIS_DATA_DIR` | ./data/redis | данные Redis |

### TLS

| Переменная | Описание |
|---|---|
| `SSL_MODE` | `letsencrypt` (по умолчанию) — сертификат получает и продлевает certbot; `custom` — используется **уже имеющийся** сертификат, certbot не разворачивается, порт 80 не занимается |
| `SSL_CERT` / `SSL_CERT_KEY` | файлы сертификата для nginx, chproxy и caddy. В режиме letsencrypt дефолт (`${DATA_DIR}/certbot/conf/live/${DOMAIN}/...`) править не нужно; в режиме `custom` укажите свои пути (fullchain + приватный ключ) |
| `LETSENCRYPT_STAGING` | `1` = staging CA Let's Encrypt для `cert-init` (тесты без rate-limit) |

В режиме `custom` preflight требует, чтобы файлы существовали, `cert-init`
ничего не выпускает (просто стартует nginx), а продление сертификата —
ваша забота: после замены файлов выполните
`./deploy.sh compose restart nginx` (и `restart chproxy`/`caddy`, если
они используются — они монтируют файл напрямую).

### ClickHouse (локальный или внешний)

| Переменная | По умолчанию | Описание |
|---|---|---|
| `CLICKHOUSE_LOCAL` | 1 | `1` — ClickHouse ставится локально (deploy.sh сам включает профиль `clickhouse`: контейнер, конфиги, каталоги); `0` — используется внешний сервер, локальный контейнер не запускается |
| `CLICKHOUSE_HOST` | 172.16.25.1 | адрес CH для всех сервисов (chwriter, chproxy, ui, create-db). Для локального — оставить равным `BIND_IP`; для внешнего — адрес сервера |
| `CLICKHOUSE_HTTP_PORT` | 8123 | http-порт CH |
| `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD` | default / default | основной пользователь (**сменить!**); для внешнего CH — его реальные креды |
| `CLICKHOUSE_RO_USER` / `CLICKHOUSE_RO_PASSWORD` | readonly / readonly | read-only пользователь (**сменить!**; для локального попадает в users.xml) |
| `CLICKHOUSE_DB` | stats | база, создаётся `create-db` |
| `MEM_LIMIT_CLICKHOUSE` | 32g | лимит памяти локального контейнера; ~50–70% RAM хоста, preflight предупредит о превышении |
| `CPUS_CLICKHOUSE` | 4 | лимит CPU локального контейнера |
| `MEM_LIMIT_REDIS` | 5g | лимит памяти Redis |

При `CLICKHOUSE_LOCAL=0` укажите внешние `CLICKHOUSE_HOST`/`CLICKHOUSE_HTTP_PORT`
и креды. Локальные clickhouse **и chproxy** в этом режиме не разворачиваются:
сервисы ходят во внешний CH напрямую (`CH_DSN` в `generated/common.env`
собирается без chproxy), `create-db` создаёт базы на внешнем сервере.
Preflight предупредит, если при `CLICKHOUSE_LOCAL=0` `CLICKHOUSE_HOST`
всё ещё равен `BIND_IP`.

### Front

| Переменная | По умолчанию | Описание |
|---|---|---|
| `FRONT_SCALE` | 5 | количество воркеров; каждый получает уникальный `WORKER_ID` |
| `FRONT_PORT_BASE` | 10001 | воркер i слушает на `BIND_IP:(FRONT_PORT_BASE + 2*i)` (для совместимости с внешним nginx; внутренний nginx ходит по именам контейнеров) |

### Kafka / Telegraf

| Переменная | Описание |
|---|---|
| `KAFKA_BROKERS` | список брокеров `host:9092,host:9092` — нужен профилям `kafkastream` |
| `INFLUXDB_URL` / `INFLUXDB_TOKEN` / `INFLUXDB_ORG` / `INFLUXDB_BUCKET` | куда telegraf пишет метрики — нужны профилю `telegraf` |

### Devtools

| Переменная | По умолчанию | Описание |
|---|---|---|
| `CADDY_PORT` | 2083 | https-порт caddy (вход в devtools) |
| `UI_PASSWORD` / `UI_SECRET` / `UI_PROJECTS` | — | сервис ui |
| `DEEPSEEK_API_KEY` / `AI_MODEL` / `AI_BASE_URL` | — / deepseek-chat / api.deepseek.com | AI-функции ui |

#### Логин и пароль caddy (basicauth)

Доступ ко всем devtools-маршрутам (`/grafana/`, `/jupyter`, `/ui`) закрыт
basicauth. Пользователи задаются **не в `.env`**, а прямо в
`configs/caddy/Caddyfile.tmpl` — bcrypt-хэш содержит `$`, который ломает
интерполяцию `.env` в docker compose:

```caddyfile
basic_auth /* bcrypt Private {
    user $2y$05$kxv3drnXqLGSBtD4bbKfYewbmasOkv7Oli3ZOYrF6WNGa9pIGXc8.
}
```

Формат строки — `<логин> <bcrypt-хэш>`, строк может быть несколько (по одной
на пользователя). Дефолтного пользователя `user` замените своим.

Полный путь — сгенерировать пароль, получить его хэш и подставить в конфиг:

```bash
# 1. сгенерировать пароль (или придумать свой) — сохраните его, в конфиг он не попадает
PASS=$(openssl rand -hex 12); echo "пароль: $PASS"

# 2. получить bcrypt-хэш пароля (без установки пакетов, тем же образом caddy)
docker run --rm lucaslorentz/caddy-docker-proxy:ci-alpine \
  hash-password --plaintext "$PASS"
# альтернатива: htpasswd -nbB user "$PASS" — из вывода взять ТОЛЬКО хэш
# после "user:" (сам логин с двоеточием не копировать!)

# 3. вписать строку "<логин> <хэш>" в блок basic_auth
#    в configs/caddy/Caddyfile.tmpl, заменив дефолтную:
#        user $2y$05$...ваш-хэш...

# 4. перерендерить конфиг и перезапустить caddy
./deploy.sh render
./deploy.sh compose --profile caddy restart caddy
```

В браузере вводятся логин из конфига и пароль из шага 1 (не хэш).

Логин авторизованного пользователя caddy пробрасывает сервисам заголовком
`X-WEBAUTH-USER` (сниппет `auth-headers`), поэтому grafana и ui логинят под
этим именем без собственных паролей.

### Образы

`IMAGE_*` — по одному на каждый сервис (front, chwriter, kafkastream,
chproxy, redis, clickhouse, caddy, jupyter, grafana, telegraf, mmgeo, ui,
nginx, certbot). Менять при обновлении версий; `up` всегда делает
`--pull always`.

⚠️ Не используйте `$` в значениях `.env` — docker compose интерполирует
env-файлы. Пароли скрипт не генерирует — задайте свои, например
`openssl rand -hex 12` (безопасно и без спецсимволов).

## Сервисы и профили

Ядро (запускается `./deploy.sh up` без аргументов):

| Сервис | Порты | Что это |
|---|---|---|
| nginx | 0.0.0.0:443 | публичный вход (только HTTPS), балансировка на front |
| certbot | 0.0.0.0:80 | выпуск/автопродление сертификата (standalone ACME; слушает 80 только в момент выпуска). Только при `SSL_MODE=letsencrypt` |
| front_1..N | BIND_IP:10003, 10005, … | приём событий |
| chwriter | — | запись событий в ClickHouse |
| redis | BIND_IP:6379 | шина/кэш |
| clickhouse | BIND_IP:8123 (http), 9000 (tcp) | хранилище; только при `CLICKHOUSE_LOCAL=1` (профиль `clickhouse` добавляется скриптом автоматически) |
| chproxy | 0.0.0.0:8443 | публичный https-доступ к локальному ClickHouse; разворачивается вместе с ним (тот же профиль `clickhouse`), при внешнем CH не нужен |

Дополнительные сервисы — через профили (бывшие ansible-теги):

| Профиль | Сервисы | Порты | Требует |
|---|---|---|---|
| `enrich` | mmgeo, uap, uapc | — | базы MaxMind в `$DATA_DIR/enrichers_dbs` |
| `ip2lgeo` | ip2lgeo | — | **файл базы IP2Location** в `$DATA_DIR/enrichers_dbs` — положить до запуска |
| `kafkastream` | kafkastream | — | `KAFKA_BROKERS` в .env |
| `telegraf` | telegraf | BIND_IP:8125/udp | `INFLUXDB_*` в .env |
| `devtools` | caddy, jupyter, grafana, ui | caddy 0.0.0.0:2083; jupyter BIND_IP:8888 | `CADDY_PORT`, basicauth в Caddyfile |
| имя сервиса | любой devtools-сервис по одному: `caddy`, `jupyter`, `grafana`, `ui` | | |

Запуск и остановка:

```bash
./deploy.sh up --profile enrich                  # ядро + энричеры
./deploy.sh up --profile ip2lgeo                 # + ip2lgeo (база уже в enrichers_dbs!)
./deploy.sh up --profile devtools                # + все devtools
./deploy.sh up --profile caddy --profile ui      # только caddy и ui из devtools
./deploy.sh up --profile kafkastream
./deploy.sh compose --profile telegraf up -d telegraf   # один сервис
./deploy.sh compose --profile devtools stop grafana
./deploy.sh compose --profile devtools down             # остановить и удалить devtools
./deploy.sh logs -f chwriter
./deploy.sh ps
```

Профиль надо указывать и при `logs`/`stop`/`down` для сервисов под профилем —
иначе compose их «не видит» (профиль `clickhouse` при `CLICKHOUSE_LOCAL=1`
скрипт добавляет во все команды сам).

Devtools доступны через caddy: `https://<домен>:2083/grafana/`, `/jupyter`,
`/ui` (basicauth из Caddyfile).

## Nginx и SSL

`nginx` — публичная точка входа, **только HTTPS (443)**: `location /`
балансируется на все `front_N` (`least_conn`, генерируемый
`upstream_front.conf`), `/public/` → `$DATA_DIR/public`.
Host-специфичные сниппеты (списки `set_real_ip_from` для Cloudflare и т.п.)
кладутся в `configs/nginx/includes/*.conf` и попадают в `location /`.
Порт 80 nginx не занимает — он закреплён за certbot, поэтому
`http://домен` не отвечает и редиректа на https нет (осознанное решение).

Сертификат (`SSL_MODE=letsencrypt`): `./deploy.sh cert-init` получает его
certbot'ом в standalone-режиме (certbot сам поднимает листенер на :80), после
чего стартуют nginx и certbot. Дальше контейнер `certbot` продлевает
сертификат сам (проверка каждые 12ч), nginx перечитывает его периодическим
reload (каждые 6ч). Для теста: `LETSENCRYPT_STAGING=1`.

Свой сертификат (`SSL_MODE=custom`): укажите файлы в `SSL_CERT`/`SSL_CERT_KEY`
— certbot не разворачивается, порт 80 остаётся свободен, nginx монтирует файлы
напрямую. После замены сертификата: `./deploy.sh compose restart nginx`.

⚠️ chproxy и caddy монтируют файл сертификата напрямую и после продления
требуют рестарта: `./deploy.sh restart chproxy` (nginx — нет).

## Масштабирование front

Каждому воркеру нужны уникальный `WORKER_ID` и свой порт, поэтому сервисы
`front_1..N` и nginx upstream генерируются скриптом. Изменить количество:

```bash
# поправить FRONT_SCALE в .env, затем
./deploy.sh gen-front
./deploy.sh up
./deploy.sh compose exec nginx nginx -s reload   # подхватить новый upstream
# при уменьшении: ./deploy.sh compose up -d --remove-orphans
```

## Миграция с ansible

- Старые пути данных задаются в `.env` — данные подхватятся как есть:
  `DATA_DIR=/srv/platform/data`, `ETC_DIR=/srv/platform/etc`,
  `CLICKHOUSE_DATA_DIR=/srv/clickhouse`, `CLICKHOUSE_TMP_DIR=/srv/clickhouse_tmp`,
  `CLICKHOUSE_LOG_DIR=/var/log/clickhouse-server`, `REDIS_DATA_DIR=/srv/redis`
  (и `SSL_CERT`/`SSL_CERT_KEY` на старые файлы). Либо остановить стек и
  перенести каталоги в папку проекта (`mv /srv/platform/data ./data` и т.д.).
- Сети `custom`/`dev` используются существующие (`external`), скрипт создаёт
  их только при отсутствии.
- Имена контейнеров совпадают со старыми, поэтому перед первым `up`
  ansible-контейнеры надо удалить: `docker rm -f <name>`.
- `pull: yes` + `recreate: yes` из ansible эквивалентны `up -d --pull always`
  (уже внутри `./deploy.sh up`).

## Типичные проблемы

- **`cert-init` падает** — DNS домена не указывает на хост (`preflight`
  предупреждает), порт 80 занят другим процессом или закрыт фаерволом,
  либо `EMAIL` невалидный (адреса на `example.com` Let's Encrypt отклоняет —
  preflight проверяет).
- **nginx в restart-loop "cannot load certificate"** — нет сертификата
  (не запускался `cert-init`). Запустить `./deploy.sh cert-init`.
- **ClickHouse убивается OOM** — `MEM_LIMIT_CLICKHOUSE` больше, чем есть
  памяти; preflight предупреждает.
- **`permission denied` к docker** — запускать `sudo ./deploy.sh ...` или
  перелогиниться после `setup` (группа docker).
- **compose ругается на `generated/common.env`** — не запускался
  `./deploy.sh init` (или `render`) после клонирования.
- **chproxy отдаёт старый сертификат после продления** — он монтирует файл
  напрямую; выполнить `./deploy.sh restart chproxy`.

## Лицензия

[Apache License 2.0](LICENSE).
