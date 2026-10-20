# CLAUDE.md

Rockstat — single-host docker-compose деплой аналитической платформы.
Репозиторий: `github.com/rockstat/bootstrap-docker`. Сделан как замена
ansible-плейбука из соседнего репо `bootstrap_lite` (эта папка — вложенный
git-репозиторий внутри него).

## Устройство

- **`deploy.sh` — единственная точка входа**: `setup` (зависимости на чистый
  Ubuntu), `preflight`, `init`, `cert-init`, `up`, `create-db`, `render`,
  `gen-front`, `compose <args>` и прокси `down/ps/logs/...`. Перед
  `init`/`up`/`cert-init` автоматически выполняется `preflight`.
- **`.env` — вся конфигурация хоста** (копия `.env.example`). Данные и
  рендеренные конфиги — в `./data` и `./etc` рядом с compose-файлом
  (старые ansible-хосты могут указать `/srv/...` пути в `.env`).
- **Генерируемые файлы** (в git не попадают): `compose.front.yml`
  (front-воркеры + depends_on nginx), `generated/common.env` (общее окружение
  контейнеров), `data/nginx/conf.d/upstream_front.conf`, все `data/*` конфиги
  из `configs/*.tmpl` (рендер `envsubst` с явным списком переменных).
- **Front масштабируется генерацией**: каждому воркеру нужен уникальный
  `WORKER_ID` и порт `BIND_IP:(FRONT_PORT_BASE + 2*i)` — compose-репликами
  это не сделать. Смена `FRONT_SCALE` → `gen-front` → `up` → reload nginx.
- **ClickHouse опционален**: `CLICKHOUSE_LOCAL=1` — deploy.sh сам добавляет
  `--profile clickhouse` во все compose-команды; `0` — внешний сервер через
  `CLICKHOUSE_HOST`/`CLICKHOUSE_HTTP_PORT`. `create-db` создаёт
  `$CLICKHOUSE_DB` **и** `stats_ui` (служебная база сервиса ui).
- **SSL**: nginx+certbot, вход через `cert-init` (временный self-signed →
  webroot ACME → reload; при ошибке dummy восстанавливается). chproxy и caddy
  монтируют файл сертификата напрямую — после продления нужен их restart.
  `SSL_CERT`/`SSL_CERT_KEY` выводятся из `${DATA_DIR}`/`${DOMAIN}` — обе
  подстановки работают и в compose, и при `source .env` в bash.

## Грабли (не наступать повторно)

- **`$` в значениях `.env` запрещён** — compose интерполирует env-файлы.
  Поэтому bcrypt-хэш basic_auth живёт в `configs/caddy/Caddyfile.tmpl`,
  а не в `.env`. Пароли генерировать `openssl rand -hex 12`.
- **Несуществующий файл в bind-mount docker молча превращает в каталог** —
  caddy/chproxy падают с `is a directory`. Preflight это проверяет.
- Строка пользователя caddy — `логин хэш` (пробел!). Вывод `htpasswd -nB` —
  `логин:хэш`; если вставить как есть после логина, caddy падает с
  `base64-decoding password: illegal base64 data`. Директива — `basic_auth`
  (не `basicauth`, deprecated с Caddy 2.8).
- `docker compose` принимает `--profile` только ДО подкоманды; `deploy.sh up`
  сам переставляет. Для `logs/stop/down` сервисов под профилем профиль
  обязателен: `./deploy.sh compose --profile devtools logs grafana`.
- ui требует базу `stats_ui` (ошибка `UNKNOWN_DATABASE code 81`, страница
  «This page couldn't load») — создаётся в `create-db`.
- Лимиты памяти в `.env` надо подгонять под хост (preflight предупреждает,
  если `MEM_LIMIT_CLICKHOUSE` > RAM).

## Проверка изменений

```bash
bash -n deploy.sh
# тестовый .env + заглушки, затем:
docker compose -f docker-compose.yml -f compose.front.yml \
  --profile clickhouse --profile enrich --profile ip2lgeo \
  --profile kafkastream --profile telegraf --profile devtools config --quiet
```

После правки шаблонов nginx — `docker run --rm ... nginx:1.27-alpine nginx -t`
с смонтированными рендерами (нужен dummy-сертификат и `--add-host front_N`).
