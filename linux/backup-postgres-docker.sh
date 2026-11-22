#!/usr/bin/env bash
# backup-postgres-docker.sh — dump lógico de um PostgreSQL que roda em container.
#
# - pg_dump em formato custom (-Fc), compactado, restaurável com pg_restore
# - checksum SHA-256 ao lado de cada dump
# - teste de integridade (pg_restore --list) antes de considerar o backup válido
# - retenção local por dias
# - cópia para FORA do host (rsync/ssh ou pasta montada) — backup no mesmo disco
#   do banco não é backup
# - lock para não rodar duas vezes ao mesmo tempo
#
# Configuração por variáveis (ou arquivo /etc/default/pg-backup):
#   PG_CONTAINER=app-db         nome do container
#   PG_USER=app                 usuário do banco
#   PG_DATABASES="app"          lista separada por espaço (vazio = todos)
#   BACKUP_DIR=/var/backups/pg
#   RETENTION_DAYS=14
#   OFFSITE_TARGET=backup@backup-host.example.internal:/srv/backups/app-server/
#   MIN_FREE_GB=2
#
# Restaurar:
#   docker exec -i app-db pg_restore -U app -d app --clean --if-exists < arquivo.dump

set -euo pipefail

if [[ -f /etc/default/pg-backup ]]; then
  # shellcheck source=/dev/null
  . /etc/default/pg-backup
fi

PG_CONTAINER="${PG_CONTAINER:?defina PG_CONTAINER}"
PG_USER="${PG_USER:-postgres}"
PG_DATABASES="${PG_DATABASES:-}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/pg}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
OFFSITE_TARGET="${OFFSITE_TARGET:-}"
MIN_FREE_GB="${MIN_FREE_GB:-2}"

ts="$(date +%Y%m%d-%H%M%S)"
dest="${BACKUP_DIR}/${PG_CONTAINER}"
log() { echo "$(date '+%F %T') [pg-backup] $*"; }

mkdir -p "$dest"
chmod 700 "$BACKUP_DIR"

# Lock (evita sobreposição se um dump demorar mais que o intervalo do timer)
exec 9>"${BACKUP_DIR}/.lock"
flock -n 9 || { log "já existe um backup em andamento, saindo"; exit 0; }

# Espaço livre mínimo
free_gb=$(df -P --block-size=1G "$BACKUP_DIR" | awk 'NR==2 {print $4}')
if (( free_gb < MIN_FREE_GB )); then
  log "ERRO: só ${free_gb} GB livres em ${BACKUP_DIR} (mínimo ${MIN_FREE_GB})"
  exit 1
fi

# Container precisa estar saudável
docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -q \
  || { log "ERRO: banco em ${PG_CONTAINER} não está pronto"; exit 1; }

if [[ -z "$PG_DATABASES" ]]; then
  PG_DATABASES=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -Atc \
    "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'")
fi

failed=0
for db in $PG_DATABASES; do
  file="${dest}/${db}-${ts}.dump"
  log "dump de ${db} -> ${file}"
  if docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -Fc -Z 6 "$db" > "${file}.partial"; then
    # Valida o arquivo antes de promover (dump truncado não pode virar "backup bom")
    if docker exec -i "$PG_CONTAINER" pg_restore --list < "${file}.partial" >/dev/null; then
      mv "${file}.partial" "$file"
      sha256sum "$file" > "${file}.sha256"
      log "ok ${db} ($(du -h "$file" | cut -f1))"
    else
      log "ERRO: dump de ${db} inválido"; rm -f "${file}.partial"; failed=1
    fi
  else
    log "ERRO: pg_dump de ${db} falhou"; rm -f "${file}.partial"; failed=1
  fi
done

# Retenção
find "$dest" -type f \( -name '*.dump' -o -name '*.sha256' \) -mtime +"$RETENTION_DAYS" -print -delete \
  | sed 's/^/  removido: /' || true

# Cópia para fora do host
if [[ -n "$OFFSITE_TARGET" ]]; then
  log "copiando para ${OFFSITE_TARGET}"
  if [[ "$OFFSITE_TARGET" == *:* ]]; then
    rsync -a --partial --timeout=300 "$dest/" "${OFFSITE_TARGET%/}/${PG_CONTAINER}/" || failed=1
  else
    mkdir -p "${OFFSITE_TARGET%/}/${PG_CONTAINER}"
    cp -u "$dest"/* "${OFFSITE_TARGET%/}/${PG_CONTAINER}/" || failed=1
  fi
fi

(( failed )) && { log "terminou COM ERROS"; exit 1; }
log "terminou ok"
