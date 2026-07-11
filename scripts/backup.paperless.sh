#!/usr/bin/env sh
set -eu

# Backup script for a Paperless-ngx stack.
# Includes MariaDB dump + paperless bind-mounted filesystem data, checksums,
# optional SCP upload, and optional WhatsApp notification via host venv.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
COMPOSE_FILE_PATH="${COMPOSE_FILE_PATH:-$PROJECT_DIR/docker-compose.yml}"
COMPOSE_CMD="${COMPOSE_CMD:-docker compose --project-directory $PROJECT_DIR -f $COMPOSE_FILE_PATH}"
APP_NAME="${APP_NAME:-paperless}"
BACKUP_ROOT="${BACKUP_ROOT:-${TMPDIR:-/tmp}/paperless-backups}"
TMP_ROOT="${TMP_ROOT:-${TMPDIR:-/tmp}}"
LOCAL_KEEP="${LOCAL_KEEP:-}"
REMOTE_KEEP="${REMOTE_KEEP:-}"
REMOTE_TARGET="${REMOTE_TARGET:-}"
REMOTE_DIR="${REMOTE_DIR:-}"
SSH_KEY="${SSH_KEY:-}"
LOG_FILE="${LOG_FILE:-$PROJECT_DIR/logs/backup.paperless.log}"


echo $BACKUP_ROOT

# WhatsApp notification settings (host python venv)
WA_NOTIFY_NUMBER="${WA_NOTIFY_NUMBER:-}"
WA_NOTIFY_SRV="${WA_NOTIFY_SRV:-}"
WA_NOTIFY_PORT="${WA_NOTIFY_PORT:-}"
WA_PYTHON_BIN="${WA_PYTHON_BIN:-/home/joern/.venv/bin/python}"

# paperless host paths
PAPERLESS_DATA_DIR="${PAPERLESS_DATA_DIR:-/srv/data/paperless/data}"
PAPERLESS_MEDIA_DIR="${PAPERLESS_MEDIA_DIR:-/srv/data/paperless/media}"
PAPERLESS_EXPORT_DIR="${PAPERLESS_EXPORT_DIR:-/srv/data/paperless/export}"
PAPERLESS_CONSUME_DIR="${PAPERLESS_CONSUME_DIR:-/srv/data/paperless/consume}"
PAPERLESS_ENV_FILE="${PAPERLESS_ENV_FILE:-$PROJECT_DIR/.env}"

CHECK_CONFIG=0

now_utc="$(date -u +%Y%m%d-%H%M%S)"
run_id="${APP_NAME}-backup-${now_utc}"
work_dir="$TMP_ROOT/$run_id"
out_dir="$BACKUP_ROOT"
final_archive="$out_dir/${run_id}.tar.gz"

if [ "${1:-}" = "--check-config" ]; then
  CHECK_CONFIG=1
  shift
fi

if [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--check-config]" >&2
  exit 1
fi

log() {
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
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

notify_backup_result() {
  exit_code="$1"

  if [ -z "$WA_NOTIFY_NUMBER" ]; then
    return 0
  fi

  if [ -z "$WA_NOTIFY_SRV" ] || [ -z "$WA_NOTIFY_PORT" ]; then
    log "WARN: WA_NOTIFY_NUMBER set but WA_NOTIFY_SRV/WA_NOTIFY_PORT missing; skipping WA notification"
    return 0
  fi

  if [ ! -x "$WA_PYTHON_BIN" ]; then
    log "WARN: WA_PYTHON_BIN not executable: $WA_PYTHON_BIN"
    return 0
  fi

  result="successful"
  if [ "$exit_code" -ne 0 ]; then
    result="failed"
  fi

  wa_msg="$(date +%d.%m.%Y) paperless backup ${result}. run_id:${run_id}"

  set +e
  wa_output="$({
    WA_MSG="$wa_msg" WA_DEST="$WA_NOTIFY_NUMBER" WA_HOST="$WA_NOTIFY_SRV" WA_PORT_VAL="$WA_NOTIFY_PORT" \
      "$WA_PYTHON_BIN" -c 'import os; from wa_hack_cli import simple_send; simple_send(os.environ["WA_HOST"], int(os.environ["WA_PORT_VAL"]), os.environ["WA_DEST"], os.environ["WA_MSG"])'
  } 2>&1)"
  wa_status=$?
  set -e

  if [ "$wa_status" -eq 0 ] && ! printf '%s' "$wa_output" | grep -Eqi 'unable to connect|connection error'; then
    log "WA notification sent to configured destination"
  else
    log "WARN: WA notification failed"
    if [ -n "$wa_output" ]; then
      log "WARN: WA notification output: $wa_output"
    fi
  fi
}

finalize() {
  exit_code="$1"
  if [ "$CHECK_CONFIG" -eq 0 ]; then
    notify_backup_result "$exit_code"
  fi
  rm -rf "$work_dir"
}
trap 'finalize $?' EXIT

cd "$PROJECT_DIR"

env_file="$PROJECT_DIR/.env"
if [ -f "$env_file" ]; then
  # For paperless backups, values from .env should override existing defaults for these paths.
  env_backup_root="$(read_env_value BACKUP_ROOT "$env_file")"
  if [ -n "$env_backup_root" ]; then
    BACKUP_ROOT="$env_backup_root"
  fi
  env_tmp_root="$(read_env_value TMP_ROOT "$env_file")"
  if [ -n "$env_tmp_root" ]; then
    TMP_ROOT="$env_tmp_root"
  fi

  if [ -z "${REMOTE_TARGET:-}" ]; then
    REMOTE_TARGET="$(read_env_value REMOTE_TARGET "$env_file")"
  fi
  if [ -z "${REMOTE_DIR:-}" ]; then
    REMOTE_DIR="$(read_env_value REMOTE_DIR "$env_file")"
  fi
  if [ -z "${SSH_KEY:-}" ]; then
    SSH_KEY="$(read_env_value SSH_KEY "$env_file")"
  fi
  if [ -z "${LOCAL_KEEP:-}" ]; then
    LOCAL_KEEP="$(read_env_value LOCAL_KEEP "$env_file")"
  fi
  if [ -z "${REMOTE_KEEP:-}" ]; then
    REMOTE_KEEP="$(read_env_value REMOTE_KEEP "$env_file")"
  fi
  if [ -z "${WA_ADMIN_NUMBER:-}" ]; then
    WA_ADMIN_NUMBER="$(read_env_value WA_ADMIN_NUMBER "$env_file")"
  fi
  if [ -z "${WA_SRV:-}" ]; then
    WA_SRV="$(read_env_value WA_SRV "$env_file")"
  fi
  if [ -z "${WA_PORT:-}" ]; then
    WA_PORT="$(read_env_value WA_PORT "$env_file")"
  fi
  if [ -z "${WA_NOTIFY_NUMBER:-}" ]; then
    WA_NOTIFY_NUMBER="$(read_env_value WA_NOTIFY_NUMBER "$env_file")"
  fi
  if [ -z "${WA_NOTIFY_SRV:-}" ]; then
    WA_NOTIFY_SRV="$(read_env_value WA_NOTIFY_SRV "$env_file")"
  fi
  if [ -z "${WA_NOTIFY_PORT:-}" ]; then
    WA_NOTIFY_PORT="$(read_env_value WA_NOTIFY_PORT "$env_file")"
  fi
  if [ -z "${WA_PYTHON_BIN:-}" ]; then
    WA_PYTHON_BIN="$(read_env_value WA_PYTHON_BIN "$env_file")"
  fi
fi

LOCAL_KEEP="${LOCAL_KEEP:-3}"
REMOTE_KEEP="${REMOTE_KEEP:-12}"
REMOTE_DIR="${REMOTE_DIR:-/public/Backups/web-srv/paperless}"
WA_NOTIFY_NUMBER="${WA_NOTIFY_NUMBER:-${WA_ADMIN_NUMBER:-}}"
WA_NOTIFY_SRV="${WA_NOTIFY_SRV:-${WA_SRV:-}}"
WA_NOTIFY_PORT="${WA_NOTIFY_PORT:-${WA_PORT:-}}"

out_dir="$BACKUP_ROOT"
work_dir="$TMP_ROOT/$run_id"
final_archive="$out_dir/${run_id}.tar.gz"

REMOTE_DIR_NORM="${REMOTE_DIR%/}"
if [ -z "$REMOTE_DIR_NORM" ]; then
  REMOTE_DIR_NORM="/"
fi

REMOTE_DIR_SYNO_FALLBACK=""
if printf '%s' "$REMOTE_DIR_NORM" | grep -Eq '^/volume[0-9]+/'; then
  REMOTE_DIR_SYNO_FALLBACK="$(printf '%s' "$REMOTE_DIR_NORM" | sed -E 's#^/volume[0-9]+##')"
  if [ -z "$REMOTE_DIR_SYNO_FALLBACK" ]; then
    REMOTE_DIR_SYNO_FALLBACK="/"
  fi
fi

ssh_opts=""
if [ -n "$SSH_KEY" ]; then
  if [ ! -f "$SSH_KEY" ]; then
    log "ERROR: SSH_KEY file not found: $SSH_KEY"
    exit 1
  fi
  ssh_opts="-i $SSH_KEY"
fi

if [ "$CHECK_CONFIG" -eq 1 ]; then
  if $COMPOSE_CMD ps -q db >/dev/null 2>&1; then
    db_service_status="ok"
  else
    db_service_status="not-found-or-unreachable"
  fi

  if [ -n "$REMOTE_TARGET" ]; then
    remote_upload="enabled"
  else
    remote_upload="disabled"
  fi

  if [ -n "$WA_NOTIFY_NUMBER" ]; then
    wa_notify="enabled"
  else
    wa_notify="disabled"
  fi

  echo "backup config check"
  echo "project_dir=$PROJECT_DIR"
  echo "compose_file_path=$COMPOSE_FILE_PATH"
  echo "compose_cmd=$COMPOSE_CMD"
  echo "app_name=$APP_NAME"
  echo "backup_root=$BACKUP_ROOT"
  echo "tmp_root=$TMP_ROOT"
  echo "local_keep=$LOCAL_KEEP"
  echo "remote_keep=$REMOTE_KEEP"
  echo "remote_target=${REMOTE_TARGET:-<empty>}"
  echo "remote_dir=$REMOTE_DIR_NORM"
  echo "ssh_key=${SSH_KEY:-<empty>}"
  echo "paperless_data_dir=$PAPERLESS_DATA_DIR"
  echo "paperless_media_dir=$PAPERLESS_MEDIA_DIR"
  echo "paperless_export_dir=$PAPERLESS_EXPORT_DIR"
  echo "paperless_consume_dir=$PAPERLESS_CONSUME_DIR"
  echo "paperless_env_file=$PAPERLESS_ENV_FILE"
  echo "wa_python_bin=$WA_PYTHON_BIN"
  echo "wa_notify_number=${WA_NOTIFY_NUMBER:-<empty>}"
  echo "wa_notify_srv=${WA_NOTIFY_SRV:-<empty>}"
  echo "wa_notify_port=${WA_NOTIFY_PORT:-<empty>}"
  echo "remote_upload=$remote_upload"
  echo "wa_notification=$wa_notify"
  echo "db_service_status=$db_service_status"
  echo "result=ok"
  exit 0
fi

if [ ! -f "$COMPOSE_FILE_PATH" ]; then
  log "ERROR: compose file missing: $COMPOSE_FILE_PATH"
  exit 1
fi

for req_dir in "$PAPERLESS_DATA_DIR" "$PAPERLESS_MEDIA_DIR" "$PAPERLESS_EXPORT_DIR" "$PAPERLESS_CONSUME_DIR"; do
  if [ ! -d "$req_dir" ]; then
    log "ERROR: required directory missing: $req_dir"
    exit 1
  fi
done

if ! $COMPOSE_CMD ps -q db >/dev/null 2>&1; then
  log "ERROR: compose service 'db' not found"
  exit 1
fi

mkdir -p "$out_dir" "$(dirname "$LOG_FILE")" "$work_dir"

db_sql="$work_dir/db.sql"
db_sql_gz="$work_dir/db.sql.gz"
fs_tar="$work_dir/filesystem.tar.gz"
meta_txt="$work_dir/meta.txt"

log "Starting backup run $run_id"

log "Creating MariaDB dump"
$COMPOSE_CMD exec -T db sh -lc 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction --routines --events --databases paperless' > "$db_sql"
gzip -9 "$db_sql"

log "Packing paperless filesystem data"
tar -czf "$fs_tar" \
  "$PAPERLESS_DATA_DIR" \
  "$PAPERLESS_MEDIA_DIR" \
  "$PAPERLESS_EXPORT_DIR" \
  "$PAPERLESS_CONSUME_DIR"

if [ -f "$PAPERLESS_ENV_FILE" ]; then
  cp "$PAPERLESS_ENV_FILE" "$work_dir/docker-compose.env"
fi
cp "$COMPOSE_FILE_PATH" "$work_dir/compose.yml"

cat > "$meta_txt" <<EOF
run_id=$run_id
timestamp_utc=$now_utc
project_dir=$PROJECT_DIR
compose_file_path=$COMPOSE_FILE_PATH
compose_cmd=$COMPOSE_CMD
paperless_data_dir=$PAPERLESS_DATA_DIR
paperless_media_dir=$PAPERLESS_MEDIA_DIR
paperless_export_dir=$PAPERLESS_EXPORT_DIR
paperless_consume_dir=$PAPERLESS_CONSUME_DIR
paperless_env_file=$PAPERLESS_ENV_FILE
EOF

log "Writing checksum manifest"
(
  cd "$work_dir"
  manifest_items="db.sql.gz filesystem.tar.gz meta.txt compose.yml"
  if [ -f docker-compose.env ]; then
    manifest_items="$manifest_items docker-compose.env"
  fi
  # shellcheck disable=SC2086
  sha256sum $manifest_items > manifest.sha256
)

log "Creating final archive $final_archive"
tar_items="db.sql.gz filesystem.tar.gz meta.txt manifest.sha256 compose.yml"
if [ -f "$work_dir/docker-compose.env" ]; then
  tar_items="$tar_items docker-compose.env"
fi
# shellcheck disable=SC2086
tar -czf "$final_archive" -C "$work_dir" $tar_items

log "Pruning local backups (keep=$LOCAL_KEEP)"
ls -1dt "$out_dir"/${APP_NAME}-backup-*.tar.gz 2>/dev/null | awk "NR>$LOCAL_KEEP" | xargs -r rm -f

if [ -n "$REMOTE_TARGET" ]; then
  remote_dir_use="$REMOTE_DIR_NORM"
  remote_file="$remote_dir_use/$(basename "$final_archive")"
  log "Backup server: $REMOTE_TARGET"
  log "Remote backup directory: $remote_dir_use"
  log "Uploading backup to $remote_file"
  # shellcheck disable=SC2086
  scp $ssh_opts "$final_archive" "$REMOTE_TARGET:$remote_file"

  log "Pruning remote backups (keep=$REMOTE_KEEP)"
  # shellcheck disable=SC2086
  ssh $ssh_opts "$REMOTE_TARGET" "ls -1dt '$remote_dir_use'/${APP_NAME}-backup-*.tar.gz 2>/dev/null | awk 'NR>$REMOTE_KEEP' | xargs -r rm -f"
else
  log "REMOTE_TARGET not set; skipping remote upload"
fi

log "Backup complete: $final_archive"
