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
  tar_cmd=(echo "[DRY RUN] Would execute: tar -I zstd -cf") # Made dry run tar more explicit
  rsync_cmd+=(--dry-run)
}

# Ensure local archive dir exists if set
if [[ -n "$LOCAL_ARCHIVE_BASE" ]]; then
  echo "Archive: Ensuring local directory exists: $LOCAL_ARCHIVE_BASE"
  [[ "$DRY_RUN" == "true" ]] || mkdir -p "$LOCAL_ARCHIVE_BASE"
fi

# Ensure remote archive dir exists if set
if [[ -n "$REMOTE_ARCHIVE_BASE" ]]; then
  remote_user_host="${REMOTE_ARCHIVE_BASE%%:*}"
  remote_path="${REMOTE_ARCHIVE_BASE#*:}"
  echo "Archive: Ensuring remote directory exists: $REMOTE_ARCHIVE_BASE"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] Would execute: ssh $remote_user_host mkdir -p '$remote_path'"
  else
    ssh "$remote_user_host" "mkdir -p '$remote_path'"
  fi
fi

# Archive logic
if [[ -n "$LOCAL_ARCHIVE_BASE" && -n "$REMOTE_ARCHIVE_BASE" ]]; then
  echo "Archive: Creating local archive: $local_archive_path"
  "${tar_cmd[@]}" "$local_archive_path" -C "$local_source_dir" .

  echo "Archive: Syncing local archive to remote target: $REMOTE_ARCHIVE_BASE"
  "${rsync_cmd[@]}" "$local_archive_path" "$remote_archive_path"

elif [[ -n "$LOCAL_ARCHIVE_BASE" ]]; then
  echo "Archive: Creating local archive: $local_archive_path"
  "${tar_cmd[@]}" "$local_archive_path" -C "$local_source_dir" .

elif [[ -n "$REMOTE_ARCHIVE_BASE" && "$LOCAL_ARCHIVE_BASE" != "$REMOTE_ARCHIVE_BASE" ]]; then
  echo "Archive: Creating remote archive on $user_host for $REMOTE_ARCHIVE_BASE"
  
  # Extract remote user, base paths, and prepare the archive logic
  remote_user_host="${REMOTE_ARCHIVE_BASE%%:*}"
  remote_archive_base="${REMOTE_ARCHIVE_BASE#*:}"
  remote_base_path="${REMOTE_TARGET_BASE#*:}"

  echo "Archive Details: Remote user/host for archive destination: $remote_user_host"
  echo "Archive Details: Remote archive base directory: $remote_archive_base"
  echo "Archive Details: Full remote archive path: $REMOTE_ARCHIVE_BASE/$archive_name" # Corrected to use $REMOTE_ARCHIVE_BASE/$archive_name for consistency with how remote_archive_path is typically formed.
  echo "Archive Details: Remote source base path for archiving: $remote_base_path"
  
  # Forming the SSH command for remote archiving
  # Ensure $archive_name is used correctly for the remote path
  ssh_cmd="mkdir -p '$remote_archive_base' && tar -I zstd -cf '$remote_archive_base/$archive_name' -C '$remote_base_path' '$user_host/'"
  echo "Archive Command: SSH command for remote archiving: $ssh_cmd"
  echo "Archive: Executing remote archive creation via SSH."

  # Execute the command remotely via SSH (with dry run support)
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] Would execute: ssh $remote_user_host \"$ssh_cmd\""
  else
    ssh "$remote_user_host" "$ssh_cmd"
  fi
else
  echo "[WARN] Skipping archive: LOCAL_ARCHIVE_BASE or REMOTE_ARCHIVE_BASE not defined in configuration."
  echo
  echo "Please define these variables in your configuration to proceed:"
  echo
  echo "    Example: In ./config/backup.env (or your custom env file)"
  echo "    LOCAL_ARCHIVE_BASE=/storage/backups/archive"
  echo "    REMOTE_ARCHIVE_BASE=notroot@server:/storage/backups/archive"
  echo
fi
