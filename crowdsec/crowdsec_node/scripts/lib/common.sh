# shellcheck shell=bash
# Общие утилиты для скриптов CrowdSec Node Manager

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- ОЧИСТКА ЭКРАНА ---
clear_screen() {
  tput clear 2>/dev/null || true
}

# --- ЛОГГЕРЫ ---
log_info()  { printf "${GREEN}%s${NC}\n" "$*"; }
log_warn()  { printf "${YELLOW}%s${NC}\n" "$*"; }
log_error() { printf "${RED}%s${NC}\n" "$*"; }
die()       { log_error "$*"; exit 1; }

# --- ШАПКИ МЕНЮ ---
print_header() {
  local title="$1"
  local icon="${2:-🛠️}"
  printf "${CYAN}┌─────────────────────────────────────────────┐${NC}\n"
  printf "${CYAN}│  ${icon}  %-37s│${NC}\n" "$title"
  printf "${CYAN}└─────────────────────────────────────────────┘${NC}\n"
  printf "\n"
}

# --- ПРОВЕРКА ЗАВИСИМОСТЕЙ ---
require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [ -n "$hint" ]; then
      die "❌ $cmd не найден. $hint"
    else
      die "❌ $cmd не найден. Установи: apt install $cmd"
    fi
  fi
}

# --- PREFLIGHT ПРОВЕРКА ЛОГОВ ХОСТА ---
# Проверяет ОС (Debian/Ubuntu), ставит rsyslog при отсутствии,
# чинит директории-заглушки от Docker и создаёт файлы логов.
# Идемпотентна: повторный прогон ничего не ломает.
# Использование: ensure_host_logs [compose_dir]
_host_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    printf ""
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    printf "sudo"
    return 0
  fi
  return 1
}

ensure_host_logs() {
  local compose_dir="${1:-}"
  local sudo_prefix=""
  local f=""

  # --- 1. ОС: любой Debian / Ubuntu ---
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
      *"debian"*|*"ubuntu"*)
        log_info "  ✅ ОС: ${PRETTY_NAME:-${ID:-unknown}}"
        ;;
      *)
        die "❌ Нужен Debian или Ubuntu, сейчас: ${PRETTY_NAME:-${ID:-unknown}}. Установи rsyslog и файлы логов вручную."
        ;;
    esac
  else
    log_warn "  ⚠️  /etc/os-release не найден, пропускаю проверку ОС"
  fi

  # --- 2. rsyslog: установить при отсутствии ---
  local rsyslog_ok=0
  if command -v dpkg >/dev/null 2>&1 && dpkg -s rsyslog >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      if [ "$(systemctl is-active rsyslog 2>/dev/null || true)" = "active" ]; then
        rsyslog_ok=1
      fi
    else
      rsyslog_ok=1
    fi
  fi
  if [ "$rsyslog_ok" = "1" ]; then
    log_info "  ✅ rsyslog установлен и активен"
  else
    log_warn "  ⚠️  rsyslog отсутствует, устанавливаю..."
    require_cmd apt-get "Установи rsyslog вручную: apt install rsyslog"
    if ! sudo_prefix="$(_host_sudo)"; then
      die "❌ Нужны root-права для установки rsyslog. Запусти под root или поставь sudo: apt install sudo"
    fi
    if [ -n "$sudo_prefix" ]; then
      $sudo_prefix apt-get update && $sudo_prefix apt-get install -y rsyslog
    else
      apt-get update && apt-get install -y rsyslog
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      if [ -n "$sudo_prefix" ]; then
        $sudo_prefix systemctl enable --now rsyslog || die "❌ Не удалось запустить rsyslog"
      else
        systemctl enable --now rsyslog || die "❌ Не удалось запустить rsyslog"
      fi
    elif command -v service >/dev/null 2>&1; then
      if [ -n "$sudo_prefix" ]; then
        $sudo_prefix service rsyslog start || true
      else
        service rsyslog start || true
      fi
    fi
    log_info "  ✅ rsyslog установлен"
  fi

  # --- 3. sudo для работы с /var/log ---
  if ! sudo_prefix="$(_host_sudo)"; then
    die "❌ Нужны root-права для /var/log. Запусти под root или поставь sudo."
  fi

  # --- 4. compose-файл для down перед удалением заглушек ---
  local compose_file=""
  if [ -n "$compose_dir" ] && [ -f "$compose_dir/compose.yml" ]; then
    compose_file="$compose_dir/compose.yml"
  elif [ -n "$compose_dir" ] && [ -f "$compose_dir/compose.yaml" ]; then
    compose_file="$compose_dir/compose.yaml"
  fi

  # --- 5. Чиним заглушки и создаём файлы ---
  local need_restart=0
  for f in /var/log/auth.log /var/log/syslog /var/log/kern.log; do
    if [ -d "$f" ] && [ ! -L "$f" ]; then
      log_warn "  ⚠️  $f — директория-заглушка от Docker, чиню..."
      if [ -n "$compose_file" ] && command -v docker >/dev/null 2>&1; then
        (cd "$compose_dir" && docker compose down >/dev/null 2>&1) || true
      fi
      # Удаляем ТОЛЬКО пустую директорию, непустую не трогаем
      if [ -n "$sudo_prefix" ]; then
        if ! $sudo_prefix rmdir "$f" 2>/dev/null; then
          die "❌ $f — непустая директория. Разбери вручную и повтори."
        fi
        $sudo_prefix touch "$f" && $sudo_prefix chmod 644 "$f"
      else
        if ! rmdir "$f" 2>/dev/null; then
          die "❌ $f — непустая директория. Разбери вручную и повтори."
        fi
        touch "$f" && chmod 644 "$f"
      fi
      need_restart=1
      log_info "  ✅ $f — заглушка удалена, файл создан"
    elif [ ! -e "$f" ]; then
      log_warn "  ⚠️  $f отсутствует, создаю..."
      if [ -n "$sudo_prefix" ]; then
        $sudo_prefix touch "$f" && $sudo_prefix chmod 644 "$f"
      else
        touch "$f" && chmod 644 "$f"
      fi
      need_restart=1
      log_info "  ✅ $f создан"
    elif [ ! -f "$f" ]; then
      die "❌ $f — не обычный файл. Разбери вручную и повтори."
    fi
    if [ ! -r "$f" ]; then
      die "❌ $f нечитаем. Проверь права."
    fi
  done

  # --- 6. Перезапуск rsyslog чтобы начал писать ---
  if [ "$need_restart" = "1" ]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      if [ -n "$sudo_prefix" ]; then
        $sudo_prefix systemctl restart rsyslog >/dev/null 2>&1 || true
      else
        systemctl restart rsyslog >/dev/null 2>&1 || true
      fi
      sleep 3
    fi
  fi

  # --- 7. Предупреждение о старом compose.yml с файловыми маунтами ---
  if [ -n "$compose_file" ] && grep -q "/var/log/auth.log:" "$compose_file" 2>/dev/null; then
    log_warn "  ⚠️  compose.yml содержит старые файловые маунты /var/log/*.log."
    log_warn "  ⚠️  Обнови из шаблона: cp compose-example.yml compose.yml (сохрани свои правки путей!)"
  fi

  log_info "  ✅ Логи хоста в порядке"
}

# Лёгкая проверка для экрана статуса (ничего не ставит и не чинит)
host_logs_status() {
  local f=""
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf "  ОС: %s\n" "${PRETTY_NAME:-${ID:-unknown}}"
  fi
  if command -v dpkg >/dev/null 2>&1 && dpkg -s rsyslog >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      printf "  rsyslog: %s\n" "$(systemctl is-active rsyslog 2>/dev/null || echo unknown)"
    else
      printf "  rsyslog: установлен\n"
    fi
  else
    printf "  rsyslog: НЕ УСТАНОВЛЕН\n"
  fi
  for f in /var/log/auth.log /var/log/syslog /var/log/kern.log; do
    if [ -d "$f" ] && [ ! -L "$f" ]; then
      printf "  %s: ДИРЕКТОРИЯ-ЗАГЛУШКА (нужен preflight)\n" "$f"
    elif [ -f "$f" ]; then
      printf "  %s: OK\n" "$f"
    else
      printf "  %s: ОТСУТСТВУЕТ\n" "$f"
    fi
  done
}
