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
    printf "\n"
    if menu_confirm "Применить показанный diff? [y/N]:"; then
      generate_configs
    else
      log_info "Отмена (живые файлы не тронуты)"
    fi
  fi
  menu_pause
}
