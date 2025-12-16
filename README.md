# FORPOST Stream

Трансляція відео з пристрою DZYGA на RTMP сервер з динамічним оверлеєм частоти.

## Встановлення

```bash
git clone https://github.com/USER/forpost-stream.git
cd forpost-stream
./install.sh
```

При встановленні введіть:
- **RTMP URL** — повний URL включно з ключем (напр. `rtmps://server:port/app/key`)
- **Overlay text** — текст оверлею (залиште пустим щоб вимкнути)

## Конфігурація

```bash
nano stream.conf
./stop.sh && ./start.sh
```

### Параметри

| Параметр | Опис | Приклад |
|----------|------|---------|
| `RTMP_URL` | Повний URL для стріму | `rtmps://server:port/app/key` |
| `OVERLAY_TEXT` | Текст оверлею | `[Моя камера]` |
| `SHOW_FREQUENCY` | Показувати частоту | `true` / `false` |
| `VIDEO_CRF` | Якість відео (28-32 = низький CPU) | `28` |
| `OVERLAY_FONTSIZE` | Розмір шрифту | `16` |
| `OVERLAY_BG_OPACITY` | Прозорість фону (0.0-1.0) | `0.5` |
| `OVERLAY_TEXT_OPACITY` | Прозорість тексту (0.0-1.0) | `1.0` |

## Команди

```bash
./start.sh    # запустити
./stop.sh     # зупинити
```

## Логи

```bash
sudo journalctl -u forpost-stream -f
```

## Видалення

```bash
./uninstall.sh
```
