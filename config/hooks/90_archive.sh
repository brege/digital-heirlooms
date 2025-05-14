#!/bin/bash

set -euo pipefail

# --- Function Definition ---
# Function to create a local archive with optional progress bar via pv
_create_local_archive_with_progress() {
  local archive_path="$1"
  local source_dir_for_tar="$2" # This is the TARGET_DIR passed to the script
  # DRY_RUN is an environment variable, tar_cmd array is already set based on it
  # local dry_run_active="${DRY_RUN:-false}" # Not strictly needed if using pre-set tar_cmd

  echo "Archive: Creating local archive: $archive_path from $source_dir_for_tar"

  # The tar_cmd array is (echo "[DRY RUN] Would execute: tar -I zstd -cf") if DRY_RUN is true
  # or (tar -I zstd -cf) if DRY_RUN is false.
  if [[ "${tar_cmd[0]}" == "echo" ]]; then # Check if it's a dry run echo command
    "${tar_cmd[@]}" "$archive_path" -C "$(dirname "$source_dir_for_tar")" "$(basename "$source_dir_for_tar")"
  else
    # Actual execution (not a dry run echo)
    if command -v pv &> /dev/null; then
      echo "Archive: pv found, attempting progress bar for local archiving."
      total_size=$(du -sb "$source_dir_for_tar" | awk '{print $1}')
      if [[ -z "$total_size" || ! "$total_size" =~ ^[0-9]+$ || "$total_size" -eq 0 ]]; then
          echo "[WARN] Archive: Could not determine size of '$source_dir_for_tar' or size is 0. Archiving without pv progress."
          # Use the actual tar command from tar_cmd_base (which is 'tar -I zstd -cf')
          tar -I zstd -cf "$archive_path" -C "$(dirname "$source_dir_for_tar")" "$(basename "$source_dir_for_tar")"
      else
          (cd "$(dirname "$source_dir_for_tar")" && tar -cf - "$(basename "$source_dir_for_tar")" | pv -N "Archiving $(basename "$source_dir_for_tar")" -s "$total_size" -ptebar | zstd -T0 > "$archive_path")
      fi
    else
      echo "Archive: pv not found. Archiving locally without progress bar."
      # Use the actual tar command from tar_cmd_base
      tar -I zstd -cf "$archive_path" -C "$(dirname "$source_dir_for_tar")" "$(basename "$source_dir_for_tar")"
    fi
    echo "Archive: Local archive created: $local_archive_path"
  fi
}
# --- End Function Definition ---

# Define variables based on the target directory
TARGET_DIR="$1"  # This is the path to the backed-up data, e.g., /path/to/LOCAL_TARGET_BASE/user@host
user_host="$(basename "$TARGET_DIR")"

# Archive file name
archive_name="$user_host.tar.zst"
local_archive_path="${LOCAL_ARCHIVE_BASE%/}/$archive_name" # Ensure no double slashes
remote_archive_path="${REMOTE_ARCHIVE_BASE%/}/$archive_name" # Ensure no double slashes
# local_source_dir was "$LOCAL_TARGET_BASE/$user_host" in your script.
# For local archiving, TARGET_DIR *is* the source directory.

# DRY RUN flag logic
tar_cmd=(tar -I zstd -cf) # Default actual command
rsync_cmd=(rsync -avz)    # Default actual command
if [[ "${DRY_RUN:-false}" == "true" ]]; then # DRY_RUN is an environment variable
  tar_cmd=(echo "[DRY RUN] Would execute: tar -I zstd -cf")
  rsync_cmd+=(--dry-run)
fi

# Ensure local archive dir exists if set
if [[ -n "${LOCAL_ARCHIVE_BASE:-}" ]]; then
  echo "Archive: Ensuring local directory exists: $LOCAL_ARCHIVE_BASE"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo "[DRY RUN] Would execute: mkdir -p \"$LOCAL_ARCHIVE_BASE\""
  else
    mkdir -p "$LOCAL_ARCHIVE_BASE"
  fi
fi

# Ensure remote archive dir exists if set
if [[ -n "${REMOTE_ARCHIVE_BASE:-}" ]]; then
  if [[ "$REMOTE_ARCHIVE_BASE" == *":"* ]]; then
    remote_user_host_for_mkdir="${REMOTE_ARCHIVE_BASE%%:*}"
    remote_path_for_mkdir="${REMOTE_ARCHIVE_BASE#*:}"
    # Ensure remote_path_for_mkdir doesn't include the filename part if present
    remote_path_for_mkdir="${remote_path_for_mkdir%/*}" 
    if [[ -n "$remote_user_host_for_mkdir" && -n "$remote_path_for_mkdir" ]]; then
        echo "Archive: Ensuring remote directory exists: $remote_user_host_for_mkdir:$remote_path_for_mkdir"
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo "[DRY RUN] Would execute: ssh $remote_user_host_for_mkdir mkdir -p '$remote_path_for_mkdir'"
        else
            ssh "$remote_user_host_for_mkdir" "mkdir -p '$remote_path_for_mkdir'"
        fi
    fi
  else
      echo "Archive: Ensuring (local) remote archive directory exists: $REMOTE_ARCHIVE_BASE"
      if [[ "${DRY_RUN:-false}" == "true" ]]; then
          echo "[DRY RUN] Would execute: mkdir -p \"$REMOTE_ARCHIVE_BASE\""
      else
          mkdir -p "$REMOTE_ARCHIVE_BASE"
      fi
  fi
fi

# Archive logic
if [[ -n "${LOCAL_ARCHIVE_BASE:-}" && -n "${REMOTE_ARCHIVE_BASE:-}" ]]; then
  # Call the function to create the local archive
  _create_local_archive_with_progress "$local_archive_path" "$TARGET_DIR"
  # To revert to the old method, comment out the line above and uncomment the line below:
  # "${tar_cmd[@]}" "$local_archive_path" -C "$TARGET_DIR" . # Original used -C "$local_source_dir" which was $LOCAL_TARGET_BASE/$user_host. TARGET_DIR is more direct.

  echo "Archive: Syncing local archive to remote target: $REMOTE_ARCHIVE_BASE" # Your original used REMOTE_ARCHIVE_BASE here
  # Build the rsync command for this operation
  rsync_op_cmd=("${rsync_cmd[@]}") # Start with base (e.g. rsync -avz or the dry-run echo version)
  if [[ "${rsync_cmd[0]}" != "echo" && "${DRY_RUN:-false}" != "true" ]]; then # Add progress if not a dry run echo
      rsync_op_cmd=(rsync -avz --info=progress2) # Rebuild if not dry run echo
      # If DRY_RUN was true, rsync_cmd already has --dry-run, so no need to re-add explicitly here
      # unless rsync_cmd was just (rsync -avz) and DRY_RUN was true, then it should be added.
      # The original rsync_cmd array already handles the --dry-run addition.
  elif [[ "${rsync_cmd[0]}" == "echo" ]]; then # It's a dry run echo
      : # Do nothing, command is already correct
  else # It's a real command, but DRY_RUN is false, ensure progress is there
      rsync_op_cmd=(rsync -avz --info=progress2)
  fi
  # If DRY_RUN is true, rsync_cmd already includes --dry-run.
  # If DRY_RUN is false, we want to ensure --info=progress2 is there.
  # Let's simplify:
  final_rsync_for_archive_push=()
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
      final_rsync_for_archive_push=("${rsync_cmd[@]}") # rsync_cmd already has --dry-run
  else
      final_rsync_for_archive_push=(rsync -avz --info=progress2) # Add progress for actual run
  fi
  final_rsync_for_archive_push+=("$local_archive_path" "$remote_archive_path")
  "${final_rsync_for_archive_push[@]}"


elif [[ -n "$LOCAL_ARCHIVE_BASE" ]]; then
  # Call the function to create the local archive
  _create_local_archive_with_progress "$local_archive_path" "$TARGET_DIR"
  # To revert to the old method, comment out the line above and uncomment the line below:
  # "${tar_cmd[@]}" "$local_archive_path" -C "$TARGET_DIR" . # Original used -C "$local_source_dir"

elif [[ -n "$REMOTE_ARCHIVE_BASE" && "$LOCAL_ARCHIVE_BASE" != "$REMOTE_ARCHIVE_BASE" ]]; then
  echo "Archive: Creating remote archive on $user_host for $REMOTE_ARCHIVE_BASE"
  
  remote_user_host="${REMOTE_ARCHIVE_BASE%%:*}"
  remote_archive_base_on_remote="${REMOTE_ARCHIVE_BASE#*:}"
  
  # REMOTE_TARGET_BASE is where the plain files are on the remote server
  if [[ -z "${REMOTE_TARGET_BASE:-}" || "$REMOTE_TARGET_BASE" != *":"* ]]; then
      echo "[ERROR] Archive: REMOTE_TARGET_BASE must be defined as a remote path (user@host:path) for direct remote archiving." >&2
      exit 1
  fi
  # The TARGET_DIR passed to this script should be the remote path of the plain files,
  # e.g., user@server:/backup/target/plain_files_root/user_to_backup@host_to_backup
  # The tar command needs to run on that remote server.
  # The -C path should be the parent of the directory we want to tar.
  # The directory to tar is the last component of TARGET_DIR's path part.

  if [[ "$TARGET_DIR" != *":"* ]]; then
      echo "[ERROR] Archive: For direct remote archiving, the input path ($TARGET_DIR) must be the remote path to the source files (e.g., user@server:/path/to/data)." >&2
      exit 1
  fi
  
  # Host where the source files (TARGET_DIR) reside and where tar will run
  source_files_host="${TARGET_DIR%%:*}"
  source_files_path_on_host="${TARGET_DIR#*:}" # e.g., /backup/target/plain_files_root/user_to_backup@host_to_backup

  # The archive is created on the host defined by REMOTE_ARCHIVE_BASE
  # If source_files_host and remote_user_host (from REMOTE_ARCHIVE_BASE) are different, this is complex.
  # Your original script assumed they are the same. Let's stick to that.
  if [[ "$source_files_host" != "$remote_user_host" ]]; then
      echo "[ERROR] Archive: Direct remote archiving currently requires source files and archive destination to be on the same remote host ($source_files_host vs $remote_user_host)." >&2
      exit 1
  fi

  # Path for -C option of tar, which is the parent of the directory to be archived
  remote_c_path_for_tar="$(dirname "$source_files_path_on_host")"
  # Directory name to archive (basename of the source path on the remote host)
  dir_to_tar_on_remote="$(basename "$source_files_path_on_host")"

  ssh_cmd="mkdir -p '$remote_archive_base_on_remote' && tar -I zstd -cf '$remote_archive_base_on_remote/$archive_name' -C '$remote_c_path_for_tar' '$dir_to_tar_on_remote'"
  
  echo "Archive Details: Remote user/host for command execution: $remote_user_host"
  echo "Archive Details: Remote archive base directory: $remote_archive_base_on_remote"
  echo "Archive Details: Full remote archive path: $remote_archive_base_on_remote/$archive_name"
  echo "Archive Details: Remote source base path for tar -C: $remote_c_path_for_tar"
  echo "Archive Details: Directory to tar within -C path: $dir_to_tar_on_remote"
  echo "Archive Command: SSH command for remote archiving: $ssh_cmd"
  echo "Archive: Executing remote archive creation via SSH."

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo "[DRY RUN] Would execute: ssh $remote_user_host \"$ssh_cmd\""
  else
    ssh "$remote_user_host" "$ssh_cmd"
  fi
else
  echo "[WARN] Skipping archive: LOCAL_ARCHIVE_BASE or REMOTE_ARCHIVE_BASE not defined in configuration for $user_host."
  echo
  echo "Please define these variables in your configuration to proceed:"
  echo
  echo "    Example: In ./config/backup.env (or your custom env file)"
  echo "    LOCAL_ARCHIVE_BASE=\"\" # Local archive directory, e.g. \"$HOME/Backups/archive\""
  echo "    REMOTE_ARCHIVE_BASE=\"\" # Remote archive directory, e.g. \"$user_host:/storage/backups/archive\"" 
  echo  
fi

