#!/usr/bin/env bash
# Городская Дума — PostgreSQL для Debian 13, DB-SERVER без Docker.
# Предполагается, что Host-only IP уже настроен в /etc/network/interfaces.
set -Eeuo pipefail
trap 'echo "ОШИБКА: установка остановлена на строке $LINENO" >&2' ERR

DB_IP="${DB_IP:-192.168.56.20}"
APP_IP="${APP_IP:-192.168.56.10}"
NET_IF="${HOSTONLY_IF:-enp0s8}"
DB_NAME=gorod_duma
DB_USER=duma_app
SECRETS=/root/gorod-duma-db-credentials.txt

[[ "$(id -u)" == 0 ]] || { echo 'Запусти: sudo bash db_server_debian13_fixed.sh' >&2; exit 1; }
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || { echo 'Этот файл только для Debian 13' >&2; exit 1; }
if ! ip -4 -o addr show dev "$NET_IF" 2>/dev/null | grep -Fq "${DB_IP}/24"; then
  echo "На $NET_IF нет адреса ${DB_IP}/24. Сначала проверь: ip -br a" >&2
  exit 1
fi

echo '[1/5] Установка PostgreSQL...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y postgresql postgresql-client openssl
systemctl enable --now postgresql

echo '[2/5] Подготовка учётных данных...'
if [[ -f "$SECRETS" ]]; then
  DB_PASSWORD="$(sed -n 's/^DB_PASSWORD=//p' "$SECRETS" | head -n 1)"
  [[ "$DB_PASSWORD" =~ ^[a-f0-9]{48}$ ]] || { echo 'Некорректный сохранённый пароль БД' >&2; exit 1; }
else
  DB_PASSWORD="$(openssl rand -hex 24)"
  (umask 077; printf 'DB_HOST=%s\nDB_PORT=5432\nDB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\n' \
    "$DB_IP" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" > "$SECRETS")
fi

echo '[3/5] Создание роли и базы данных...'
if [[ "$(runuser -u postgres -- psql -XAtqc "SELECT count(*) FROM pg_roles WHERE rolname='${DB_USER}'")" == 0 ]]; then
  runuser -u postgres -- psql -Xv ON_ERROR_STOP=1 -c "CREATE ROLE ${DB_USER} LOGIN"
fi
printf "SET password_encryption='scram-sha-256'; ALTER ROLE %s LOGIN PASSWORD '%s';\n" \
  "$DB_USER" "$DB_PASSWORD" | runuser -u postgres -- psql -Xv ON_ERROR_STOP=1
if [[ "$(runuser -u postgres -- psql -XAtqc "SELECT count(*) FROM pg_database WHERE datname='${DB_NAME}'")" == 0 ]]; then
  runuser -u postgres -- createdb --owner="$DB_USER" "$DB_NAME"
fi
runuser -u postgres -- psql -Xv ON_ERROR_STOP=1 -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER}"

echo '[4/5] Разрешение подключений только с APP-SERVER...'
runuser -u postgres -- psql -Xv ON_ERROR_STOP=1 -c \
  "ALTER SYSTEM SET listen_addresses TO 'localhost,${DB_IP}'"
HBA="$(runuser -u postgres -- psql -XAtqc 'SHOW hba_file')"
[[ -f "$HBA" ]] || { echo "Не найден pg_hba.conf: $HBA" >&2; exit 1; }
if ! grep -Fq '# BEGIN GOROD-DUMA' "$HBA"; then
  cp -a "$HBA" "${HBA}.backup-gorod-duma"
else
  sed -i '/# BEGIN GOROD-DUMA/,/# END GOROD-DUMA/d' "$HBA"
fi
printf '\n# BEGIN GOROD-DUMA\nhost    %s    %s    %s/32    scram-sha-256\n# END GOROD-DUMA\n' \
  "$DB_NAME" "$DB_USER" "$APP_IP" >> "$HBA"

printf '[5/5] Перезапуск PostgreSQL и проверка...\n'
systemctl restart postgresql
pg_isready -h "$DB_IP" -p 5432

echo '============================================='
echo "Готово: DB-SERVER ${DB_IP}:5432"
echo "База: ${DB_NAME}; пользователь: ${DB_USER}"
echo "Пароль: ${DB_PASSWORD}"
echo "Дубликат пароля: ${SECRETS} (доступен только root)"
echo 'Следующий шаг: установить приложение на APP-SERVER.'
echo '============================================='
