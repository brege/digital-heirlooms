#!/bin/bash

set -euo pipefail

# Define variables based on the target directory
TARGET_DIR="$1"  # May look like a local or remote path
user_host="$(basename "$TARGET_DIR")"

# Archive file name
archive_name="$user_host.tar.zst"
local_archive_path="$LOCAL_ARCHIVE_BASE/$archive_name"
remote_archive_path="$REMOTE_ARCHIVE_BASE/$archive_name"
local_source_dir="$LOCAL_TARGET_BASE/$user_host"

# DRY RUN flag logic
tar_cmd=(tar -I zstd -cf)
rsync_cmd=(rsync -avz)
[[ "$DRY_RUN" == "true" ]] && {
  tar_cmd=(echo "[DRY RUN] tar -I zstd -cf")
  rsync_cmd+=(--dry-run)
}

# 🔧 Ensure local archive dir exists if set
if [[ -n "$LOCAL_ARCHIVE_BASE" ]]; then
  echo "📂 Ensuring local archive directory exists: $LOCAL_ARCHIVE_BASE"
  [[ "$DRY_RUN" == "true" ]] || mkdir -p "$LOCAL_ARCHIVE_BASE"
fi

# 🔧 Ensure remote archive dir exists if set
if [[ -n "$REMOTE_ARCHIVE_BASE" ]]; then
  remote_user_host="${REMOTE_ARCHIVE_BASE%%:*}"
  remote_path="${REMOTE_ARCHIVE_BASE#*:}"
  echo "📂 Ensuring remote archive directory exists: $REMOTE_ARCHIVE_BASE"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] ssh $remote_user_host mkdir -p '$remote_path'"
  else
    ssh "$remote_user_host" "mkdir -p '$remote_path'"
  fi
fi

# 🧠 Archive logic
if [[ -n "$LOCAL_ARCHIVE_BASE" && -n "$REMOTE_ARCHIVE_BASE" ]]; then
  echo "📦 Creating local archive: $local_archive_path"
  "${tar_cmd[@]}" "$local_archive_path" -C "$local_source_dir" .

  echo "🌐 Syncing archive to remote: $REMOTE_ARCHIVE_BASE"
  "${rsync_cmd[@]}" "$local_archive_path" "$remote_archive_path"

elif [[ -n "$LOCAL_ARCHIVE_BASE" ]]; then
  echo "📦 Creating local archive: $local_archive_path"
  "${tar_cmd[@]}" "$local_archive_path" -C "$local_source_dir" .

elif [[ -n "$REMOTE_ARCHIVE_BASE" && "$LOCAL_ARCHIVE_BASE" != "$REMOTE_ARCHIVE_BASE" ]]; then
  echo "📦 Creating remote archive on host: $user_host"
  
  # Extract remote user, base paths, and prepare the archive logic
  remote_user_host="${REMOTE_ARCHIVE_BASE%%:*}"
  remote_archive_base="${REMOTE_ARCHIVE_BASE#*:}"
  remote_base_path="${REMOTE_TARGET_BASE#*:}"

  echo "remote_user_host: $remote_user_host"
  echo "remote_archive_base: $remote_archive_base"
  echo "remote_archive_path: $remote_archive_path"
  echo "remote_base_path: $remote_base_path"
  
  # Forming the SSH command for remote archiving
  ssh_cmd="mkdir -p '$remote_archive_base' && tar -I zstd -cf '$remote_archive_base/$archive_name' -C '$remote_base_path' '$user_host/'"
  echo "ssh_cmd: $ssh_cmd"
  echo "Executing remote archive command: ssh $remote_user_host \"$ssh_cmd\""

  # Execute the command remotely via SSH (with dry run support)
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] ssh $remote_user_host \"$ssh_cmd\""
  else
    ssh "$remote_user_host" "$ssh_cmd"
  fi
else
  echo "🛑 Skipping archive: No LOCAL_ARCHIVE_BASE or REMOTE_ARCHIVE_BASE defined."
  echo
  echo "Please define these variables in your configuration to proceed:"
  echo
  echo "    Example: In ./config/backup.env (or your custom env file)"
  echo "    LOCAL_ARCHIVE_BASE=/storage/backups/archive"
  echo "    REMOTE_ARCHIVE_BASE=notroot@server:/storage/backups/archive"
  echo
fi


