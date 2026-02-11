#!/usr/bin/env bash
set -euo pipefail

HOST="prodft30-overlord0.druid.singular.net"
REMOTE_BASE="/home/ubuntu/druid"
LOCAL_ROOT="$(pwd)"

K8S_JAR="$LOCAL_ROOT/extensions-contrib/kubernetes-overlord-extensions/target/druid-kubernetes-overlord-extensions-30.0.0.jar"
MSQ_JAR="$LOCAL_ROOT/extensions-core/multi-stage-query/target/druid-multi-stage-query-30.0.0.jar"
K8S_DEPS_DIR="$LOCAL_ROOT/extensions-contrib/kubernetes-overlord-extensions/target/dependency"

K8S_REMOTE_DIR="$REMOTE_BASE/extensions/druid-kubernetes-overlord-extensions"
MSQ_REMOTE_DIR="$REMOTE_BASE/extensions/druid-multi-stage-query"

DO_COPY_EXT=false
DO_COPY_DEPS=false
DO_RESTART=false
DO_REVERT=false
DO_BACKUP=false
DO_BACKUP_ONLY=false
DO_SKIP_BACKUP=false
DO_VERBOSE=false
DO_TAIL_LOG=false

usage() {
  cat <<EOF
Usage: $0 [flags]

Flags:
  --copy-extensions     Copy k8s + msq extension jars
  --copy-deps           Copy k8s runtime dependency jars (target/dependency/*.jar)
  --restart             Restart overlord via supervisorctl
  --revert              Revert to latest backup on server
  --backup              Create backups on server
  --backup-only         Create backups and exit
  --no-backup           Skip backups (even when copying)
  --verbose             Echo commands as they run
  --tail-log            Tail latest Overlord stdout log

Optional overrides:
  --host <host>         Override SSH host (default: $HOST)
  --remote-base <path>  Override remote druid base dir (default: $REMOTE_BASE)
  --local-root <path>   Override local repo root (default: $LOCAL_ROOT)

Examples:
  $0 --copy-extensions --copy-deps --restart
  $0 --revert --restart
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy-extensions) DO_COPY_EXT=true; shift;;
    --copy-deps) DO_COPY_DEPS=true; shift;;
    --restart) DO_RESTART=true; shift;;
    --revert) DO_REVERT=true; shift;;
    --backup) DO_BACKUP=true; shift;;
    --backup-only) DO_BACKUP_ONLY=true; shift;;
    --no-backup) DO_SKIP_BACKUP=true; shift;;
    --verbose) DO_VERBOSE=true; shift;;
    --tail-log) DO_TAIL_LOG=true; shift;;
    --host) HOST="$2"; shift 2;;
    --remote-base) REMOTE_BASE="$2"; shift 2;;
    --local-root) LOCAL_ROOT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

# Recompute paths if overrides used
K8S_JAR="$LOCAL_ROOT/extensions-contrib/kubernetes-overlord-extensions/target/druid-kubernetes-overlord-extensions-30.0.0.jar"
MSQ_JAR="$LOCAL_ROOT/extensions-core/multi-stage-query/target/druid-multi-stage-query-30.0.0.jar"
K8S_DEPS_DIR="$LOCAL_ROOT/extensions-contrib/kubernetes-overlord-extensions/target/dependency"

K8S_REMOTE_DIR="$REMOTE_BASE/extensions/druid-kubernetes-overlord-extensions"
MSQ_REMOTE_DIR="$REMOTE_BASE/extensions/druid-multi-stage-query"

timestamp() { date +%Y%m%d-%H%M%S; }

run_cmd() {
  if $DO_VERBOSE; then
    echo "+ $*"
  fi
  "$@"
}

remote_backup() {
  local ts
  ts="$(timestamp)"
  echo "Creating backups on $HOST with timestamp $ts..."
  echo "Backup base directory: $REMOTE_BASE/extensions"
  echo "Backup targets:"
  echo "  - $K8S_REMOTE_DIR"
  echo "  - $MSQ_REMOTE_DIR"
  if $DO_VERBOSE; then
    echo "+ ssh $HOST bash <<EOF"
  fi
  ssh "$HOST" bash <<EOF
set -e
cd "$REMOTE_BASE/extensions"
echo "Remote working dir: \$(pwd)"
echo "Backup name suffix: $ts"
if [ -d "$(basename "$K8S_REMOTE_DIR")" ]; then
  cp -a "$(basename "$K8S_REMOTE_DIR")" "$(basename "$K8S_REMOTE_DIR").backup-$ts"
  echo "Backed up: $(basename "$K8S_REMOTE_DIR") -> $(basename "$K8S_REMOTE_DIR").backup-$ts"
  echo "Files in backup ($(basename "$K8S_REMOTE_DIR").backup-$ts):"
  ls -lh "$(basename "$K8S_REMOTE_DIR").backup-$ts" | sed -n '1,200p'
else
  echo "Skip: $(basename "$K8S_REMOTE_DIR") not found"
fi
if [ -d "$(basename "$MSQ_REMOTE_DIR")" ]; then
  cp -a "$(basename "$MSQ_REMOTE_DIR")" "$(basename "$MSQ_REMOTE_DIR").backup-$ts"
  echo "Backed up: $(basename "$MSQ_REMOTE_DIR") -> $(basename "$MSQ_REMOTE_DIR").backup-$ts"
  echo "Files in backup ($(basename "$MSQ_REMOTE_DIR").backup-$ts):"
  ls -lh "$(basename "$MSQ_REMOTE_DIR").backup-$ts" | sed -n '1,200p'
else
  echo "Skip: $(basename "$MSQ_REMOTE_DIR") not found"
fi
EOF
}

revert_latest() {
  echo "Reverting to latest backups on $HOST..."
  if $DO_VERBOSE; then
    echo "+ ssh $HOST bash <<EOF"
  fi
  ssh "$HOST" bash <<EOF
set -e
cd "$REMOTE_BASE/extensions"

latest_k8s="\$(ls -dt druid-kubernetes-overlord-extensions.backup-* 2>/dev/null | head -1 || true)"
latest_msq="\$(ls -dt druid-multi-stage-query.backup-* 2>/dev/null | head -1 || true)"

if [ -z "\$latest_k8s" ] && [ -z "\$latest_msq" ]; then
  echo "No backups found. Abort."
  exit 1
fi

if [ -n "\$latest_k8s" ]; then
  rm -rf druid-kubernetes-overlord-extensions
  mv "\$latest_k8s" druid-kubernetes-overlord-extensions
  echo "Restored \$latest_k8s"
fi

if [ -n "\$latest_msq" ]; then
  rm -rf druid-multi-stage-query
  mv "\$latest_msq" druid-multi-stage-query
  echo "Restored \$latest_msq"
fi
EOF
}

if $DO_REVERT; then
  revert_latest
fi

if $DO_BACKUP_ONLY || $DO_BACKUP || (( $DO_COPY_EXT || $DO_COPY_DEPS ) && ! $DO_SKIP_BACKUP ); then
  remote_backup
fi

if $DO_BACKUP_ONLY; then
  echo "Backup completed. Exiting due to --backup-only."
  exit 0
fi

if $DO_COPY_EXT; then
  echo "Copying extension jars..."
  run_cmd scp "$K8S_JAR" "$HOST:$K8S_REMOTE_DIR/"
  run_cmd scp "$MSQ_JAR" "$HOST:$MSQ_REMOTE_DIR/"
fi

if $DO_COPY_DEPS; then
  echo "Copying k8s dependency jars..."
  run_cmd scp "$K8S_DEPS_DIR"/*.jar "$HOST:$K8S_REMOTE_DIR/"
fi

if $DO_RESTART; then
  echo "Restarting overlord..."
  run_cmd ssh "$HOST" "sudo supervisorctl restart overlord"
fi

if $DO_TAIL_LOG; then
  echo "Tailing latest Overlord stdout log..."
  run_cmd ssh "$HOST" "ls -t /logs/druid/overlord-stdout--*.log 2>/dev/null | head -1 | xargs -r sudo tail -n 10 -f"
fi

echo "Done."
