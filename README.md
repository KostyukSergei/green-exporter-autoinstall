# green-exporter-autoinstall

One-command installers for Prometheus host agents on Windows and Linux.
The scripts in this repository are [Apache-2.0](LICENSE). Third-party programs
are downloaded separately and stay under their own licenses ([NOTICE](NOTICE)).

Установщики агентов Prometheus: одна команда на Windows, одна на Linux.

```cmd
install-windows.cmd
```

```bash
sudo ./install-linux.sh
```

Права запрашиваются сами. `-Uninstall` / `--uninstall` снимает установленное.

## Что ставится

| Условие | Компонент | Порт | Метрики |
|---|---|---|---|
| Windows, всегда | windows_exporter | 9182 | `windows_*` |
| Windows, железо **без BMC** | LibreHardwareMonitor + lhm_exporter | 8000 | `custom_*` |
| Windows, железо **с BMC** | только windows_exporter; датчики — IPMI-over-LAN | — | `ipmi_*` с Prometheus |
| Linux, всегда | node_exporter | 9100 | `node_*` |
| Linux + NVIDIA | dcgm-exporter | 9400 | `DCGM_FI_DEV_*` |
| Linux + BMC | ipmi_exporter | 9290 | `ipmi_*` |

На **Server 2008 R2**: EXE `0.24.0` через NSSM (без коллектора `time`).
На новых Windows: MSI `0.31.8`.

## Откуда берутся бинарники

В git лежат только скрипты. Закреплённые версии:

| Компонент | Версия | Кто скачивает |
|---|---|---|
| windows_exporter | 0.24.0 exe, 0.31.8 msi | `fetch-windows-assets.ps1` |
| LibreHardwareMonitor (net472) | 0.9.4 | `fetch-windows-assets.ps1` |
| NSSM | 2.24 | `fetch-windows-assets.ps1` |
| node_exporter | последний релиз, или `--version` | `install-linux.sh` |
| ipmi_exporter | последний релиз | `install-linux.sh` |
| dcgm-exporter | образ `nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04` | `install-linux.sh` |

`install-windows.cmd` вызывает fetch сам, если файлов рядом нет.
Уже лежащие файлы не перекачиваются: можно положить их вручную и ставить офлайн.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fetch-windows-assets.ps1
```

`.NET 4.8` и WMF 5.1 fetch не качает. Для Server 2008 R2 их кладут в `prereqs\`
вручную, см. [prereqs/README.txt](prereqs/README.txt).

## Windows: ход установки

`install-windows.cmd`:

1. При отсутствии бинарников — `fetch-windows-assets.ps1`.
2. `windows-exporter.cmd` — снять старую установку, поставить нужный билд,
   правило фаервола `netsh`, старт, проверка `/metrics`. PowerShell 5.1
   на этом шаге не нужен.
3. `windows-agent.ps1` — LHM или ветка BMC. Нужен PowerShell 5.1. Если его нет
   и в `prereqs\` лежат .NET 4.8 и WMF 5.1, bootstrap ставит их и продолжает
   установку после перезагрузки.

Ключи (`windows-agent.ps1`, можно передать через cmd): `-NoLhm`, `-ForceLhm`,
`-NoBmc`, `-ForceBmc`.

Linux:

```bash
sudo ./install-linux.sh                 # установить или обновить
sudo ./install-linux.sh --uninstall     # снять
sudo ./install-linux.sh --no-dcgm       # без dcgm-exporter
sudo ./install-linux.sh --version 1.8.2 # конкретный node_exporter
```

Локальный архив `node_exporter-*.linux-<arch>.tar.gz` или
`ipmi_exporter-*.linux-<arch>.tar.gz` рядом со скриптом используется вместо
скачивания.

## Состав репозитория

```
install-windows.cmd          точка входа Windows
install-linux.sh             точка входа Linux
fetch-windows-assets.ps1     закреплённые бинарники Windows
windows-exporter.cmd         windows_exporter
windows-agent.ps1            LHM / BMC
bootstrap-prereqs.ps1        .NET + WMF 5.1 для Server 2008 R2
lhm_exporter.ps1             экспортёр LHM
test_exporter.ps1            тест разбора ответа LHM
diag-sensors.ps1             диагностика датчиков, ничего не меняет
prereqs/README.txt           куда класть офлайн-пакеты Microsoft
LICENSE                      Apache-2.0
NOTICE                       лицензии сторонних компонентов
```

После fetch рядом появляются `windows_exporter-*`, `LibreHardware\` и `nssm-2.24\`.
В git их нет.

## Откуда напряжения и температуры

**Windows без BMC** — LibreHardwareMonitor (`custom_*`).
**Windows с BMC** — IPMI-over-LAN, job `ipmi` на стороне Prometheus.
**Linux** — BMC через `ipmi_exporter`; GPU — `dcgm-exporter`.

## Проверка

Windows:

```powershell
(Invoke-WebRequest http://localhost:9182/metrics -UseBasicParsing).StatusCode
```

На железе с LHM дополнительно `custom_exporter_up` на `:8000`.

Linux:

```bash
curl -s localhost:9100/metrics | grep -c '^node_'
```

## Самоподъём служб (Windows)

Установщик настраивает две вещи, чтобы остановленный экспортёр поднялся сам:

- **краш → рестарт**: `sc failure` для `windows_exporter`, `PrometheusExporter`,
  `LibreHardwareMonitor`;
- **ручной Stop / Disabled → сторож**: задача `MonitoringWatchdog` (schtasks,
  раз в 5 минут, SYSTEM) через `C:\Monitoring\watchdog.cmd` возвращает
  `start= auto` и поднимает службу, которая не в состоянии RUNNING.
  `sc failure` ручной стоп не ловит, поэтому сторож нужен отдельно.

Проверить или снять вручную:

```bat
schtasks /Query /TN MonitoringWatchdog
type C:\Monitoring\watchdog.log
schtasks /Delete /TN MonitoringWatchdog /F
```

## Лицензия

Скрипты — Apache License 2.0, см. [LICENSE](LICENSE).
Сторонние программы перечислены в [NOTICE](NOTICE).
