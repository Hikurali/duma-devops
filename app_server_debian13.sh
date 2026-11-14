#!/usr/bin/env bash
# Городская Дума — APP-SERVER bootstrap. Самодостаточный файл: исходники встроены ниже.
# Debian 13 (Trixie) без GUI, приложение без Docker, systemd + FastAPI + PostgreSQL на второй ВМ.
set -Eeuo pipefail

APP_IP="${APP_IP:-192.168.56.10}"
DB_IP="${DB_IP:-192.168.56.20}"
HOSTONLY_IF="${HOSTONLY_IF:-enp0s8}"
TARGET="/opt/gorod-duma"
ENV_DIR="/etc/gorod-duma"
ENV_FILE="$ENV_DIR/app.env"
SERVICE="/etc/systemd/system/gorod-duma.service"
log() { echo -e "\n[APP-SERVER] $*"; }
fail() { echo "[ОШИБКА] $*" >&2; exit 1; }
trap 'echo "[APP-SERVER] Сбой на строке $LINENO. Посмотрите сообщение выше и journalctl." >&2' ERR
[[ $EUID -eq 0 ]] || fail "Запусти с sudo: sudo bash app_server_debian13.sh"
. /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] || fail "Нужен Debian 13 (Trixie), обнаружено: ${PRETTY_NAME:-неизвестная ОС}"
[[ "$DB_IP" =~ ^[0-9.]+$ && "$APP_IP" =~ ^[0-9.]+$ ]] || fail "Неверный IPv4"
if [[ -f "$TARGET/.installed_by_duma_script" && "${REINSTALL:-0}" != "1" ]]; then
  fail "Проект уже установлен. Чтобы не затереть твои изменения, остановился. Проверка: sudo systemctl status gorod-duma. Для явной переустановки: sudo REINSTALL=1 bash app_server.sh"
fi

ensure_hostonly() {
  command -v ip >/dev/null 2>&1 || fail "Не найдена команда ip; на Debian 13 необходим пакет iproute2"
  ip link show "$HOSTONLY_IF" >/dev/null 2>&1 || fail "Не найден интерфейс $HOSTONLY_IF. Проверь адаптер Host-only через 'ip -br a' и передай HOSTONLY_IF=имя."

  local this_ip="${THIS_IP}" current_conf
  # Конфликтующий адрес нельзя бездумно перезаписывать: это может оборвать SSH.
  current_conf=$(ip -o -4 addr show dev "$HOSTONLY_IF" | awk '{print $4}')
  if [[ -n "$current_conf" && "$current_conf" != "${this_ip}/24" ]]; then
    ip -br -4 addr show dev "$HOSTONLY_IF"
    fail "На $HOSTONLY_IF уже стоит другой IP ($current_conf). Нужен ${this_ip}/24; сначала проверь DHCP Host-only или настройки этой ВМ."
  fi

  if systemctl is-active --quiet NetworkManager && command -v nmcli >/dev/null 2>&1; then
    if nmcli -g GENERAL.STATE device show "$HOSTONLY_IF" 2>/dev/null | grep -qE '^100'; then
      if [[ "$current_conf" == "${this_ip}/24" ]]; then
        log "Интерфейс $HOSTONLY_IF уже настроен NetworkManager: $current_conf"
        return
      fi
      fail "NetworkManager управляет $HOSTONLY_IF. Назначь ${this_ip}/24 через nmcli; скрипт не будет перезаписывать профиль NM."
    fi
  fi

  # Если IP уже правильно настроен — не трогаем чужую сетевую конфигурацию.
  if [[ "$current_conf" == "${this_ip}/24" ]]; then
    log "Host-only интерфейс $HOSTONLY_IF уже имеет ${this_ip}/24 — оставляю существующую настройку"
    return
  fi

  # Debian 13 без GUI: системные сети могут обслуживаться systemd-networkd либо ifupdown.
  if systemctl is-active --quiet systemd-networkd; then
    log "Настраиваю Host-only через systemd-networkd, не трогая NAT"
    mkdir -p /etc/systemd/network
    local config="/etc/systemd/network/05-gorod-duma-${HOSTONLY_IF}.network"
    [[ ! -e "$config" ]] || cp -a "$config" "${config}.backup-gorod-duma"
    cat > "$config" <<NETWORK
[Match]
Name=${HOSTONLY_IF}

[Network]
Address=${this_ip}/24
LinkLocalAddressing=no
NETWORK
    chmod 644 "$config"
    networkctl reload
    networkctl reconfigure "$HOSTONLY_IF" || true
  elif command -v ifup >/dev/null 2>&1 && [[ -f /etc/network/interfaces ]]; then
    # Не допускаем дублирования интерфейса в конфигурации ifupdown.
    if { grep -Eq "^[[:space:]]*iface[[:space:]]+${HOSTONLY_IF}[[:space:]]" /etc/network/interfaces \
       || { [[ -d /etc/network/interfaces.d ]] && grep -hREq "^[[:space:]]*iface[[:space:]]+${HOSTONLY_IF}[[:space:]]" /etc/network/interfaces.d/; }; }; then
      fail "В ifupdown уже описан $HOSTONLY_IF, но IP не поднят. Проверь /etc/network/interfaces и /etc/network/interfaces.d/."
    fi
    log "Настраиваю Host-only через Debian ifupdown, не трогая NAT"
    cp -a /etc/network/interfaces /etc/network/interfaces.backup-gorod-duma
    # Записываем в основной файл: Debian может не подключать interfaces.d автоматически.
    cat >> /etc/network/interfaces <<NETWORK

# BEGIN GOROD-DUMA HOST-ONLY
# Выделенный интерфейс VirtualBox Host-only (без gateway и DNS)
auto ${HOSTONLY_IF}
iface ${HOSTONLY_IF} inet static
    address ${this_ip}/24
# END GOROD-DUMA HOST-ONLY
NETWORK
  else
    # Если ifupdown не установлен, используем networkd только на Host-only интерфейсе.
    if systemctl is-active --quiet NetworkManager; then
      fail "Активен NetworkManager, сеть не изменена. Настрой ${this_ip}/24 на $HOSTONLY_IF вручную."
    fi
    log "Настраиваю systemd-networkd только для Host-only ($HOSTONLY_IF)"
    mkdir -p /etc/systemd/network
    cat > "/etc/systemd/network/05-gorod-duma-${HOSTONLY_IF}.network" <<NETWORK
[Match]
Name=${HOSTONLY_IF}
