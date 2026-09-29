#!/bin/bash
# shellcheck shell=bash
# UI: перегенерация с diff-превью (бывший инлайн п.8 haproxy.sh).
# Зависимости: common.sh (load_sites/preview_configs/generate_configs),
#   ui/menu.sh (menu_confirm/menu_pause).

# cmd_regen — показать diff живые vs сгенерированные, спросить подтверждение.
cmd_regen() {
  if [ ! -f "$SITES_CONF" ]; then
    log_error "❌ sites.conf не найден"
    menu_pause
    return 0
  fi
  load_sites
  printf "\n"
  preview_configs
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    log_info "✅ Перегенерировать нечего — живые конфиги совпадают"
  elif [ "$rc" -eq 2 ]; then
    log_error "❌ Предпросмотр не удался — чиним sites.conf и повторяем"
  else
    # Детектор сноса: живые SNI-правила есть, а в новых нет (кейс stream-vision
    # поверх xray-direct и наоборот) — требуем явное ДА вместо y.
    local live_stream="${HAPROXY_DIR}/stream/haproxy.cfg"
    if grep -q 'req\.ssl_sni -i' "$live_stream" 2>/dev/null; then
      local tmpd
      tmpd=$(mktemp -d)
      if generate_stream_config > "$tmpd/stream.cfg" 2>/dev/null \
        && ! grep -q 'req\.ssl_sni -i' "$tmpd/stream.cfg" 2>/dev/null; then
        printf "  ${RED}❌ ВНИМАНИЕ: новая генерация сносит ВСЕ SNI-правила stream (см. diff выше).${NC}\n"
        printf "  ${RED}   Для подтверждения введи ДА:${NC} "
        local wipe
        tread -r wipe || wipe=""
        rm -rf "$tmpd"
        if [ "$wipe" != "ДА" ]; then log_info "Отмена (живые файлы не тронуты)"; menu_pause; return 0; fi
        printf "\n"
      else
        rm -rf "$tmpd"
      fi
    fi
    printf "\n"
    local vflag
    vflag=$(ask_validate)
    if menu_confirm "Применить показанный diff? [y/N]:"; then
      if [ -z "$vflag" ]; then
        generate_configs
      else
        generate_configs "$vflag"
      fi
    else
      log_info "Отмена (живые файлы не тронуты)"
    fi
  fi
  menu_pause
}
