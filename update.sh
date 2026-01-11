#!/bin/bash
# Quick update script - pulls latest code and restarts services

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

echo "=========================================="
echo "Updating Forpost Stream"
echo "=========================================="
echo ""

# Check if we're in a git repository
if [ ! -d ".git" ]; then
    echo "ERROR: Not a git repository"
    exit 1
fi

# Function to restore stash on script interruption
restore_stash_on_interrupt() {
    if [ "$STASH_CREATED" = true ] && [ -f /tmp/strema_last_stash ]; then
        echo ""
        echo "🔄 Відновлюємо локальні зміни (переривання скрипту)..."
        if sudo -u "$SUDO_USER" git stash pop 2>/dev/null; then
            echo "✅ Локальні зміни відновлено"
        else
            echo "⚠️  Не вдалося відновити зміни автоматично"
            echo "💾 Зміни збережено в stash. Використайте 'git stash list' та 'git stash pop'"
        fi
        rm -f /tmp/strema_last_stash
    fi
}

# Set trap to restore stash on script interruption
trap restore_stash_on_interrupt INT TERM

# Step 1: Check for local changes and handle them
echo "[1/5] Checking for local changes..."
LOCAL_CHANGES=$(sudo -u "$SUDO_USER" git status --porcelain 2>/dev/null || true)
STASH_CREATED=false

if [ -n "$LOCAL_CHANGES" ]; then
    echo "⚠️  Виявлено локальні зміни:"
    echo "$LOCAL_CHANGES"
    echo ""
    
    # Check if we're in an interactive terminal
    if [ -t 0 ]; then
        read -p "Зберегти зміни та продовжити оновлення? (y/n): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Оновлення скасовано для збереження локальних змін"
            exit 0
        fi
    else
        echo "🔧 Автоматично зберігаємо зміни в stash (неінтерактивний режим)"
    fi
    
    # Create stash with unique name
    STASH_NAME="auto_update_$(date +%Y%m%d_%H%M%S)"
    echo "🔧 Зберігаємо локальні зміни в stash..."
    if sudo -u "$SUDO_USER" git stash push -m "$STASH_NAME" 2>/dev/null; then
        STASH_CREATED=true
        echo "✅ Зміни збережено в stash: $STASH_NAME"
        
        # Save stash info for potential manual recovery
        echo "$STASH_NAME" > /tmp/strema_last_stash
        echo "💾 Інформація про stash збережена в /tmp/strema_last_stash"
    else
        echo "❌ Не вдалося створити stash"
        echo "Будь ласка, збережіть зміни вручну і запустіть оновлення знову"
        exit 1
    fi
    echo ""
else
    echo "✅ Немає локальних змін"
    echo ""
fi

# Step 2: Pull latest changes
echo "[2/5] Pulling latest changes from git..."
if sudo -u "$SUDO_USER" git pull 2>/dev/null; then
    echo "✅ Код оновлено"
    echo ""
    
    # Step 3: Try to restore local changes if they were stashed
    if [ "$STASH_CREATED" = true ]; then
        echo "[3/5] Відновлюємо локальні зміни..."
        if sudo -u "$SUDO_USER" git stash pop 2>/dev/null; then
            echo "✅ Локальні зміни відновлено"
        else
            echo "⚠️  Не вдалося відновити зміни автоматично"
            echo "💾 Зміни збережено в stash. Використайте:"
            echo "   git stash list    # щоб побачити список stash"
            echo "   git stash pop    # щоб відновити останній stash"
            echo "   git stash drop   # щоб видалити stash якщо не потрібен"
        fi
        rm -f /tmp/strema_last_stash
        echo ""
    fi
else
    echo "❌ Помилка оновлення коду"
    
    # Provide helpful error information
    echo ""
    echo "🔍 Можливі причини:"
    echo "• Проблеми з мережею або доступом до GitHub"
    echo "• Конфлікти, які не вдалося вирішити автоматично"
    echo "• Проблеми з правами доступу до git репозиторію"
    
    if [ "$STASH_CREATED" = true ]; then
        echo ""
        echo "💾 Ваші локальні зміни збережено в stash"
        echo "   Використайте 'git stash list' для перегляду"
        echo "   Використайте 'git stash pop' для відновлення"
    fi
    
    echo ""
    echo "🔧 Рекомендовані дії:"
    echo "1. Перевірте мережеве з'єднання"
    echo "2. Спробуйте оновити вручну: git pull"
    echo "3. Якщо є конфлікти - вирішіть їх вручну"
    
    exit 1
fi

# Step 4: Check service status BEFORE install
echo "[4/7] Checking service status..."
if [ ! -f "$SCRIPT_DIR/scripts/service_manager.sh" ] && [ -f "$SCRIPT_DIR/scripts/service_manager.sh.template" ]; then
    cp "$SCRIPT_DIR/scripts/service_manager.sh.template" "$SCRIPT_DIR/scripts/service_manager.sh"
fi
source "$SCRIPT_DIR/scripts/service_manager.sh"
ACTIVE_SERVICES=$(get_active_services)
echo "Active services: ${ACTIVE_SERVICES:-none}"
echo ""

# Step 5: Run install script
echo "[5/7] Running install script..."
./install.sh 2>&1 | grep -v "^\[" || true
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "ERROR: install.sh failed"
    exit 1
fi
echo "✓ Installation completed"
echo ""

# Step 6: Restart web interface
echo "[6/7] Restarting web interface..."
systemctl restart forpost-stream-web
if [ $? -eq 0 ]; then
    echo "✓ Web interface restarted"
else
    echo "⚠ Failed to restart web interface"
fi
echo ""

# Step 7: Restart active services in correct order
echo "[7/7] Restarting active services..."
if [ -n "$ACTIVE_SERVICES" ]; then
    # Restart services in dependency order (proxy first, then stream)
    if echo "$ACTIVE_SERVICES" | grep -q "forpost-udp-proxy"; then
        echo "Restarting forpost-udp-proxy (dependency first)..."
        systemctl restart forpost-udp-proxy
    fi
    
    if echo "$ACTIVE_SERVICES" | grep -q "forpost-stream"; then
        echo "Restarting forpost-stream (depends on proxy)..."
        systemctl restart forpost-stream
    fi
    
    # Restart any other active services
    for service in $ACTIVE_SERVICES; do
        if [[ "$service" != "forpost-udp-proxy" && "$service" != "forpost-stream" ]]; then
            echo "Restarting $service..."
            systemctl restart "$service"
        fi
    done
else
    echo "No active services to restart"
fi

echo ""
echo "=========================================="
echo "Update complete!"
echo "=========================================="
echo ""

# Show current version
if [ -f "$SCRIPT_DIR/VERSION" ]; then
    VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
    echo "Current version: $VERSION"
fi

# Show web interface URL
IP_ADDRESS=$(hostname -I | awk '{print $1}')
echo "Web interface: http://$IP_ADDRESS:8081"
echo ""
