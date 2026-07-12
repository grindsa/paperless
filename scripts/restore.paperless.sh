#!/usr/bin/env sh
set -eu

# Restore utility for archives created by scripts/backup.paperless.sh.
# Restores DB and paperless filesystem data.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
COMPOSE_FILE_PATH="${COMPOSE_FILE_PATH:-$PROJECT_DIR/docker-compose.yml}"
COMPOSE_CMD="${COMPOSE_CMD:-docker compose --project-directory $PROJECT_DIR -f $COMPOSE_FILE_PATH}"
TMP_ROOT="${TMP_ROOT:-${TMPDIR:-/tmp}}"
RESTORE_CONFIRM="${RESTORE_CONFIRM:-no}"
APP_NAME="${APP_NAME:-paperless}"
REMOTE_TARGET="${REMOTE_TARGET:-}"
REMOTE_DIR="${REMOTE_DIR:-}"
SSH_KEY="${SSH_KEY:-}"

PAPERLESS_DATA_DIR="${PAPERLESS_DATA_DIR:-/srv/data/paperless/data}"
PAPERLESS_MEDIA_DIR="${PAPERLESS_MEDIA_DIR:-/srv/data/paperless/media}"
PAPERLESS_EXPORT_DIR="${PAPERLESS_EXPORT_DIR:-/srv/data/paperless/export}"
PAPERLESS_CONSUME_DIR="${PAPERLESS_CONSUME_DIR:-/srv/data/paperless/consume}"

usage() {
  echo "Usage: $0 [--check-config] [--from-remote-latest] [/path/to/paperless-backup-YYYYmmdd-HHMMSS.tar.gz]"
  echo ""
  echo "Modes:"
  echo "  local archive           Provide archive path as argument"
  echo "  --from-remote-latest   Read .env, fetch latest remote backup, then restore"
  echo "  --check-config         Print resolved config and exit"
  echo "Set RESTORE_CONFIRM=yes to run a destructive restore."
}

# Parse one value from .env without executing the file.
read_env_value() {
  key="$1"
  file="$2"
  awk -v k="$key" '
    {
      line=$0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^#/) next

      if (line ~ "^" k "[[:space:]]*=") {
        sub("^" k "[[:space:]]*=[[:space:]]*", "", line)
      } else if (line ~ "^" k "[[:space:]]*:") {
        sub("^" k "[[:space:]]*:[[:space:]]*", "", line)
      } else {
        next
      }

      gsub(/^["\047]|["\047]$/, "", line)
      print line
      exit
    }
  ' "$file"
}

FROM_REMOTE_LATEST=0
CHECK_CONFIG=0
archive_path=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-config)
      CHECK_CONFIG=1
      ;;
    --from-remote-latest)
      FROM_REMOTE_LATEST=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [ -n "$archive_path" ]; then
        echo "ERROR: multiple archive paths provided" >&2
        usage
        exit 1
      fi
      archive_path="$1"
      ;;
  esac
  shift
done

if [ "$FROM_REMOTE_LATEST" -eq 1 ] && [ -n "$archive_path" ]; then
  echo "ERROR: provide either --from-remote-latest or a local archive path, not both" >&2
  usage
  exit 1
fi

if [ "$CHECK_CONFIG" -eq 0 ] && [ "$FROM_REMOTE_LATEST" -eq 0 ] && [ -z "$archive_path" ]; then
  usage
  exit 1
fi

cd "$PROJECT_DIR"

env_file="$PROJECT_DIR/.env"
if [ -f "$env_file" ]; then
  if [ -z "${REMOTE_TARGET:-}" ]; then
    REMOTE_TARGET="$(read_env_value REMOTE_TARGET "$env_file")"
  fi
  if [ -z "${REMOTE_DIR:-}" ]; then
    REMOTE_DIR="$(read_env_value REMOTE_DIR "$env_file")"
  fi
  if [ -z "${SSH_KEY:-}" ]; then
    SSH_KEY="$(read_env_value SSH_KEY "$env_file")"
  fi
fi

REMOTE_DIR_DEFAULTED="${REMOTE_DIR:-/public/Backups/web-srv/paperless}"
REMOTE_DIR_NORM="${REMOTE_DIR_DEFAULTED%/}"
if [ -z "$REMOTE_DIR_NORM" ]; then
  REMOTE_DIR_NORM="/"
fi

if [ "$CHECK_CONFIG" -eq 1 ]; then
  if [ -f "$COMPOSE_FILE_PATH" ]; then
    compose_file_status="ok"
  else
    compose_file_status="missing"
  fi

  if $COMPOSE_CMD ps -q db >/dev/null 2>&1; then
    db_service_status="ok"
  else
    db_service_status="not-found-or-unreachable"
  fi

  if [ "$FROM_REMOTE_LATEST" -eq 1 ]; then
    mode="from-remote-latest"
  else
    mode="local-archive"
  fi

  if [ -n "$REMOTE_TARGET" ]; then
    remote_target_status="set"
  else
    remote_target_status="empty"
  fi

  if [ -n "$SSH_KEY" ]; then
    if [ -f "$SSH_KEY" ]; then
      ssh_key_status="ok"
    else
      ssh_key_status="missing"
    fi
  else
    ssh_key_status="empty"
  fi

  if [ -n "$archive_path" ]; then
    if [ -f "$archive_path" ]; then
      archive_status="ok"
    else
      archive_status="missing"
    fi
  else
    archive_status="not-set"
  fi

  echo "restore config check"
  echo "project_dir=$PROJECT_DIR"
  echo "compose_file_path=$COMPOSE_FILE_PATH"
  echo "compose_cmd=$COMPOSE_CMD"
  echo "tmp_root=$TMP_ROOT"
  echo "mode=$mode"
  echo "archive_path=${archive_path:-<empty>}"
  echo "archive_status=$archive_status"
  echo "env_file=$env_file"
  echo "compose_file_status=$compose_file_status"
  echo "db_service_status=$db_service_status"
  echo "remote_target=${REMOTE_TARGET:-<empty>}"
  echo "remote_target_status=$remote_target_status"
  echo "remote_dir=$REMOTE_DIR_NORM"
  echo "ssh_key=${SSH_KEY:-<empty>}"
  echo "ssh_key_status=$ssh_key_status"
  echo "paperless_data_dir=$PAPERLESS_DATA_DIR"
  echo "paperless_media_dir=$PAPERLESS_MEDIA_DIR"
  echo "paperless_export_dir=$PAPERLESS_EXPORT_DIR"
  echo "paperless_consume_dir=$PAPERLESS_CONSUME_DIR"
  echo "restore_confirm=$RESTORE_CONFIRM"
  echo "result=ok"
  exit 0
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

if [ "$FROM_REMOTE_LATEST" -eq 1 ]; then
  REMOTE_DIR="$REMOTE_DIR_NORM"

  if [ -z "$REMOTE_TARGET" ]; then
    echo "ERROR: REMOTE_TARGET is required for --from-remote-latest" >&2
    exit 1
  fi

  ssh_opts=""
  if [ -n "$SSH_KEY" ]; then
    if [ ! -f "$SSH_KEY" ]; then
      echo "ERROR: SSH_KEY file not found: $SSH_KEY" >&2
      exit 1
    fi
    ssh_opts="-i $SSH_KEY"
  fi

  echo "Resolving latest backup archive on $REMOTE_TARGET:$REMOTE_DIR_NORM"
  remote_glob_primary="'$REMOTE_DIR_NORM'/${APP_NAME}-backup-*.tar.gz"
  remote_glob_synology=""
  case "$REMOTE_DIR_NORM" in
    /volume1/*)
      ;;
    *)
      remote_glob_synology="'/volume1$REMOTE_DIR_NORM'/${APP_NAME}-backup-*.tar.gz"
      ;;
  esac

  if [ -n "$remote_glob_synology" ]; then
    # shellcheck disable=SC2086
    latest_remote_archive="$(ssh $ssh_opts "$REMOTE_TARGET" "ls -1dt $remote_glob_primary $remote_glob_synology 2>/dev/null | head -n 1")"
  else
    # shellcheck disable=SC2086
    latest_remote_archive="$(ssh $ssh_opts "$REMOTE_TARGET" "ls -1dt $remote_glob_primary 2>/dev/null | head -n 1")"
  fi

  if [ -z "$latest_remote_archive" ]; then
    echo "ERROR: no backup archives found at $REMOTE_TARGET:$REMOTE_DIR_NORM" >&2
    exit 1
  fi

  echo "Fetching latest backup: $latest_remote_archive"
  # shellcheck disable=SC2086
  if ! scp $ssh_opts "$REMOTE_TARGET:$latest_remote_archive" "$work_dir/"; then
    case "$latest_remote_archive" in
      /volume1/*)
        latest_remote_archive_scp="${latest_remote_archive#/volume1}"
        echo "Retrying fetch without /volume1 prefix: $latest_remote_archive_scp"
        # shellcheck disable=SC2086
        if ! scp $ssh_opts "$REMOTE_TARGET:$latest_remote_archive_scp" "$work_dir/"; then
          echo "ERROR: unable to fetch latest backup archive from $REMOTE_TARGET" >&2
          exit 1
        fi
        ;;
      *)
        echo "ERROR: unable to fetch latest backup archive from $REMOTE_TARGET" >&2
        exit 1
        ;;
    esac
  fi

  archive_path="$work_dir/$(basename "$latest_remote_archive")"
fi

if [ ! -f "$archive_path" ]; then
  echo "ERROR: archive not found: $archive_path" >&2
  exit 1
fi

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

echo "Taking full stack down"
$COMPOSE_CMD down

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

