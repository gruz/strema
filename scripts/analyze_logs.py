#!/usr/bin/env python3
"""Analyze debug.log and print summary of issues.

Works as CLI tool and can be called by the web interface.
"""
import argparse
import datetime
import json
import re
import sys
from pathlib import Path


def counter_growth(values):
    """Sum of positive deltas. Cumulative counters (retrans, drop) reset
    on reconnect/session restart, so a plain last-first is wrong."""
    return sum(max(0, b - a) for a, b in zip(values, values[1:]))


def analyze_logs(log_dir, hours=0):
    """Analyze debug.log and return summary dict with issues and recommendation."""
    log_path = Path(log_dir) / 'debug.log'
    if not log_path.exists():
        return {
            'issues': [],
            'recommendation': 'Debug-лог не знайдено. Спочатку увімкніть DEBUG_MODE.',
            'period': ''
        }

    # Analyze full history: rotated .old file first, then current log
    lines = []
    old_path = Path(log_dir) / 'debug.log.old'
    for path in (old_path, log_path):
        if path.exists():
            with open(path, 'r', errors='replace') as f:
                lines.extend(f.read().splitlines())

    # Filter by time window if requested (hours > 0)
    if hours > 0:
        ts_re = re.compile(r'^\[([0-9-]+ [0-9:]+)\]')
        last_ts = None
        for line in reversed(lines):
            m = ts_re.match(line)
            if m:
                last_ts = datetime.datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S')
                break
        if last_ts:
            cutoff = last_ts - datetime.timedelta(hours=hours)
            filtered = []
            for line in lines:
                m = ts_re.match(line)
                if m:
                    try:
                        ts = datetime.datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S')
                        if ts >= cutoff:
                            filtered.append(line)
                    except ValueError:
                        pass
                else:
                    filtered.append(line)
            lines = filtered

    issues = []

    # CPU check: count saturated samples over the whole period
    cpu_lines = [l for l in lines if '[METRIC]' in l and 'cpu_ffmpeg=' in l]
    if cpu_lines:
        cpu_values = []
        for line in cpu_lines:
            match = re.search(r'cpu_ffmpeg=([0-9]+)', line)
            if match:
                cpu_values.append(int(match.group(1)))
        if cpu_values:
            saturated = sum(1 for v in cpu_values if v > 250)
            if saturated > len(cpu_values) * 0.1 and saturated > 5:
                issues.append({
                    'type': 'cpu',
                    'severity': 'high',
                    'message': f'CPU ffmpeg > 250% (з 400% на 4 ядрах) у {saturated}/{len(cpu_values)} вимірах — кодувальник на межі насичення',
                    'hint': 'Зменшіть VIDEO_BITRATE, VIDEO_FPS або вимкніть оверлеї'
                })

    # Local link check (ping to default gateway)
    timeouts = [l for l in lines if '[METRIC]' in l and 'gw_ping=timeout' in l]
    if len(timeouts) > 3:
        issues.append({
            'type': 'network',
            'severity': 'high',
            'message': f'{len(timeouts)} таймаутів пінгу до шлюзу — локальне з\'єднання нестабільне (PoE-кабель / роутер)',
            'hint': 'Перевірте PoE-кабель та локальне мережеве обладнання'
        })

    # Gateway ping packet loss (partial loss within burst)
    loss_lines = [l for l in lines if '[METRIC]' in l and 'gw_loss=' in l]
    if loss_lines:
        loss_events = 0
        for line in loss_lines:
            match = re.search(r'gw_loss=([0-9]+)%', line)
            if match and 0 < int(match.group(1)) < 100:
                loss_events += 1
        if loss_events > 3:
            issues.append({
                'type': 'network',
                'severity': 'medium',
                'message': f'Часткова втрата пакетів до шлюзу у {loss_events} вимірах — джиттер локального з\'єднання',
                'hint': 'Перевірте якість та довжину PoE-кабелю, можливі електромагнітні перешкоди'
            })

    # TCP RTT to RTMP server (real connection latency, works even if ICMP is blocked)
    rtt_lines = [l for l in lines if '[METRIC]' in l and 'rtt=' in l and 'rtt=N/A' not in l]
    if rtt_lines:
        rtt_values = []
        for line in rtt_lines:
            match = re.search(r'rtt=([0-9.]+)ms', line)
            if match:
                try:
                    rtt_values.append(float(match.group(1)))
                except ValueError:
                    pass
        if rtt_values:
            high_rtt = sum(1 for v in rtt_values if v > 500)
            if high_rtt > len(rtt_values) * 0.1 and high_rtt > 5:
                issues.append({
                    'type': 'network',
                    'severity': 'medium',
                    'message': f'Високий TCP RTT (>500 мс) до RTMP-сервера у {high_rtt}/{len(rtt_values)} вимірах',
                    'hint': 'Повільний uplink. Затримка стріму буде високою'
                })

    # Packet loss: retrans is a cumulative counter (resets per connection) — sum growth
    retrans_lines = [l for l in lines if '[METRIC]' in l and 'retrans=' in l]
    if retrans_lines:
        retrans_values = []
        for line in retrans_lines:
            match = re.search(r'retrans=([0-9]+)', line)
            if match:
                retrans_values.append(int(match.group(1)))
        retrans_total = counter_growth(retrans_values)
        if retrans_total > 50:
            issues.append({
                'type': 'network',
                'severity': 'medium',
                'message': f'{retrans_total} TCP-ретрансмісій за період моніторингу — втрата пакетів на uplink',
                'hint': 'Перевантаження мережі або хендовер/переключення базової станції'
            })

    # Encoding speed (lag detection): count slow samples over whole period
    speed_lines = [l for l in lines if '[METRIC]' in l and 'speed=' in l and 'speed=N/A' not in l]
    if speed_lines:
        speed_values = []
        for line in speed_lines:
            match = re.search(r'speed=([0-9.]+)x', line)
            if match:
                try:
                    speed = float(match.group(1))
                    speed_values.append(speed)
                except ValueError:
                    pass
        if speed_values:
            slow = sum(1 for v in speed_values if v < 0.95)
            if slow > len(speed_values) * 0.1 and slow > 3:
                issues.append({
                    'type': 'encoding',
                    'severity': 'high',
                    'message': f'Швидкість кодування < 0.95x у {slow}/{len(speed_values)} вимірах — не встигає за реальним часом',
                    'hint': 'Зменшіть VIDEO_BITRATE або VIDEO_FPS, вимкніть оверлеї або перевірте тротлінг CPU (недостатнє живлення/перегрів)'
                })

    # Dropped frames
    drop_lines = [l for l in lines if '[METRIC]' in l and 'drop=' in l and 'drop=N/A' not in l]
    if drop_lines:
        drop_values = []
        for line in drop_lines:
            match = re.search(r'drop=([0-9]+)', line)
            if match:
                drop_values.append(int(match.group(1)))
        if len(drop_values) >= 2:
            deltas = [b - a for a, b in zip(drop_values, drop_values[1:])]
            bad_intervals = sum(1 for d in deltas if d > 24)
            if bad_intervals > len(deltas) * 0.1 and bad_intervals > 3:
                issues.append({
                    'type': 'encoding',
                    'severity': 'high',
                    'message': f'Високий рівень відкидання кадрів (>3/с) у {bad_intervals}/{len(deltas)} інтервалах — кодувальник не справляється',
                    'hint': 'Перевантаження CPU. Зменшіть бітрейт/FPS або вимкніть оверлеї. Примітка: ~1 drop/с — нормальна конверсія fps (25->24)'
                })

    # USB disconnects (peripherals resetting — power or cable issues)
    usb_lines = [l for l in lines if '[METRIC]' in l and 'usb_disc=' in l]
    if usb_lines:
        usb_values = []
        for line in usb_lines:
            match = re.search(r'usb_disc=([0-9]+)', line)
            if match:
                usb_values.append(int(match.group(1)))
        new_disconnects = counter_growth(usb_values)
        if new_disconnects > 0:
            issues.append({
                'type': 'power',
                'severity': 'high',
                'message': f'{new_disconnects} USB-дисконект(и) під час моніторингу — периферія (VRX/capture/RP2040) перезавантажується',
                'hint': 'Ймовірно проблема з живленням або ослаблений USB-кабель. Перевірте dmesg, щоб визначити, який пристрій перезавантажується'
            })

    # USB device count (sudden drops indicate hub/power issues)
    usb_dev_lines = [l for l in lines if '[METRIC]' in l and 'usb_devs=' in l]
    if usb_dev_lines:
        usb_dev_values = []
        for line in usb_dev_lines:
            match = re.search(r'usb_devs=([0-9]+)', line)
            if match:
                usb_dev_values.append(int(match.group(1)))
        if usb_dev_values and len(usb_dev_values) >= 2:
            drop = max(usb_dev_values) - min(usb_dev_values)
            if drop >= 2:
                issues.append({
                    'type': 'power',
                    'severity': 'high',
                    'message': f'USB-пристрої зникали з шини (з {max(usb_dev_values)} до {min(usb_dev_values)}) — проблема живлення/контактів',
                    'hint': 'Перевірте блок живлення USB-хаба, кабелі, можливе перенавантаження по струму'
                })

    # Video capture device presence
    video_dev_lines = [l for l in lines if '[METRIC]' in l and 'video_dev=' in l]
    if video_dev_lines:
        video_dev_values = []
        for line in video_dev_lines:
            match = re.search(r'video_dev=([0-9]+)', line)
            if match:
                video_dev_values.append(int(match.group(1)))
        if video_dev_values and min(video_dev_values) == 0:
            issues.append({
                'type': 'stream',
                'severity': 'high',
                'message': 'Плата відеозахоплення пропадала (/dev/video* відсутній) — стрім неможливий',
                'hint': 'Перевірте USB-кабель плати захоплення, живлення, чи не перегрілась'
            })

    # RP2040 (Dzyga) presence
    ttyacm_lines = [l for l in lines if '[METRIC]' in l and 'ttyacm=' in l]
    if ttyacm_lines:
        ttyacm_values = []
        for line in ttyacm_lines:
            match = re.search(r'ttyacm=([0-9]+)', line)
            if match:
                ttyacm_values.append(int(match.group(1)))
        if ttyacm_values and min(ttyacm_values) == 0:
            issues.append({
                'type': 'stream',
                'severity': 'high',
                'message': 'RP2040 (Dzyga) пропадав з шини — втрата керування частотою/сканером',
                'hint': 'Перевірте USB-кабель RP2040, живлення. Можливо, перезавантаження через недостатнє живлення'
            })

    # USB power errors from dmesg (under-voltage / over-current)
    usb_pwr_lines = [l for l in lines if '[METRIC]' in l and 'usb_pwr_err=' in l]
    if usb_pwr_lines:
        usb_pwr_values = []
        for line in usb_pwr_lines:
            match = re.search(r'usb_pwr_err=([0-9]+)', line)
            if match:
                usb_pwr_values.append(int(match.group(1)))
        if usb_pwr_values:
            pwr_err_total = counter_growth(usb_pwr_values)
            if pwr_err_total > 0:
                issues.append({
                    'type': 'power',
                    'severity': 'high',
                    'message': f'{pwr_err_total} помилок живлення USB (under-voltage/over-current)',
                    'hint': 'USB-пристрої відключаються через перенавантаження. Перевірте блок живлення, PoE-кабель, USB-хаб'
                })

    # Power: undervoltage detection (Raspberry Pi)
    undervolt_now = [l for l in lines if '[METRIC]' in l and 'pwr=UNDERVOLT' in l]
    undervolt_past = [l for l in lines if '[METRIC]' in l and 'pwr=was_bad' in l]
    if undervolt_now:
        issues.append({
            'type': 'power',
            'severity': 'high',
            'message': f'Виявлено недостатнє живлення у {len(undervolt_now)} вимірах — блок живлення недостатній',
            'hint': 'Перевірте довжину/якість PoE-кабелю та блок живлення. Просадка напруги призводить до тротлінгу CPU та лагів стріму'
        })
    elif undervolt_past:
        issues.append({
            'type': 'power',
            'severity': 'medium',
            'message': 'Недостатнє живлення траплялося з моменту завантаження (зараз не активно)',
            'hint': 'Живлення просідало в якийсь момент. Моніторте метрику pwr=, перевірте PoE/живлення під навантаженням'
        })

    # Additional undervoltage detection by core voltage (vcgencmd sometimes misses it)
    volt_lines = [l for l in lines if '[METRIC]' in l and 'volt=' in l]
    if volt_lines:
        volt_values = []
        for line in volt_lines:
            match = re.search(r'volt=([0-9.]+)V', line)
            if match:
                try:
                    volt_values.append(float(match.group(1)))
                except ValueError:
                    pass
        if volt_values:
            min_volt = min(volt_values)
            crit_count = sum(1 for v in volt_values if v < 0.85)
            low_count = sum(1 for v in volt_values if v < 0.87)
            if crit_count >= 3 or (len(volt_values) > 100 and crit_count / len(volt_values) > 0.01):
                issues.append({
                    'type': 'power',
                    'severity': 'high',
                    'message': f'Напруга ядра критично просідала (<0.85В) у {crit_count}/{len(volt_values)} вимірах, мінімум {min_volt:.4f}В',
                    'hint': 'Постійне недостатнє живлення — ймовірний тротлінг CPU. Перевірте блок живлення / PoE-кабель / з\'єднання'
                })
            elif low_count >= 5 or (len(volt_values) > 100 and low_count / len(volt_values) > 0.05):
                issues.append({
                    'type': 'power',
                    'severity': 'medium',
                    'message': f'Напруга ядра часто просідала (<0.87В) у {low_count}/{len(volt_values)} вимірах, мінімум {min_volt:.4f}В',
                    'hint': 'Живлення на межі. Якщо супроводжується лагами — перевірте блок живлення / PoE-кабель / з\'єднання'
                })

    # CPU temperature (throttling)
    temp_lines = [l for l in lines if '[METRIC]' in l and 'temp=' in l and 'N/A' not in l]
    if temp_lines:
        temp_values = []
        for line in temp_lines:
            match = re.search(r'temp=([0-9.]+)', line)
            if match:
                try:
                    temp_values.append(float(match.group(1)))
                except ValueError:
                    pass
        if temp_values:
            max_temp = max(temp_values)
            if max_temp > 75:
                issues.append({
                    'type': 'cpu',
                    'severity': 'high',
                    'message': f'Температура CPU сягала {max_temp:.1f}°C — можливий термальний тротлінг',
                    'hint': 'Покращіть охолодження, зменшіть температуру корпусу або знизьте навантаження на кодування'
                })
            elif max_temp > 70:
                issues.append({
                    'type': 'cpu',
                    'severity': 'medium',
                    'message': f'Температура CPU {max_temp:.1f}°C — наближається до порога термального тротлінгу (80°C)',
                    'hint': 'Перевірте вентилятор охолодження, радіатор, вентиляцію корпусу'
                })

    # ARM clock frequency (throttling indicator) — per-row correlation
    metric_rows = [l for l in lines if '[METRIC]' in l]
    clock_data = []
    for line in metric_rows:
        c = re.search(r'arm_clock=([0-9]+)', line)
        if c:
            try:
                clock = int(c.group(1))
                t = re.search(r'temp=([0-9.]+)', line)
                temp = float(t.group(1)) if t else None
                v = re.search(r'volt=([0-9.]+)V', line)
                volt = float(v.group(1)) if v else None
                undervolt = 'pwr=UNDERVOLT' in line or 'pwr=was_bad' in line
                clock_data.append({'clock': clock, 'temp': temp, 'volt': volt, 'undervolt': undervolt})
            except ValueError:
                pass

    if clock_data:
        clocks = [d['clock'] for d in clock_data]
        min_clock = min(clocks)

        # Filter to rows where clock was actually low for diagnosis
        low_clock_rows = [d for d in clock_data if d['clock'] < 1200000000]
        if low_clock_rows:
            thermal = any(r['temp'] is not None and r['temp'] > 75 for r in low_clock_rows)
            power = any(r['volt'] is not None and r['volt'] < 0.85 for r in low_clock_rows) or \
                    any(r['undervolt'] for r in low_clock_rows)
            if thermal and power:
                cause = 'термальний тротлінг і недостатнє живлення'
                hint = 'Одночасно перегрів і просідання живлення. Покращіть охолодження та перевірте блок живлення / PoE-кабель'
            elif thermal:
                cause = 'термальний тротлінг (перегрів CPU)'
                hint = 'Покращіть охолодження — частота знижена через температуру'
            elif power:
                cause = 'тротлінг через недостатнє живлення'
                hint = 'Напруга/живлення недостатні. Перевірте блок живлення / PoE-кабель / з\'єднання'
            else:
                cause = 'CPU тротлить (перегрів або недостатнє живлення)'
                hint = 'Перевірте охолодження, блок живлення / PoE-кабель. Pi 4 має працювати на 1500 МГц'
            issues.append({
                'type': 'cpu',
                'severity': 'high',
                'message': f'Частота ARM впала до {min_clock/1e6:.0f} МГц — {cause}',
                'hint': hint
            })
        else:
            # Medium: frequent dips but not severe
            low_clock_rows = [d for d in clock_data if d['clock'] < 1400000000]
            low_clock_count = len(low_clock_rows)
            if low_clock_count > len(clock_data) * 0.05:
                thermal = any(r['temp'] is not None and r['temp'] > 70 for r in low_clock_rows)
                power = any(r['volt'] is not None and r['volt'] < 0.87 for r in low_clock_rows) or \
                        any(r['undervolt'] for r in low_clock_rows)
                if thermal:
                    cause = 'ймовірний термальний тротлінг'
                    hint = 'Температура підвищена — перевірте охолодження'
                elif power:
                    cause = 'ймовірний тротлінг через живлення'
                    hint = 'Просідання напруги — перевірте блок живлення / PoE-кабель'
                else:
                    cause = 'можливий тротлінг (перегрів або просідання живлення)'
                    hint = 'Моніторте температуру та напругу'
                issues.append({
                    'type': 'cpu',
                    'severity': 'medium',
                    'message': f'Частота ARM знижувалась у {low_clock_count}/{len(clock_data)} вимірах (мінімум {min_clock/1e6:.0f} МГц) — {cause}',
                    'hint': hint
                })

    # Low memory
    mem_lines = [l for l in lines if '[METRIC]' in l and 'mem=' in l and 'N/A' not in l]
    if mem_lines:
        mem_values = []
        for line in mem_lines:
            match = re.search(r'mem=([0-9]+)', line)
            if match:
                mem_values.append(int(match.group(1)))
        if mem_values and min(mem_values) < 50:
            issues.append({
                'type': 'memory',
                'severity': 'medium',
                'message': f'Пам\'ять критично мала ({min(mem_values)}МБ вільно) — ризик OOM',
                'hint': 'Перевірте на витоки пам\'яті. Перезапуск сервісів може тимчасово допомогти'
            })

    # Disconnections: distinguish intentional stops from unexpected ones
    disconnect_lines = [l for l in lines if '[EVENT]' in l and 'disconnected' in l]
    graceful = [l for l in disconnect_lines if 'graceful' in l.lower() or 'сканування' in l.lower()]
    unexpected = [l for l in disconnect_lines if l not in graceful]
    if len(unexpected) > 0:
        issues.append({
            'type': 'stream',
            'severity': 'medium',
            'message': f'{len(unexpected)} розрив(и) стріму',
            'hint': 'Перевірте стабільність мережі, стан RTMP-сервера або падіння ffmpeg (див. рядки [FFMPEG] перед розривом)'
        })

    # FFMPEG timestamp drift warnings (accumulated frame dropping causes playback issues)
    past_duration = [l for l in lines if '[FFMPEG]' in l and 'Past duration' in l]
    if len(past_duration) > 10:
        issues.append({
            'type': 'encoding',
            'severity': 'medium',
            'message': f'{len(past_duration)} попереджень "Past duration too large" від ffmpeg',
            'hint': 'Дрейф таймстемпів через відкидання кадрів. Встановіть VIDEO_FPS=25 для відповідності виходу VRX або перевірте навантаження CPU, що спричиняє лаги'
        })

    # Determine analyzed period from first/last timestamps
    period = ''
    ts_re = re.compile(r'^\[([0-9-]+ [0-9:]+)\]')
    first_ts = next((m.group(1) for l in lines if (m := ts_re.match(l))), None)
    last_ts = next((m.group(1) for l in reversed(lines) if (m := ts_re.match(l))), None)
    if first_ts and last_ts:
        period = f' (період аналізу: {first_ts} — {last_ts})'

    recommendations = []
    if any(i['type'] == 'power' for i in issues):
        recommendations.append('Спочатку виправте живлення — недостатнє живлення спричиняє тротлінг та нестабільність')
    if any(i['type'] == 'cpu' for i in issues):
        recommendations.append('Зменшіть навантаження на кодування та покращіть охолодження')
    if any(i['type'] == 'encoding' for i in issues):
        recommendations.append('Зменшіть бітрейт/FPS або вимкніть оверлеї, щоб зменшити навантаження на кодування')
    if any(i['type'] == 'memory' for i in issues):
        recommendations.append('Перевірте на витоки пам\'яті та перезапустіть сервіси за потреби')
    if any(i['type'] == 'network' for i in issues):
        recommendations.append('Перевірте стабільність мережі (хендовери/переключення базових станцій можуть спричиняти тимчасові проблеми)')
    if any(i['type'] == 'stream' for i in issues):
        recommendations.append('Моніторте доступність RTMP-сервера')

    if not issues:
        recommendation = f'Проблем не виявлено. Стрім виглядає стабільним.{period}'
    else:
        recommendation = ' • '.join(recommendations) + period

    return {
        'issues': issues,
        'recommendation': recommendation,
        'period': period
    }


def format_text(result):
    """Format analysis result as human-readable text."""
    lines = []
    lines.append('=' * 50)
    lines.append('Аналіз debug.log')
    lines.append('=' * 50)

    if result['period']:
        lines.append(result['period'].strip())
        lines.append('')

    if not result['issues']:
        lines.append(result['recommendation'])
    else:
        lines.append(f"Виявлено проблем: {len(result['issues'])}")
        lines.append('')
        for idx, issue in enumerate(result['issues'], 1):
            severity_label = 'ВИСОКА' if issue['severity'] == 'high' else 'СЕРЕДНЯ'
            lines.append(f"{idx}. [{severity_label}] {issue['message']}")
            lines.append(f"   Підказка: {issue['hint']}")
            lines.append('')
        lines.append('Рекомендації:')
        for rec in result['recommendation'].split(' • '):
            if rec.strip():
                lines.append(f"  • {rec.strip()}")

    return '\n'.join(lines)


def main():
    script_dir = Path(__file__).parent.absolute()
    default_log_dir = script_dir.parent / 'logs'

    parser = argparse.ArgumentParser(
        description='Analyze FORPOST debug.log and report issues.'
    )
    parser.add_argument(
        '--log-dir',
        type=str,
        default=str(default_log_dir),
        help='Directory containing debug.log (default: ../logs/)'
    )
    parser.add_argument(
        '--hours',
        type=int,
        default=0,
        help='Analyze only last N hours (0 = all history)'
    )
    parser.add_argument(
        '--format',
        choices=['text', 'json'],
        default='text',
        help='Output format (default: text)'
    )
    args = parser.parse_args()

    result = analyze_logs(args.log_dir, args.hours)

    if args.format == 'json':
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(format_text(result))


if __name__ == '__main__':
    main()
