#!/bin/bash
# Shim: команда переехала в commands/cert.sh (оставлен для совместимости).
# shellcheck disable=SC1091
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${HERE}/commands/cert.sh" "$@"
