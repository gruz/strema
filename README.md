# FORPOST Stream

Трансляція відео з пристрою DZYGA на RTMP сервер з динамічним оверлеєм частоти.

## 🚀 Швидке встановлення

**Одна команда через SSH:**

```bash
curl -fsSL https://raw.githubusercontent.com/gruz/strema/master/install.sh | bash
```

Після встановлення в консолі з'явиться посилання на веб-інтерфейс:
```
🌐 Web Interface: http://192.168.1.X:8081
```

**⚠️ ВАЖЛИВО:** Стрімінг за замовчуванням **ВИМКНЕНИЙ**. Увімкніть його через веб-інтерфейс.

> **Примітка:** За замовчуванням встановлюється останній стабільний реліз.

---

## 📦 Альтернативні способи встановлення

### Стабільна версія (реліз)
```bash
curl -fsSL https://raw.githubusercontent.com/gruz/strema/master/install.sh | bash -s v0.1.0
```

### Останній код з master (для тестування)
```bash
curl -fsSL https://raw.githubusercontent.com/gruz/strema/master/install.sh | bash -s master
```

### Для розробників (з git)
```bash
git clone https://github.com/gruz/strema.git
cd strema
sudo ./install.sh
```

> **Примітка:** Встановлення завжди відбувається в `~/strema` (домашня тека поточного користувача)

---

## 🔄 Оновлення

### Через веб-інтерфейс
1. Відкрийте http://IP:8081
2. Розділ "🔄 Оновлення системи"
3. Оберіть версію → "Оновити"

### Через CLI
```bash
curl -fsSL https://raw.githubusercontent.com/gruz/strema/master/install.sh | bash -s v0.1.1
```

---

## ⚙️ Веб-інтерфейс

Після встановлення відкрийте у браузері:
```
http://[IP-адреса]:8081
```

**Можливості:**
- 🎬 Керування трансляцією (старт/стоп)
- ⚙️ Налаштування якості відео
- 📝 Оверлей тексту та частоти
- 🔄 Автоматичні оновлення
- 📊 Режими роботи при скануванні

## Логи

Якщо виникли проблеми, перегляньте логи:

```bash
# Логи трансляції
tail -f logs/stream.log

# Системні логи
sudo journalctl -u forpost-stream -f
```

## Видалення

```bash
./uninstall.sh
```
