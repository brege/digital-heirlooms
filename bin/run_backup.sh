#!/bin/bash
set -euo pipefail

# ----------------------------------------
# 🧭 Resolve script base and config dir
# ----------------------------------------

BACKUPKIT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_ROOT_DEFAULT="$BACKUPKIT_HOME/config"
CONFIG_ROOT="$CONFIG_ROOT_DEFAULT"

# Check for --config=/some/path
for arg in "$@"; do
  case $arg in
    --config=*)
      CONFIG_ROOT="$(realpath "${arg#*=}")"
      shift
      ;;
  esac
done

# Try to source backup.env and let it override CONFIG_ROOT via CONFIG_DIR
ENV_FILE="$CONFIG_ROOT_DEFAULT/backup.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a  # Auto-export all variables
  source "$ENV_FILE"
  set +a
  CONFIG_ROOT="${CONFIG_DIR:-$CONFIG_ROOT}"
fi

# Derived paths
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
EXCLUDES_DIR="$CONFIG_ROOT/excludes"
HOOKS_DIR="$CONFIG_ROOT/hooks"

echo "Using machine configs from: $MACHINES_ENABLED_DIR"
echo "Using excludes: $EXCLUDES_DIR"

DEFAULT_EXCLUDE="$EXCLUDES_DIR/default.exclude"
echo "$DEFAULT_EXCLUDE"
if [[ -f "$DEFAULT_EXCLUDE" ]]; then
  echo "🔧 Applying global excludes from: $DEFAULT_EXCLUDE"
  default_exclude="--exclude-from=$DEFAULT_EXCLUDE"
else
  default_exclude=""
fi


REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}"
DRY_RUN="${DRY_RUN:-false}"
direct_remote_rsync=false
current_user=""
current_host=""
current_exclude=""
backup_paths=()
staged_dirs=()

declare -A target_roots

is_local_host() {
  [[ "$1" == "localhost" || "$1" == "$(hostname)" || "$1" == "$(hostname -f)" ]]
}

flush_backup() {
  [[ ${#backup_paths[@]} -eq 0 ]] && return

  for src_path in "${backup_paths[@]}"; do
    if [[ -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      dest_dir="${LOCAL_TARGET_BASE:-$HOME/Backup}/$current_user@$current_host"
      target_roots["$current_user@$current_host"]="$dest_dir"

      if is_local_host "$current_host"; then
        use_ssh=false
        src_path_expanded="$src_path"
      else
        use_ssh=true
        src_path_expanded="$current_user@$current_host:$src_path"
      fi

      mkdir -p "$dest_dir"

      rsync_cmd=(rsync -avzR --delete $default_exclude)
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      [[ -n "$current_exclude" && -f "$current_exclude" ]] && rsync_cmd+=(--exclude-from="$current_exclude")
      $use_ssh && rsync_cmd+=(-e ssh)
      rsync_cmd+=("$src_path_expanded" "$dest_dir")

      echo -e "\n📁 Rsync to local staging: ${rsync_cmd[*]}"
      "${rsync_cmd[@]}"

      staged_dirs+=("$current_user@$current_host")

      echo "🔁 Skipping direct remote rsync; will sync from local staging later"
      direct_remote_rsync=true

    elif [[ -z "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      use_ssh=true
      rsync_cmd=(rsync -avzR --delete $default_exclude)
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      [[ -n "$current_exclude" && -f "$current_exclude" ]] && rsync_cmd+=(--exclude-from="$current_exclude")

      target_roots["$current_user@$current_host"]="$REMOTE_TARGET_BASE/$current_user@$current_host"
      rsync_cmd+=(-e ssh "$src_path" "$REMOTE_TARGET_BASE/$current_user@$current_host/")

      echo -e "\n🌐 Direct remote rsync: ${rsync_cmd[*]}"
      "${rsync_cmd[@]}"

    else
      dest_dir="${LOCAL_TARGET_BASE:-$HOME/Backup}/$current_user@$current_host"
      target_roots["$current_user@$current_host"]="$dest_dir"

      if is_local_host "$current_host"; then
        use_ssh=false
        src_path_expanded="$src_path"
      else
        use_ssh=true
        src_path_expanded="$current_user@$current_host:$src_path"
      fi

      mkdir -p "$dest_dir"

      rsync_cmd=(rsync -avzR --delete $default_exclude)
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      [[ -n "$current_exclude" && -f "$current_exclude" ]] && rsync_cmd+=(--exclude-from="$current_exclude")
      $use_ssh && rsync_cmd+=(-e ssh)
      rsync_cmd+=("$src_path_expanded" "$dest_dir")

      echo -e "\n📁 Rsync to local staging: ${rsync_cmd[*]}"
      "${rsync_cmd[@]}"

      staged_dirs+=("$current_user@$current_host")
    fi
  done

  backup_paths=()
  current_exclude=""
}

# Read and process machine configuration files
for config_file in "$MACHINES_ENABLED_DIR"/*; do
  [[ -f "$config_file" ]] || continue

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[(.+)@(.+)\]$ ]]; then
      flush_backup
      current_user="${BASH_REMATCH[1]}"
      current_host="${BASH_REMATCH[2]}"
      current_exclude="$EXCLUDES_DIR/$current_user@$current_host"
      continue
    fi

    if [[ "$line" == src=* ]]; then
      raw_path="${line#src=}"
      shopt -s globstar
      expanded_path=$(eval echo "$raw_path")
      backup_paths+=($expanded_path)
    fi
  done < "$config_file"
done

flush_backup

# Sync staged directories if LOCAL_TARGET_BASE is set
if [[ -n "$REMOTE_TARGET_BASE" && "$direct_remote_rsync" == false && -n "${LOCAL_TARGET_BASE:-}" ]]; then
  declare -A seen
  for dir in "${staged_dirs[@]}"; do
    if [[ -n "${seen[$dir]:-}" ]]; then
      continue
    fi
    seen["$dir"]=1

    src="$LOCAL_TARGET_BASE/$dir/"
    dest="$REMOTE_TARGET_BASE/$dir/"
    rsync_cmd=(rsync -az --delete $default_exclude)
    [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
    rsync_cmd+=("$src" "$dest")

    echo -e "\n🚚 Rsyncing staged $dir to remote ..."
    echo "🔄 Rsync: ${rsync_cmd[*]}"
    "${rsync_cmd[@]}"
  done
fi

# Post-backup hooks
HOOKS_DIR="$CONFIG_ROOT/hooks"
if [[ -d "$HOOKS_DIR" ]]; then
  for hook in "$HOOKS_DIR"/*; do
    if [[ -x "$hook" ]]; then
      echo -e "\n🔧 Running post-backup hook: $hook"
      for dir in "${target_roots[@]}"; do
        "$hook" "$dir"
      done
    else
      echo -e "\n🔧 Skipping non-executable hook: $hook"
    fi
  done
else
  echo -e "\n🔎 No hooks directory at $HOOKS_DIR"
fi

echo -e "\n🎉 Backup complete!"

