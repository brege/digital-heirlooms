#!/bin/bash

set -euo pipefail

# --- Function Definition ---
# Function to create a local archive with optional progress bar via pv
_create_local_archive_with_progress() {
  local archive_path="$1"
  local source_dir_for_tar="$2" # This is the TARGET_DIR passed to the script
  # DRY_RUN is an environment variable, tar_cmd array is already set based on it

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
          echo "[WARN] Archive: Could not determine size of '$source_dir_for_tar' or size is 0. Archiving without pv progress." >&2
          tar -I zstd -cf "$archive_path" -C "$(dirname "$source_dir_for_tar")" "$(basename "$source_dir_for_tar")"
      else
          (cd "$(dirname "$source_dir_for_tar")" && tar -cf - "$(basename "$source_dir_for_tar")" | pv -N "Archiving $(basename "$source_dir_for_tar")" -s "$total_size" -ptebar | zstd -T0 > "$archive_path")
      fi
    else
      echo "Archive: pv not found. Archiving locally without progress bar."
      tar -I zstd -cf "$archive_path" -C "$(dirname "$source_dir_for_tar")" "$(basename "$source_dir_for_tar")"
    fi
    echo "Archive: Local archive created: $archive_path"
  fi
}
# --- End Function Definition ---

# DRY RUN flag logic
tar_cmd=(tar -I zstd -cf) # Default actual command
rsync_cmd=(rsync -avz)    # Default actual command
if [[ "${DRY_RUN:-false}" == "true" ]]; then # DRY_RUN is an environment variable
  tar_cmd=(echo "[DRY RUN] Would execute: tar -I zstd -cf")
  rsync_cmd+=(--dry-run)
fi

# Ensure local archive dir exists if set
if [[ -n "${LOCAL_ARCHIVE_BASE:-}" ]]; then
  echo "Archive: Ensuring local base directory exists: $LOCAL_ARCHIVE_BASE"
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
    if [[ -n "$remote_user_host_for_mkdir" && -n "$remote_path_for_mkdir" ]]; then
        echo "Archive: Ensuring remote base directory exists: $remote_user_host_for_mkdir:'$remote_path_for_mkdir'"
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo "[DRY RUN] Would execute: ssh $remote_user_host_for_mkdir mkdir -p '$remote_path_for_mkdir'"
        else
            ssh "$remote_user_host_for_mkdir" "mkdir -p '$remote_path_for_mkdir'"
        fi
    fi
  else
      echo "Archive: Ensuring (local) remote archive base directory exists: $REMOTE_ARCHIVE_BASE"
      if [[ "${DRY_RUN:-false}" == "true" ]]; then
          echo "[DRY RUN] Would execute: mkdir -p \"$REMOTE_ARCHIVE_BASE\""
      else
          mkdir -p "$REMOTE_ARCHIVE_BASE"
      fi
  fi
fi

if [[ $# -eq 0 ]]; then
    echo "Archive: No target directories provided to process. Exiting hook."
    exit 0
fi

for TARGET_DIR in "$@"; do
  echo # Blank line for readability
  echo "Archive: Processing target: $TARGET_DIR"

  user_host="$(basename "$TARGET_DIR")" 
  archive_name="$user_host.tar.zst"
  local_archive_path="${LOCAL_ARCHIVE_BASE%/}/$archive_name" 
  remote_archive_path="${REMOTE_ARCHIVE_BASE%/}/$archive_name" 

  # Archive logic
  if [[ -n "${LOCAL_ARCHIVE_BASE:-}" && -n "${REMOTE_ARCHIVE_BASE:-}" ]]; then
    if [[ "$TARGET_DIR" == *":"* ]]; then
        echo "[ERROR] Archive: LOCAL_ARCHIVE_BASE is set, but TARGET_DIR ('$TARGET_DIR') appears to be remote. Cannot create local archive from remote source directly with current '_create_local_archive_with_progress'." >&2
        continue
    fi
    _create_local_archive_with_progress "$local_archive_path" "$TARGET_DIR"

    echo "Archive: Syncing local archive $local_archive_path to remote target $remote_archive_path"
    final_rsync_for_archive_push=()
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        final_rsync_for_archive_push=("${rsync_cmd[@]}")
    else
        final_rsync_for_archive_push=(rsync -avz --info=progress2)
    fi
    final_rsync_for_archive_push+=("$local_archive_path" "$remote_archive_path")
    "${final_rsync_for_archive_push[@]}"

  elif [[ -n "$LOCAL_ARCHIVE_BASE" ]]; then
    if [[ "$TARGET_DIR" == *":"* ]]; then
        echo "[ERROR] Archive: LOCAL_ARCHIVE_BASE is set, but TARGET_DIR ('$TARGET_DIR') appears to be remote. Cannot create local archive from remote source directly with current '_create_local_archive_with_progress'." >&2
        continue
    fi
    _create_local_archive_with_progress "$local_archive_path" "$TARGET_DIR"

  elif [[ -n "$REMOTE_ARCHIVE_BASE" && -z "${LOCAL_ARCHIVE_BASE:-}" ]]; then 
    echo "Archive: Creating remote archive for $user_host using remote sources, to $REMOTE_ARCHIVE_BASE"
    
    if [[ "$REMOTE_ARCHIVE_BASE" != *":"* ]]; then
        echo "[ERROR] Archive: REMOTE_ARCHIVE_BASE ('$REMOTE_ARCHIVE_BASE') must be a remote path (user@host:path) for direct remote archiving." >&2
        continue 
    fi
    if [[ -z "${REMOTE_TARGET_BASE:-}" || "$REMOTE_TARGET_BASE" != *":"* ]]; then
        echo "[ERROR] Archive: REMOTE_TARGET_BASE (from backup.env) must be defined as a remote path (user@host:path) to locate source files for direct remote archiving." >&2
        continue 
    fi
    
    actual_remote_source_prefix="${REMOTE_TARGET_BASE%/}/$user_host"
    
    source_files_host="${actual_remote_source_prefix%%:*}"
    source_files_path_on_host="${actual_remote_source_prefix#*:}" 

    remote_archive_cmd_host="${REMOTE_ARCHIVE_BASE%%:*}"
    remote_archive_target_dir="${REMOTE_ARCHIVE_BASE#*:}"

    if [[ "$source_files_host" != "$remote_archive_cmd_host" ]]; then
        echo "[ERROR] Archive: Direct remote archiving requires source files (on '$source_files_host' from REMOTE_TARGET_BASE) and archive destination (on '$remote_archive_cmd_host' from REMOTE_ARCHIVE_BASE) to be on the same remote host." >&2
        continue
    fi

    remote_c_path_for_tar="$(dirname "$source_files_path_on_host")"
    dir_to_tar_on_remote="$(basename "$source_files_path_on_host")"
    full_remote_tarball_path="${remote_archive_target_dir%/}/$archive_name"
    
    echo "Archive Details (Direct Remote):"
    echo "  Remote source for tar: $source_files_host:$source_files_path_on_host"
    echo "  Remote host for command: $remote_archive_cmd_host"
    echo "  Target directory on remote for archive: $remote_archive_target_dir"
    echo "  Full remote archive path: $full_remote_tarball_path"
    echo "  Remote tar -C path: $remote_c_path_for_tar"
    echo "  Directory to tar on remote: $dir_to_tar_on_remote"
    echo "Archive: Executing remote archive creation via SSH."

    final_ssh_tar_cmd=""
    if ssh "$remote_archive_cmd_host" "command -v pv &> /dev/null"; then
        echo "Archive: pv found on remote host '$remote_archive_cmd_host'."
        remote_total_size_cmd="du -sb '$source_files_path_on_host' | awk '{print \$1}'"
        remote_total_size=$(ssh "$remote_archive_cmd_host" "$remote_total_size_cmd")

        if [[ -n "$remote_total_size" && "$remote_total_size" =~ ^[0-9]+$ && "$remote_total_size" -gt 0 ]]; then
            echo "Archive: Remote source size is $remote_total_size bytes. Using pv for progress."
            final_ssh_tar_cmd="(cd '$remote_c_path_for_tar' && tar -cf - '$dir_to_tar_on_remote' | pv -N \"Archiving $dir_to_tar_on_remote@$remote_archive_cmd_host\" -s $remote_total_size -ptebar | zstd -T0 > '$full_remote_tarball_path')"
        else
            echo "[WARN] Archive: Could not determine remote size of '$source_files_path_on_host' ($remote_total_size) or size is 0. Archiving remotely without pv progress." >&2
            final_ssh_tar_cmd="tar -I zstd -cf '$full_remote_tarball_path' -C '$remote_c_path_for_tar' '$dir_to_tar_on_remote'"
        fi
    else
        echo "Archive: pv not found on remote host '$remote_archive_cmd_host'. Archiving remotely without progress bar."
        final_ssh_tar_cmd="tar -I zstd -cf '$full_remote_tarball_path' -C '$remote_c_path_for_tar' '$dir_to_tar_on_remote'"
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
      # For DRY_RUN, also indicate that -t would be used for actual execution.
      echo "[DRY RUN] Would execute: ssh -t $remote_archive_cmd_host \"$final_ssh_tar_cmd\""
    else
      # Use ssh -t to allocate a TTY for pv
      ssh -t "$remote_archive_cmd_host" "$final_ssh_tar_cmd"
    fi

  else
    echo "[WARN] Skipping archive for $user_host: Archive base variables not configured suitably." >&2
  fi
  echo "Archive: Finished processing $user_host from $TARGET_DIR."
done
echo # Final blank line
echo "Archive: All targets processed by hook."
