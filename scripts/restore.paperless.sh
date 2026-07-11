#!/usr/bin/env sh
set -eu

# Restore utility for archives created by scripts/backup.paperless.sh.
# Restores DB and paperless filesystem data.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
COMPOSE_FILE_PATH="${COMPOSE_FILE_PATH:-$PROJECT_DIR/paperless-compopse.yml}"
COMPOSE_CMD="${COMPOSE_CMD:-docker compose --project-directory $PROJECT_DIR -f $COMPOSE_FILE_PATH}"
TMP_ROOT="${TMP_ROOT:-${TMPDIR:-/tmp}}"
RESTORE_CONFIRM="${RESTORE_CONFIRM:-no}"

PAPERLESS_DATA_DIR="${PAPERLESS_DATA_DIR:-/srv/data/paperless/data}"
PAPERLESS_MEDIA_DIR="${PAPERLESS_MEDIA_DIR:-/srv/data/paperless/media}"
PAPERLESS_EXPORT_DIR="${PAPERLESS_EXPORT_DIR:-/srv/data/paperless/export}"
PAPERLESS_CONSUME_DIR="${PAPERLESS_CONSUME_DIR:-/srv/data/paperless/consume}"

usage() {
  echo "Usage: $0 /path/to/paperless-backup-YYYYmmdd-HHMMSS.tar.gz"
  echo "Set RESTORE_CONFIRM=yes to run a destructive restore."
}

if [ "${1:-}" = "" ]; then
  usage
  exit 1
fi

archive_path="$1"

if [ ! -f "$archive_path" ]; then
  echo "ERROR: archive not found: $archive_path" >&2
  exit 1
fi

if [ "$RESTORE_CONFIRM" != "yes" ]; then
  echo "ERROR: restore is destructive. Re-run with RESTORE_CONFIRM=yes" >&2
  exit 1
fi

if [ ! -f "$COMPOSE_FILE_PATH" ]; then
  echo "ERROR: compose file missing: $COMPOSE_FILE_PATH" >&2
  exit 1
fi

work_dir="$TMP_ROOT/restore-paperless-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$work_dir"
trap 'rm -rf "$work_dir"' EXIT INT TERM

cd "$PROJECT_DIR"

echo "Extracting archive to $work_dir"
tar -xzf "$archive_path" -C "$work_dir"

for required in db.sql.gz filesystem.tar.gz manifest.sha256; do
  if [ ! -f "$work_dir/$required" ]; then
    echo "ERROR: missing $required in backup archive" >&2
    exit 1
  fi
done

echo "Validating checksum manifest"
(
  cd "$work_dir"
  sha256sum -c manifest.sha256
)

echo "Stopping paperless services"
$COMPOSE_CMD stop paperless db broker

echo "Restoring filesystem data"
mkdir -p "$PAPERLESS_DATA_DIR" "$PAPERLESS_MEDIA_DIR" "$PAPERLESS_EXPORT_DIR" "$PAPERLESS_CONSUME_DIR"
rm -rf "$PAPERLESS_DATA_DIR"/* "$PAPERLESS_MEDIA_DIR"/* "$PAPERLESS_EXPORT_DIR"/* "$PAPERLESS_CONSUME_DIR"/*
tar -xzf "$work_dir/filesystem.tar.gz" -C /

echo "Starting db service"
$COMPOSE_CMD up -d db

echo "Waiting for db to accept connections"
$COMPOSE_CMD exec -T db sh -lc 'for i in $(seq 1 60); do mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'

echo "Restoring database"
gunzip -c "$work_dir/db.sql.gz" | $COMPOSE_CMD exec -T db sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'

echo "Starting paperless services"
$COMPOSE_CMD up -d broker paperless

echo "Restore completed successfully."

