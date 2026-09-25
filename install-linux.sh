#!/usr/bin/env bash
#
# Установка мониторинга на Debian/Ubuntu одной командой.
# Аналог install-windows.cmd для Windows-хостов.
#
# Ставит node_exporter (порт 9100). Дополнительно, если находит железо:
#   видеокарта NVIDIA -> dcgm-exporter (порт 9400), метрики DCGM_FI_DEV_*
#   /dev/ipmi* (BMC)  -> ipmi_exporter (порт 9290), метрики ipmi_*
#
# ipmi_exporter нужен ради напряжений: на серверных платах они живут за BMC,
# а не в hwmon. На Dell в hwmon виден только coretemp, тогда как BMC отдаёт
# 35 напряжений, обороты вентиляторов и потребление.
#
#   sudo ./install-linux.sh              установить или обновить
#   sudo ./install-linux.sh --uninstall  снять полностью
#   sudo ./install-linux.sh --no-dcgm    только node_exporter
#   sudo ./install-linux.sh --version 1.8.2   конкретная версия
#
# Идемпотентен: на хосте с уже работающим экспортёром обновляет его на месте.
# Перед заменой снимает копию бинарника и юнита, и если проверка после запуска
# не проходит — откатывается на прежнюю версию сам.
#
set -euo pipefail

PORT=9100
USER_NAME=node_exporter
BIN=/usr/local/bin/node_exporter
UNIT=/etc/systemd/system/node_exporter.service
BACKUP_DIR=/var/backups/node_exporter
NE_VERSION=""   # своя переменная; VERSION занята /etc/os-release
DO_UNINSTALL=0
DCGM_PORT=9400
DCGM_MODE=auto   # auto | yes | no
# dcgm-exporter не публикует бинарников, только исходники, поэтому берётся
# официальный контейнер. Тег можно переопределить, если этот окажется недоступен.
# Тег сверен со списком в реестре nvcr.io (самый свежий с ubuntu22.04 на
# 2026-08-06). Если понадобится другой — ключ --dcgm-image.
DCGM_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04"
DCGM_UNIT=/etc/systemd/system/dcgm-exporter.service
IPMI_PORT=9290
IPMI_MODE=auto   # auto | yes | no
IPMI_BIN=/usr/local/bin/ipmi_exporter
IPMI_UNIT=/etc/systemd/system/ipmi_exporter.service
IPMI_VERSION=""  # пусто -> последняя с GitHub

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) DO_UNINSTALL=1 ;;
        --version)   NE_VERSION="${2:-}"; shift ;;
        --port)      PORT="${2:-}"; shift ;;
        --no-dcgm)   DCGM_MODE=no ;;
        --with-dcgm) DCGM_MODE=yes ;;
        --dcgm-image) DCGM_IMAGE="${2:-}"; shift ;;
        --no-ipmi)   IPMI_MODE=no ;;
        --with-ipmi) IPMI_MODE=yes ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
die()  { printf '\nОШИБКА: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "нужны права root: запустите через sudo"

# --- удаление -------------------------------------------------------------
if [ "$DO_UNINSTALL" -eq 1 ]; then
    step "Снимаю node_exporter"
    systemctl disable --now node_exporter 2>/dev/null || true
    rm -f "$UNIT" && systemctl daemon-reload
    rm -f "$BIN"
    if [ -f "$DCGM_UNIT" ]; then
        systemctl disable --now dcgm-exporter 2>/dev/null || true
        rm -f "$DCGM_UNIT"; systemctl daemon-reload
        docker rm -f dcgm-exporter >/dev/null 2>&1 || true
        note "dcgm-exporter снят"
    fi
    if [ -f "$IPMI_UNIT" ]; then
        systemctl disable --now ipmi_exporter 2>/dev/null || true
        rm -f "$IPMI_UNIT" "$IPMI_BIN"; systemctl daemon-reload
        note "ipmi_exporter снят"
    fi
    userdel "$USER_NAME" 2>/dev/null || true
    command -v ufw >/dev/null 2>&1 && ufw --force delete allow "$PORT/tcp" >/dev/null 2>&1 || true
    note "удалено. Не забудьте убрать хост из prometheus.yml"
    exit 0
fi

# --- что за система -------------------------------------------------------
step "Проверяю систему"
# os-release читаем в подоболочке: он определяет переменную VERSION и затирает
# любую одноимённую в скрипте — на этом уже обожглись, URL собирался из
# "11 (bullseye)" вместо номера версии node_exporter.
[ -r /etc/os-release ] || die "нет /etc/os-release, дистрибутив не опознан"
OS_PRETTY=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")
OS_FAMILY=$(. /etc/os-release 2>/dev/null && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")
case "$OS_FAMILY" in
    *debian*|*ubuntu*) : ;;
    *) note "ВНИМАНИЕ: дистрибутив ${OS_PRETTY:-неизвестен}, скрипт рассчитан на Debian/Ubuntu" ;;
esac
case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    armv7l)  ARCH=armv7 ;;
    *) die "неподдерживаемая архитектура: $(uname -m)" ;;
esac
note "${OS_PRETTY:-?} / $ARCH"

# --- откуда брать дистрибутив --------------------------------------------
step "Ищу дистрибутив node_exporter"
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
TARBALL=$(ls -1 "$SRC_DIR"/node_exporter-*."linux-$ARCH".tar.gz 2>/dev/null | sort -V | tail -1 || true)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -n "$TARBALL" ]; then
    note "локальный архив: $(basename "$TARBALL")"
else
    if [ -z "$NE_VERSION" ]; then
        # без интернета версию не узнать — тогда нужен локальный архив
        NE_VERSION=$(curl -fsSL --max-time 20 \
            https://api.github.com/repos/prometheus/node_exporter/releases/latest 2>/dev/null |
            sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1 || true)
        [ -n "$NE_VERSION" ] || die "не удалось узнать последнюю версию. Задайте --version, либо положите рядом node_exporter-*.linux-$ARCH.tar.gz"
    fi
    # версия должна быть похожа на 1.8.2 — иначе URL заведомо мусорный
    case "$NE_VERSION" in
        [0-9]*.[0-9]*) : ;;
        *) die "версия выглядит неправильно: '$NE_VERSION'" ;;
    esac
    URL="https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.linux-${ARCH}.tar.gz"
    note "скачиваю v$NE_VERSION"
    curl -fsSL --max-time 300 -o "$TMP/ne.tar.gz" "$URL" || die "не скачался: $URL"
    TARBALL="$TMP/ne.tar.gz"
fi

tar xzf "$TARBALL" -C "$TMP" --strip-components=1 || die "архив не распаковался"
[ -x "$TMP/node_exporter" ] || die "в архиве нет исполняемого node_exporter"
NEW_VER=$("$TMP/node_exporter" --version 2>&1 | head -1 | awk '{print $3}')
note "версия в архиве: $NEW_VER"

# --- резервная копия перед заменой ---------------------------------------
OLD_VER=""
if [ -x "$BIN" ]; then
    OLD_VER=$("$BIN" --version 2>&1 | head -1 | awk '{print $3}' || echo "?")
    step "Уже установлен ($OLD_VER), делаю резервную копию"
    mkdir -p "$BACKUP_DIR"
    cp -a "$BIN" "$BACKUP_DIR/node_exporter.$OLD_VER" 2>/dev/null || true
    [ -f "$UNIT" ] && cp -a "$UNIT" "$BACKUP_DIR/node_exporter.service.bak"
    note "копии в $BACKUP_DIR"
fi

# --- пользователь ---------------------------------------------------------
step "Готовлю пользователя и каталоги"
if ! id "$USER_NAME" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME"
    note "создан системный пользователь $USER_NAME"
else
    note "пользователь $USER_NAME уже есть"
fi
install -d -o "$USER_NAME" -g "$USER_NAME" -m 755 /var/lib/node_exporter/textfile

# --- бинарник -------------------------------------------------------------
step "Ставлю бинарник"
systemctl stop node_exporter 2>/dev/null || true
install -o root -g root -m 755 "$TMP/node_exporter" "$BIN"
note "$BIN -> $($BIN --version 2>&1 | head -1 | awk '{print $3}')"

# --- юнит -----------------------------------------------------------------
step "Пишу systemd-юнит"
cat > "$UNIT" <<UNITEOF
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
# network-online, а не network: иначе экспортёр может подняться раньше,
# чем появится адрес, и привязка к порту не удастся
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER_NAME
Group=$USER_NAME
ExecStart=$BIN \\
  --web.listen-address=:$PORT \\
  --collector.hwmon \\
  --collector.systemd \\
  --collector.textfile.directory=/var/lib/node_exporter/textfile
Restart=always
RestartSec=5

# --collector.hwmon обязателен: без него нет node_hwmon_temp_celsius, на
# котором построено общее правило перегрева CPU для linux-хостов.
# --collector.systemd даёт node_systemd_unit_state — по нему можно алертить
# на падение любой службы, включая сам мониторинг.

# Ограничения намеренно скромные. ProtectHome и PrivateTmp здесь ВРЕДНЫ:
# node_exporter обязан видеть реальное дерево монтирования, иначе метрики
# node_filesystem_* по /home и /tmp станут неверными или пропадут.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectKernelModules=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
note "$UNIT"

# --- фаервол --------------------------------------------------------------
step "Проверяю фаервол"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi active; then
    ufw allow "$PORT/tcp" >/dev/null && note "ufw: порт $PORT открыт"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    note "firewalld: порт $PORT открыт"
else
    note "активного ufw/firewalld нет, правила не требуются"
fi

# --- запуск ---------------------------------------------------------------
step "Запускаю"
systemctl enable node_exporter >/dev/null 2>&1
systemctl restart node_exporter
sleep 4

# --- проверка -------------------------------------------------------------
step "Проверяю, что всё действительно работает"
PROBLEMS=()

if systemctl is-active --quiet node_exporter; then
    note "служба: active ($(systemctl is-enabled node_exporter))"
else
    PROBLEMS+=("служба не запущена")
    journalctl -u node_exporter -n 5 --no-pager 2>/dev/null | sed 's/^/      /' || true
fi

LISTEN=$(ss -tlnH "sport = :$PORT" 2>/dev/null | awk '{print $4}' | paste -sd, -)
if [ -n "$LISTEN" ]; then
    note "слушает: $LISTEN"
else
    PROBLEMS+=("на порту $PORT никто не слушает")
fi

BODY=$(curl -fsS --max-time 10 "http://localhost:$PORT/metrics" 2>/dev/null || true)
if [ -n "$BODY" ]; then
    TOTAL=$(printf '%s\n' "$BODY" | grep -vc '^#' || true)
    HWMON=$(printf '%s\n' "$BODY" | grep -c '^node_hwmon_temp_celsius' || true)
    SYSD=$(printf '%s\n' "$BODY" | grep -c '^node_systemd_unit_state' || true)
    note "метрик: $TOTAL (hwmon: $HWMON, systemd: $SYSD)"
    [ "$TOTAL" -gt 100 ] || PROBLEMS+=("подозрительно мало метрик: $TOTAL")
    if [ "$HWMON" -eq 0 ]; then
        note "ВНИМАНИЕ: датчиков hwmon нет — обычное дело для виртуалки,"
        note "          но правило перегрева CPU по этому хосту работать не будет"
    fi
else
    PROBLEMS+=("экспортёр не отвечает на http://localhost:$PORT/metrics")
fi

# --- откат, если стало хуже ----------------------------------------------
if [ ${#PROBLEMS[@]} -gt 0 ] && [ -n "$OLD_VER" ] && [ -f "$BACKUP_DIR/node_exporter.$OLD_VER" ]; then
    step "Проверка не прошла — откатываюсь на $OLD_VER"
    install -o root -g root -m 755 "$BACKUP_DIR/node_exporter.$OLD_VER" "$BIN"
    [ -f "$BACKUP_DIR/node_exporter.service.bak" ] && cp -a "$BACKUP_DIR/node_exporter.service.bak" "$UNIT"
    systemctl daemon-reload
    systemctl restart node_exporter || true
    sleep 3
    if systemctl is-active --quiet node_exporter; then
        note "откат выполнен, прежняя версия снова работает"
    else
        note "откат НЕ помог — разбирайтесь вручную: journalctl -u node_exporter"
    fi
fi

# --- GPU: dcgm-exporter ---------------------------------------------------
# Ставится после проверки node_exporter намеренно: сбой здесь не должен
# приводить к откату уже работающего node_exporter.
has_nvidia_gpu() {
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q '^GPU'; then
        return 0
    fi
    if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -Eqi 'nvidia.*(vga|3d controller)'; then
        return 0
    fi
    return 1
}

WANT_DCGM=0
case "$DCGM_MODE" in
    yes)  WANT_DCGM=1 ;;
    no)   : ;;
    auto) has_nvidia_gpu && WANT_DCGM=1 || true ;;
esac

if [ "$WANT_DCGM" -eq 0 ]; then
    if [ "$DCGM_MODE" = auto ]; then
        step "Видеокарта NVIDIA не найдена"
        note "dcgm-exporter не нужен (принудительно — ключ --with-dcgm)"
    fi
else
    step "Ставлю dcgm-exporter (GPU, порт $DCGM_PORT)"
    GPU_OK=1
    if command -v nvidia-smi >/dev/null 2>&1; then
        note "$(nvidia-smi -L 2>/dev/null | head -2 | paste -sd'; ' -)"
    fi

    # dcgm-exporter распространяется только контейнером, поэтому нужен docker
    if ! command -v docker >/dev/null 2>&1; then
        PROBLEMS+=("dcgm-exporter требует docker, а его нет. Поставьте docker и запустите скрипт снова, либо используйте --no-dcgm")
        GPU_OK=0
    elif ! docker info >/dev/null 2>&1; then
        PROBLEMS+=("docker установлен, но демон не отвечает (systemctl start docker)")
        GPU_OK=0
    fi

    # без nvidia-container-toolkit контейнер не увидит видеокарту
    if [ "$GPU_OK" -eq 1 ] && ! docker info 2>/dev/null | grep -qi nvidia; then
        if ! command -v nvidia-container-runtime >/dev/null 2>&1 && \
           ! command -v nvidia-ctk >/dev/null 2>&1; then
            PROBLEMS+=("нет nvidia-container-toolkit — контейнер не получит доступ к GPU. Поставьте пакет nvidia-container-toolkit и повторите")
            GPU_OK=0
        fi
    fi

    if [ "$GPU_OK" -eq 1 ]; then
        note "тяну образ $DCGM_IMAGE"
        if ! docker pull "$DCGM_IMAGE" >/dev/null 2>&1; then
            PROBLEMS+=("образ $DCGM_IMAGE не скачался. Проверьте доступ к nvcr.io или задайте другой тег ключом --dcgm-image")
            GPU_OK=0
        fi
    fi

    if [ "$GPU_OK" -eq 1 ]; then
        cat > "$DCGM_UNIT" <<DCGMEOF
[Unit]
Description=NVIDIA DCGM Exporter (GPU metrics for Prometheus)
Documentation=https://github.com/NVIDIA/dcgm-exporter
After=network-online.target docker.service
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
# --rm и удаление перед стартом: иначе после жёсткой перезагрузки остаётся
# контейнер-призрак с занятым именем, и служба не поднимается
ExecStartPre=-/usr/bin/docker rm -f dcgm-exporter
ExecStart=/usr/bin/docker run --rm --name dcgm-exporter \\
  --gpus all --cap-add SYS_ADMIN \\
  -p $DCGM_PORT:9400 \\
  $DCGM_IMAGE
ExecStop=/usr/bin/docker stop -t 10 dcgm-exporter
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
DCGMEOF
        systemctl daemon-reload
        systemctl enable dcgm-exporter >/dev/null 2>&1
        systemctl restart dcgm-exporter
        note "жду инициализации GPU, это дольше обычного"
        sleep 20

        if systemctl is-active --quiet dcgm-exporter; then
            note "служба dcgm-exporter: active"
        else
            PROBLEMS+=("служба dcgm-exporter не запустилась")
            journalctl -u dcgm-exporter -n 8 --no-pager 2>/dev/null | sed 's/^/      /' || true
        fi

        GBODY=$(curl -fsS --max-time 15 "http://localhost:$DCGM_PORT/metrics" 2>/dev/null || true)
        if [ -n "$GBODY" ]; then
            GTOTAL=$(printf '%s\n' "$GBODY" | grep -c '^DCGM_FI_' || true)
            # именно эта метрика нужна существующему правилу перегрева GPU
            GTEMP=$(printf '%s\n' "$GBODY" | grep -c '^DCGM_FI_DEV_GPU_TEMP' || true)
            note "метрик DCGM_FI_*: $GTOTAL (из них DCGM_FI_DEV_GPU_TEMP: $GTEMP)"
            [ "$GTEMP" -gt 0 ] || PROBLEMS+=("нет DCGM_FI_DEV_GPU_TEMP — правило перегрева GPU работать не будет")
        else
            PROBLEMS+=("dcgm-exporter не отвечает на http://localhost:$DCGM_PORT/metrics")
        fi

        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi active; then
            ufw allow "$DCGM_PORT/tcp" >/dev/null && note "ufw: порт $DCGM_PORT открыт"
        fi
        DCGM_DONE=1
    fi
fi

# --- BMC: ipmi_exporter ---------------------------------------------------
# Как и GPU-часть, идёт после проверки node_exporter: сбой здесь не должен
# приводить к откату уже работающего node_exporter.
IPMI_DONE=0
WANT_IPMI=0
case "$IPMI_MODE" in
    yes)  WANT_IPMI=1 ;;
    no)   : ;;
    auto) ls /dev/ipmi* >/dev/null 2>&1 && WANT_IPMI=1 || true ;;
esac

if [ "$WANT_IPMI" -eq 0 ]; then
    if [ "$IPMI_MODE" = auto ]; then
        step "BMC не найден"
        note "устройств /dev/ipmi* нет — напряжения с платы читать нечем"
        note "(на обычном ПК их и не бывает, это серверная штука)"
    fi
else
    step "Найден BMC, ставлю ipmi_exporter (порт $IPMI_PORT)"
    IPMI_OK=1

    # ipmi_exporter работает НЕ через ipmitool, а через FreeIPMI
    if ! command -v ipmimonitoring >/dev/null 2>&1; then
        note "ставлю freeipmi-tools"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq freeipmi-tools >/dev/null 2>&1 || true
    fi
    if ! command -v ipmimonitoring >/dev/null 2>&1; then
        PROBLEMS+=("нет freeipmi-tools, ipmi_exporter без него не соберёт данные")
        IPMI_OK=0
    fi

    if [ "$IPMI_OK" -eq 1 ]; then
        IPMI_TAR=$(ls -1 "$SRC_DIR"/ipmi_exporter-*."linux-$ARCH".tar.gz 2>/dev/null | sort -V | tail -1 || true)
        ITMP=$(mktemp -d)
        if [ -n "$IPMI_TAR" ]; then
            note "локальный архив: $(basename "$IPMI_TAR")"
        else
            if [ -z "$IPMI_VERSION" ]; then
                IPMI_VERSION=$(curl -fsSL --max-time 20 \
                    https://api.github.com/repos/prometheus-community/ipmi_exporter/releases/latest 2>/dev/null |
                    sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1 || true)
            fi
            case "$IPMI_VERSION" in
                [0-9]*.[0-9]*) : ;;
                *) PROBLEMS+=("не удалось узнать версию ipmi_exporter, задайте архив рядом со скриптом"); IPMI_OK=0 ;;
            esac
            if [ "$IPMI_OK" -eq 1 ]; then
                IURL="https://github.com/prometheus-community/ipmi_exporter/releases/download/v${IPMI_VERSION}/ipmi_exporter-${IPMI_VERSION}.linux-${ARCH}.tar.gz"
                note "скачиваю v$IPMI_VERSION"
                curl -fsSL --max-time 300 -o "$ITMP/ie.tar.gz" "$IURL" || { PROBLEMS+=("не скачался $IURL"); IPMI_OK=0; }
                IPMI_TAR="$ITMP/ie.tar.gz"
            fi
        fi
    fi

    if [ "$IPMI_OK" -eq 1 ]; then
        tar xzf "$IPMI_TAR" -C "$ITMP" --strip-components=1 2>/dev/null || { PROBLEMS+=("архив ipmi_exporter не распаковался"); IPMI_OK=0; }
    fi

    if [ "$IPMI_OK" -eq 1 ] && [ -x "$ITMP/ipmi_exporter" ]; then
        systemctl stop ipmi_exporter 2>/dev/null || true
        install -o root -g root -m 755 "$ITMP/ipmi_exporter" "$IPMI_BIN"
        cat > "$IPMI_UNIT" <<IPMIEOF
[Unit]
Description=Prometheus IPMI Exporter (датчики BMC)
Documentation=https://github.com/prometheus-community/ipmi_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Запускается от root намеренно: /dev/ipmi0 имеет права 600 root:root,
# без прав доступа экспортёр не прочитает ни одного датчика.
User=root
ExecStart=$IPMI_BIN --config.file=/etc/ipmi_exporter.yml --web.listen-address=:$IPMI_PORT
Restart=always
RestartSec=5
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
IPMIEOF
        # Пустой конфиг = локальный режим: экспортёр читает свой же BMC
        [ -f /etc/ipmi_exporter.yml ] || cat > /etc/ipmi_exporter.yml <<'CFGEOF'
# Локальный режим: собираем датчики с BMC этой же машины.
# Удалённые BMC описываются отдельными модулями, см. документацию.
modules:
  default:
    collectors:
      - ipmi
      - dcmi
      - chassis
CFGEOF
        systemctl daemon-reload
        systemctl enable ipmi_exporter >/dev/null 2>&1
        systemctl restart ipmi_exporter
        sleep 8

        if systemctl is-active --quiet ipmi_exporter; then
            note "служба ipmi_exporter: active"
        else
            PROBLEMS+=("служба ipmi_exporter не запустилась")
            journalctl -u ipmi_exporter -n 6 --no-pager 2>/dev/null | sed 's/^/      /' || true
        fi

        IBODY=$(curl -fsS --max-time 25 "http://localhost:$IPMI_PORT/metrics" 2>/dev/null || true)
        if [ -n "$IBODY" ]; then
            IV=$(printf '%s\n' "$IBODY" | grep -c '^ipmi_voltage' || true)
            IF=$(printf '%s\n' "$IBODY" | grep -c '^ipmi_fan_speed' || true)
            IT=$(printf '%s\n' "$IBODY" | grep -c '^ipmi_temperature' || true)
            note "метрик BMC: напряжений $IV, вентиляторов $IF, температур $IT"
            [ "$IV" -gt 0 ] || note "ВНИМАНИЕ: напряжений нет — возможно, BMC их не отдаёт"
        else
            PROBLEMS+=("ipmi_exporter не отвечает на http://localhost:$IPMI_PORT/metrics")
        fi

        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi active; then
            ufw allow "$IPMI_PORT/tcp" >/dev/null && note "ufw: порт $IPMI_PORT открыт"
        fi
        IPMI_DONE=1
    fi
    rm -rf "${ITMP:-/nonexistent-tmp}"
fi

echo
if [ ${#PROBLEMS[@]} -eq 0 ]; then
    IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    echo "ГОТОВО. node_exporter установлен и проверен."
    echo
    echo "Добавьте хост в prometheus.yml, джоб servers:"
    TARGETS="'${IP:-<IP>}:$PORT'"
    [ "${DCGM_DONE:-0}" -eq 1 ] && TARGETS="$TARGETS, '${IP:-<IP>}:$DCGM_PORT'"
    [ "${IPMI_DONE:-0}" -eq 1 ] && TARGETS="$TARGETS, '${IP:-<IP>}:$IPMI_PORT'"
    echo "    - targets: [$TARGETS]"
    echo
    echo "  :$PORT  — node_* (CPU, память, диск, сеть)"
    [ "${DCGM_DONE:-0}" -eq 1 ] && echo "  :$DCGM_PORT  — DCGM_FI_DEV_* (видеокарты)"
    [ "${IPMI_DONE:-0}" -eq 1 ] && echo "  :$IPMI_PORT  — ipmi_* (напряжения, вентиляторы, BMC)"
else
    echo "УСТАНОВКА ЗАВЕРШЕНА С ЗАМЕЧАНИЯМИ:"
    for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
    exit 1
fi
