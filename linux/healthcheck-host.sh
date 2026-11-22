#!/usr/bin/env bash
# healthcheck-host.sh — checagem rápida de um host Linux com Docker.
#
# Verifica: uso de disco, memória, load, containers parados/unhealthy/reiniciando,
# units do systemd com falha e build cache do Docker acumulado.
# Saída em texto (padrão) ou JSON (--json). Exit code: 0 OK, 1 ATENÇÃO, 2 CRÍTICO.
# Opcional: envia o resultado para um webhook se HEALTH_WEBHOOK_URL estiver definido.
#
# Uso:
#   ./healthcheck-host.sh                 # texto
#   ./healthcheck-host.sh --json          # JSON (para um coletor)
#   DISK_WARN=80 DISK_CRIT=90 ./healthcheck-host.sh
#
# Ignorar containers que terminam de propósito (ex.: serviço "migrate" one-shot):
#   IGNORE_EXITED_REGEX='-migrate-' ./healthcheck-host.sh

set -euo pipefail

DISK_WARN="${DISK_WARN:-80}"
DISK_CRIT="${DISK_CRIT:-90}"
MEM_WARN="${MEM_WARN:-90}"
BUILD_CACHE_WARN_GB="${BUILD_CACHE_WARN_GB:-10}"
IGNORE_EXITED_REGEX="${IGNORE_EXITED_REGEX:-^$}"
OUTPUT="text"
[[ "${1:-}" == "--json" ]] && OUTPUT="json"

status=0            # 0 ok, 1 warn, 2 crit
declare -a findings=()

add() {             # add <nivel 1|2> <mensagem>
  local lvl="$1"; shift
  findings+=("$([[ $lvl -eq 2 ]] && echo CRIT || echo WARN): $*")
  (( lvl > status )) && status=$lvl
  return 0
}

# --- Disco (ignora tmpfs/overlay) -------------------------------------------
while read -r use mount; do
  pct="${use%\%}"
  if   (( pct >= DISK_CRIT )); then add 2 "disco ${mount} em ${pct}%"
  elif (( pct >= DISK_WARN )); then add 1 "disco ${mount} em ${pct}%"
  fi
done < <(df -P -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk 'NR>1 {print $5, $6}')

# --- Memória ----------------------------------------------------------------
mem_pct=$(free | awk '/^Mem:/ { printf "%d", ($2-$7)*100/$2 }')
(( mem_pct >= MEM_WARN )) && add 1 "memória em uso ${mem_pct}%"

# --- Load (comparado ao nº de CPUs) -----------------------------------------
cpus=$(nproc)
load1=$(cut -d' ' -f1 /proc/loadavg)
if awk -v l="$load1" -v c="$cpus" 'BEGIN{exit !(l > c*2)}'; then
  add 1 "load ${load1} com ${cpus} CPU(s)"
fi

# --- systemd ----------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  while read -r unit; do
    [[ -n "$unit" ]] && add 2 "unit com falha: ${unit}"
  done < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
fi

# --- Docker -----------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # Parados com código != 0 (Exited (0) é fim normal de job one-shot)
  while IFS='|' read -r name st; do
    [[ "$name" =~ $IGNORE_EXITED_REGEX ]] && continue
    if [[ "$st" =~ ^Exited\ \(([0-9]+)\) ]] && [[ "${BASH_REMATCH[1]}" != "0" ]]; then
      add 2 "container ${name}: ${st}"
    fi
  done < <(docker ps -a --format '{{.Names}}|{{.Status}}')

  while read -r name; do
    [[ -n "$name" ]] && add 2 "container ${name}: unhealthy"
  done < <(docker ps --filter health=unhealthy --format '{{.Names}}')

  while read -r name; do
    [[ -n "$name" ]] && add 1 "container ${name}: reiniciando em loop"
  done < <(docker ps --filter status=restarting --format '{{.Names}}')

  # Containers sem política de restart (somem no próximo restart do daemon)
  while read -r name; do
    pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name")
    [[ "$pol" == "no" || -z "$pol" ]] && add 1 "container ${name} sem restart policy"
  done < <(docker ps --format '{{.Names}}')

  # Build cache recuperável (causa comum de disco cheio em host de build)
  # Docker mostra unidades decimais ("14.5GB", "512kB") -> tira o "B" e converte em SI
  cache_bytes=$(docker system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null \
    | awk '/^Build/ {sub(/B$/, "", $3); print $3}' | numfmt --from=si 2>/dev/null || echo 0)
  cache_gb=$(( ${cache_bytes:-0} / 1000000000 ))
  (( cache_gb >= BUILD_CACHE_WARN_GB )) && \
    add 1 "build cache recuperável: ${cache_gb} GB (docker builder prune -f)"
fi

# --- Saída ------------------------------------------------------------------
if   [[ $status -eq 0 ]]; then label="OK"
elif [[ $status -eq 1 ]]; then label="WARN"
else label="CRIT"
fi

if [[ "$OUTPUT" == "json" ]]; then
  printf '{"host":"%s","status":"%s","checked_at":"%s","findings":[' \
    "$(hostname)" "$label" "$(date -Is)"
  sep=""
  for f in "${findings[@]}"; do
    printf '%s"%s"' "$sep" "${f//\"/\\\"}"; sep=","
  done
  printf ']}\n'
else
  echo "[$label] $(hostname) — $(date '+%F %T')"
  for f in "${findings[@]}"; do echo "  - $f"; done
fi

# --- Webhook opcional (só quando há problema) ---------------------------------
if [[ -n "${HEALTH_WEBHOOK_URL:-}" && $status -gt 0 ]]; then
  body=$(printf '%s\n' "${findings[@]}")
  curl -fsS -m 10 -X POST -H 'Content-Type: text/plain' \
    --data-binary "[$label] $(hostname)"$'\n'"$body" \
    "$HEALTH_WEBHOOK_URL" >/dev/null || true
fi

exit "$status"
