#!/bin/bash
# Shim: команда переехала в commands/preset.sh (оставлен для совместимости).
# shellcheck disable=SC1091
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${HERE}/commands/preset.sh" "$@"
