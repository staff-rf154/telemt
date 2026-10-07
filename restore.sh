#!/usr/bin/env bash
# Восстановление telemt из локального эталона .backup/ внутри этого каталога.
#
# Зачем: каталог /opt/compose/proxy/telemt дважды очищался извне. Без
# docker-compose.yml Docker создаёт контейнер с дефолтами и без монтирования
# ./config:/etc/telemt, и telemt под uid 65532 (nonroot) не может создать
# /etc/telemt/config.toml:
#
#   Error: failed to create explicit config at /etc/telemt/config.toml:
#   Permission denied (os error 13)
#
# Эталон лежит рядом, в .backup/, поэтому восстановление не зависит ни от
# /opt/compose/telemt (исходники проекта), ни от /opt/backup.
#
# Ключ [access.users] default не перегенерируется: конфиг копируется как есть,
# все существующие клиенты продолжают работать.
#
# Использование:
#   ./restore.sh            # восстановить и пересоздать контейнер
#   ./restore.sh --files    # только разложить файлы, контейнер не трогать
#   ./restore.sh --check    # только проверить эталон и текущее состояние
#   ./restore.sh --backup   # обновить .backup из текущего рабочего каталога

set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$BASE/.backup"
UID_NUM=65532   # nonroot в образе ghcr.io/telemt/telemt

ok()   { echo "OK    $*"; }
warn() { echo "WARN  $*"; }
fail() { echo "FAIL  $*"; exit 1; }

check_source() {
    [[ -f "$SRC/docker-compose.yml" ]] || fail "нет $SRC/docker-compose.yml"
    [[ -f "$SRC/config/config.toml" ]] || fail "нет $SRC/config/config.toml"
    ok "эталон на месте: $SRC"
    ok "ключ в эталоне: $(grep -m1 -oE 'default = "[0-9a-f]{32}"' "$SRC/config/config.toml")"
}

copy_files() {
    cp -a "$SRC/docker-compose.yml" "$BASE/docker-compose.yml"
    mkdir -p "$BASE/config"
    cp -a "$SRC/config/." "$BASE/config/"
    # nonroot должен писать в config: каталог и файлы принадлежат uid 65532
    chown -R "${UID_NUM}:${UID_NUM}" "$BASE/config"
    ok "файлы разложены в $BASE"
}

verify() {
    local key
    key="$(grep -m1 -oE 'default = "[0-9a-f]{32}"' "$BASE/config/config.toml" || true)"
    [[ -n "$key" ]] || fail "в config.toml не найден ключ access.users"
    ok "ключ на месте: $key"

    docker compose -f "$BASE/docker-compose.yml" config -q \
        || fail "docker-compose.yml не проходит проверку"
    ok "compose-файл валиден"
}

start_container() {
    docker compose -f "$BASE/docker-compose.yml" up -d --force-recreate
    sleep 12
    local state health restarts
    state="$(docker inspect telemt --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
    health="$(docker inspect telemt --format '{{.State.Health.Status}}' 2>/dev/null || echo none)"
    restarts="$(docker inspect telemt --format '{{.RestartCount}}' 2>/dev/null || echo '?')"
    ok "контейнер: ${state}, health: ${health}, рестартов: ${restarts}"
    [[ "$state" == "running" ]] || fail "контейнер не запустился, смотрите: docker logs telemt"
    docker logs --tail 5 telemt 2>&1 | sed 's/^/      /'
}

report() {
    docker inspect telemt --format 'контейнер: {{.State.Status}}, health: {{.State.Health.Status}}, рестартов: {{.RestartCount}}' 2>/dev/null \
        || warn "контейнер telemt не найден"
    if [[ -f "$BASE/docker-compose.yml" ]]; then
        ok "docker-compose.yml на месте"
    else
        fail "docker-compose.yml отсутствует — нужен ./restore.sh"
    fi
    if [[ -f "$BASE/config/config.toml" ]]; then
        ok "config/config.toml на месте, ключ: $(grep -m1 -oE 'default = \"[0-9a-f]{32}\"' "$BASE/config/config.toml")"
    else
        fail "config/config.toml отсутствует — нужен ./restore.sh"
    fi
    docker inspect telemt --format '{{range .Mounts}}{{if eq .Destination "/etc/telemt"}}OK    монтирование {{.Source}} -> {{.Destination}}{{end}}{{end}}' 2>/dev/null \
        || true
}

case "${1:-}" in
    --check)
        check_source
        report
        ;;
    --files)
        check_source
        copy_files
        verify
        warn "контейнер не трогали"
        ;;
    --backup)
        [[ -f "$BASE/docker-compose.yml" ]] || fail "нет $BASE/docker-compose.yml"
        [[ -f "$BASE/config/config.toml" ]] || fail "нет $BASE/config/config.toml"
        rm -rf "$SRC"
        mkdir -p "$SRC"
        cp -a "$BASE/docker-compose.yml" "$SRC/docker-compose.yml"
        cp -a "$BASE/config" "$SRC/config"
        chown -R "${UID_NUM}:${UID_NUM}" "$SRC/config"
        ok "эталон обновлён из $BASE"
        ok "ключ: $(grep -m1 -oE 'default = \"[0-9a-f]{32}\"' "$SRC/config/config.toml")"
        ;;
    "")
        check_source
        copy_files
        verify
        start_container
        ;;
    *)
        echo "Использование: $0 [--files|--check|--backup]" >&2
        exit 1
        ;;
esac
