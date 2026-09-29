#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../ui/menu.sh"

show_menu() {
  trap 'exit 0' INT
  while true; do
    clear_screen
    print_header "БЭКАПЫ" "💾"
    printf "  Каталог: ${CYAN}%s${NC} (держим последние %s)\n\n" "${BACKUP_DIR}" "$BACKUP_KEEP"
    local i=0
    local names=()
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      i=$((i + 1))
      names+=("$line")
      printf "  ${GREEN}%d.${NC} %s\n" "$i" "$line"
    done < <(list_backups)
    if [ "$i" -eq 0 ]; then
      printf "  ${YELLOW}(пока пусто — бэкапы создаются при save/generate/rollback)${NC}\n"
    fi
    printf "\n"
    printf "  ${GREEN}r.${NC} ↩️  Откатить к бэкапу (по номеру)\n"
    printf "  ${GREEN}?.${NC} ❓ Шпаргалка\n"
    printf "  ${RED}0.${NC} ⬅️  Назад\n"
    printf "\n"
    printf "${CYAN}👉 Пункт:${NC} "
    read -r choice < /dev/tty

    case "$choice" in
      0) exit 0 ;;
      r|R)
        if [ "$i" -eq 0 ]; then
          log_error "❌ Нечего откатывать"
          sleep 1
          continue
        fi
        printf "  ${CYAN}👉 Номер бэкапа:${NC} "
        read -r num < /dev/tty
        if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$i" ]; then
          log_error "❌ Нет такого номера"
          sleep 1
          continue
        fi
        local target="${names[$((num - 1))]}"
        printf "  ${YELLOW}⚠  Откатить sites.conf + оба haproxy.cfg к %s? [y/N]:${NC} " "$target"
        read -r ans < /dev/tty
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
          if rollback_backup "$target"; then
            log_warn "  ⚠  Не забудь перезапустить сервисы (п.5 главного меню), если конфиги уже применялись"
          fi
        else
          log_info "Отмена"
        fi
        printf "\n"
        menu_pause
        ;;
      ?) print_cheatsheet || true ;;
      *) menu_invalid; continue ;;
    esac
  done
}

show_menu
