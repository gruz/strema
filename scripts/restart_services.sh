#!/bin/bash

# Script for restarting FORPOST services
# Usage: ./restart_services.sh [stream|web|udp|dzyga|watchdog|all]

# Don't use set -e — we handle errors explicitly per service
# set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

restart_service() {
    local service="$1"
    local svc_type
    svc_type=$(systemctl show "$service" --property=Type --value 2>/dev/null)

    if [ "$svc_type" = "oneshot" ]; then
        log_info "Запуск $service (oneshot)..."
        if sudo systemctl start "$service" 2>/dev/null; then
            log_info "$service успішно запущено"
        else
            log_error "$service не вдалося запустити (oneshot — це моніторинговий скрипт, може бути не налаштований)"
        fi
        return
    fi

    if systemctl is-active --quiet "$service" 2>/dev/null; then
        log_info "Перезавантаження $service..."
        sudo systemctl restart "$service"
        if systemctl is-active --quiet "$service"; then
            log_info "$service успішно перезавантажено"
        else
            log_error "$service не запустився після перезавантаження"
        fi
    else
        log_warn "$service не був активний, запускаємо..."
        sudo systemctl start "$service"
        if systemctl is-active --quiet "$service"; then
            log_info "$service успішно запущено"
        else
            log_error "$service не вдалося запустити"
        fi
    fi
}

show_help() {
    echo "Використання: $(basename "$0") [команда]"
    echo ""
    echo "Команди:"
    echo "  stream    Перезавантажити сервіс стріму (forpost-stream)"
    echo "  web       Перезавантажити веб-інтерфейс (forpost-stream-web)"
    echo "  udp       Перезавантажити UDP-проксі (forpost-udp-proxy)"
    echo "  dzyga     Перезавантажити монітор Dzyga (forpost-dzyga-monitor)"
    echo "  watchdog  Перезавантажити watchdog (forpost-stream-watchdog)"
    echo "  all       Перезавантажити всі сервіси"
    echo "  help      Показати цю довідку"
    echo ""
    echo "Приклади:"
    echo "  $(basename "$0") stream   # тільки стрім"
    echo "  $(basename "$0") web      # тільки веб"
    echo "  $(basename "$0") all      # все"
}

CMD="${1:-help}"

case "$CMD" in
    stream)
        restart_service "forpost-stream"
        ;;
    web)
        restart_service "forpost-stream-web"
        ;;
    udp)
        restart_service "forpost-udp-proxy"
        ;;
    dzyga)
        restart_service "forpost-dzyga-monitor"
        ;;
    watchdog)
        restart_service "forpost-stream-watchdog"
        ;;
    all)
        log_info "Перезавантаження всіх сервісів..."
        # Correct order: oneshot first, then udp-proxy (before stream),
        # then stream (depends on udp-proxy), then watchdog (after stream),
        # finally web (independent)
        restart_service "forpost-dzyga-monitor"
        restart_service "forpost-udp-proxy"
        restart_service "forpost-stream"
        restart_service "forpost-stream-watchdog"
        restart_service "forpost-stream-web"
        log_info "Готово."
        ;;
    help|--help|-h|""|*)
        show_help
        exit 0
        ;;
esac
