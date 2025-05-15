#!/bin/bash
set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Script Path & Default Config Path ---
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Default if no --config and no CONFIG_DIR in repo's backup.env
CONFIG_ROOT_DEFAULT="$REPO_ROOT/config"

# --- print_usage function ---
print_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Runs the backup process for $PROJECT_NAME."
  echo ""
  echo "Options:"
  echo "  --config <path>        Specify the root directory for $PROJECT_NAME configurations."
  echo "                         Overrides default behavior and any CONFIG_DIR from backup.env."
  echo "  --help, -h             Show this help message."
}

# --- Argument parsing for --config ---
CONFIG_ROOT_OVERRIDE=""
# Create a temporary array from $@ to safely shift and inspect
args_to_process=("$@")
idx=0
while [[ $idx -lt ${#args_to_process[@]} ]]; do
  arg_to_check="${args_to_process[$idx]}"
  case "$arg_to_check" in
    --help|-h)
      print_usage
      exit 0
      ;;
    --config)
      if [[ -n "${args_to_process[$((idx + 1))]:-}" && "${args_to_process[$((idx + 1))]}" != --* ]]; then
        CONFIG_ROOT_OVERRIDE="${args_to_process[$((idx + 1))]}"
        idx=$((idx + 1)) # Advance past value
      else
        echo "WARN: --config flag found, but no value followed or value is another flag. Ignoring." >&2
      fi
      ;;
    --config=*)
      CONFIG_ROOT_OVERRIDE="${arg_to_check#*=}"
      ;;
    -*)
      echo "ERROR: Unknown option: $arg_to_check" >&2
      print_usage
      exit 1
      ;;
    *)
      # Other arguments can be processed here if run_backup.sh takes more options
      # For now, we only care about --config. Non-matching args are passed over.
      :
      ;;
  esac
  ((idx++))
done

# --- Resolve script base and config dir ---
CONFIG_ROOT="$CONFIG_ROOT_DEFAULT"      # Initial assumption

cfg_override_set=false
if [[ -n "$CONFIG_ROOT_OVERRIDE" ]]; then
  # --config was provided, use its value directly
  if ! config_root_realpath_temp="$(realpath "$CONFIG_ROOT_OVERRIDE" 2>/dev/null)"; then
    echo "ERROR: Invalid path specified with --config: $CONFIG_ROOT_OVERRIDE" >&2
    exit 1
  fi
  CONFIG_ROOT="$config_root_realpath_temp"
  cfg_override_set=true
else
  # No --config, use default logic:
  # Check if the REPO's default backup.env specifies a user CONFIG_DIR
  DEFAULT_REPO_ENV_FILE="$CONFIG_ROOT_DEFAULT/backup.env"
  if [[ -f "$DEFAULT_REPO_ENV_FILE" ]]; then
    # Source into a subshell to safely extract CONFIG_DIR
    sourced_cfg_dir=$( (CONFIG_DIR="" source "$DEFAULT_REPO_ENV_FILE" >/dev/null 2>&1 && echo "$CONFIG_DIR") )
    if [[ -n "$sourced_cfg_dir" ]]; then
      if ! sourced_cfg_dir_realpath="$(realpath "$sourced_cfg_dir" 2>/dev/null)"; then
        echo "ERROR: Invalid CONFIG_DIR specified in $DEFAULT_REPO_ENV_FILE: $sourced_cfg_dir" >&2
        exit 1
      fi
      CONFIG_ROOT="$sourced_cfg_dir_realpath"
    fi
  fi
fi

# Now, CONFIG_ROOT is definitively set.
# Source the backup.env from this final CONFIG_ROOT.
ENV_FILE_TO_SOURCE="$CONFIG_ROOT/backup.env"
if [[ -f "$ENV_FILE_TO_SOURCE" ]]; then
  set -a  # Auto-export all variables from this env file
  prev_cfg_dir_val="${CONFIG_DIR:-}"
  source "$ENV_FILE_TO_SOURCE"
  set +a
  if [[ "$cfg_override_set" == true ]]; then
      CONFIG_DIR="${prev_cfg_dir_val}"
  elif [[ -n "${CONFIG_DIR:-}" ]]; then
      # If --config was NOT used, and the sourced env file SETS CONFIG_DIR,
      # and that CONFIG_DIR points to a different place than the current CONFIG_ROOT,
      # then update CONFIG_ROOT to this new CONFIG_DIR from the user's primary env file.
      if ! new_config_root_realpath="$(realpath "${CONFIG_DIR}" 2>/dev/null)"; then
          echo "ERROR: Invalid CONFIG_DIR specified in $ENV_FILE_TO_SOURCE: ${CONFIG_DIR}" >&2
          exit 1
      fi
      if [[ "$CONFIG_ROOT" != "$new_config_root_realpath" ]]; then
         CONFIG_ROOT="$new_config_root_realpath"
      fi
  fi
else
  echo "WARN: Environment file not found: $ENV_FILE_TO_SOURCE. Critical variables (DRY_RUN, target paths) may be unset." >&2
  DRY_RUN="${DRY_RUN:-true}"
  LOCAL_TARGET_BASE="${LOCAL_TARGET_BASE:-}"
  REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}"
  LOCAL_ARCHIVE_BASE="${LOCAL_ARCHIVE_BASE:-}"
  REMOTE_ARCHIVE_BASE="${REMOTE_ARCHIVE_BASE:-}"
fi

# Derived paths from the final CONFIG_ROOT
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
EXCLUDES_DIR="$CONFIG_ROOT/excludes"
HOOKS_DIR="$CONFIG_ROOT/hooks-enabled"

echo "Using machine configs from: $MACHINES_ENABLED_DIR"
echo "Using excludes from: $EXCLUDES_DIR"
echo "Using hooks from: $HOOKS_DIR"

# Setup rsync's default exclude file
dflt_exclude_path="$EXCLUDES_DIR/default.exclude"
if [[ -f "$dflt_exclude_path" ]]; then
  echo "Applying global excludes from: $dflt_exclude_path"
  default_exclude="$dflt_exclude_path"
else
  default_exclude=""
  echo "No global exclude file found at $dflt_exclude_path (this is okay)."
fi

REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}"
DRY_RUN="${DRY_RUN:-false}"

# Not currently used, but present in original
direct_remote_rsync=false
staged_dirs=()

current_user=""
current_host=""
current_exclude=""
backup_paths=()
declare -A target_machine_roots

is_local_host() {
  # Check if the given host is the local machine
  [[ "$1" == "localhost" || "$1" == "$(hostname)" || "$1" == "$(hostname -f)" ]]
}

# --- Backup Processing Function ---
flush_backup() {
  [[ ${#backup_paths[@]} -eq 0 ]] && return

  local staged_locally_this_flush=false

  for src_path in "${backup_paths[@]}"; do
    # Initialize with base options
    local rsync_cmd=(rsync -avzR --delete)

    # Add global exclude file
    if [[ -n "$default_exclude" && -f "$default_exclude" ]]; then
        rsync_cmd+=(--exclude-from="$default_exclude")
    fi
    # Add machine-specific exclude file
    if [[ -n "$current_exclude" && -f "$current_exclude" ]]; then
        rsync_cmd+=(--exclude-from="$current_exclude")
    fi

    # Scenario 1: Local staging then remote push
    if [[ -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      dest_dir="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir"

      src_path_expanded=""
      # Assume SSH by default for this scenario if host isn't local
      use_ssh=true
      if is_local_host "$current_host"; then
        use_ssh=false
        src_path_expanded="$src_path"
      else
        src_path_expanded="$current_user@$current_host:$src_path"
      fi

      mkdir -p "$dest_dir"

      # Prevent recursion: Exclude the local target base
      if [[ "$LOCAL_TARGET_BASE" == /* ]]; then
          rsync_cmd+=(--exclude "$LOCAL_TARGET_BASE")
      fi

      if [[ "$DRY_RUN" == "true" ]]; then
         rsync_cmd+=(--dry-run)
      fi
      if [[ "$use_ssh" == true ]]; then
         rsync_cmd+=(-e ssh)
      fi
      rsync_cmd+=("$src_path_expanded" "$dest_dir")

      echo ""
      echo "Rsyncing to local staging ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $dest_dir"
      "${rsync_cmd[@]}"
      staged_locally_this_flush=true

    # Scenario 2: Direct remote push
    elif [[ -z "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      dest_dir="$REMOTE_TARGET_BASE/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir"

      src_path_expanded="$current_user@$current_host:$src_path"
      if [[ "$DRY_RUN" == "true" ]]; then
        rsync_cmd+=(--dry-run)
      fi
      rsync_cmd+=(-e ssh "$src_path_expanded" "${dest_dir%/}/")

      echo ""
      echo "Rsyncing directly to remote ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> ${dest_dir%/}/"
      "${rsync_cmd[@]}"

    # Scenario 3: Local staging only (REMOTE_TARGET_BASE is empty)
    else
      if [[ -z "$LOCAL_TARGET_BASE" ]]; then
        echo "ERROR: flush_backup: LOCAL_TARGET_BASE is not set for local backup of $current_user@$current_host. Skipping path $src_path." >&2
        continue
      fi
      dest_dir="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir"

      src_path_expanded=""
      # Assume SSH if host isn't local
      use_ssh=true
      if is_local_host "$current_host"; then
        use_ssh=false
        src_path_expanded="$src_path"
      else
        src_path_expanded="$current_user@$current_host:$src_path"
      fi

      mkdir -p "$dest_dir"
      if [[ "$LOCAL_TARGET_BASE" == /* ]]; then
          rsync_cmd+=(--exclude "$LOCAL_TARGET_BASE")
      fi

      if [[ "$DRY_RUN" == "true" ]]; then
        rsync_cmd+=(--dry-run)
      fi
      if [[ "$use_ssh" == true ]]; then
        rsync_cmd+=(-e ssh)
      fi
      rsync_cmd+=("$src_path_expanded" "$dest_dir")

      echo ""
      echo "Rsyncing to local destination ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $dest_dir"
      "${rsync_cmd[@]}"
      staged_locally_this_flush=true
    fi
  done

  if [[ "$staged_locally_this_flush" == true && -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
    local local_stage_path="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
    local remote_dest_path="$REMOTE_TARGET_BASE/$current_user@$current_host"

    echo ""
    echo "Syncing staged data for $current_user@$current_host to remote..."
    echo "Path: $local_stage_path/ -> $remote_dest_path/"

    local rsync_push_cmd=(rsync -az --delete --info=progress2)
    if [[ "$DRY_RUN" == "true" ]]; then
      rsync_push_cmd+=(--dry-run)
    fi
    rsync_push_cmd+=("$local_stage_path/" "$remote_dest_path/")
    "${rsync_push_cmd[@]}"
  fi

  backup_paths=()
  current_exclude=""
}

# --- Main Processing Loop for Machines ---
machine_processed_count=0
config_file_found_in_enabled_dir=false
for config_file in "$MACHINES_ENABLED_DIR"/*; do
  if [[ ! -f "$config_file" ]]; then
    # This handles the case where MACHINES_ENABLED_DIR is empty
    if [[ "$config_file" == "$MACHINES_ENABLED_DIR/*" ]]; then
        :
    else
        echo "WARN: Skipping non-file in MACHINES_ENABLED_DIR: $config_file" >&2
    fi
    continue
  fi
  config_file_found_in_enabled_dir=true

  current_user=""
  current_host=""
  backup_paths=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[(.+)@(.+)\]$ ]]; then
      if [[ -n "$current_user" && -n "$current_host" ]]; then
        flush_backup || echo "WARN: A problem occurred in flush_backup for $current_user@$current_host (file: $config_file), continuing." >&2
        backup_paths=()
      fi
      current_user="${BASH_REMATCH[1]}"
      current_host="${BASH_REMATCH[2]}"
      current_exclude="$EXCLUDES_DIR/$current_user@$current_host"
      echo ""
      echo "Processing machine: $current_user@$current_host from $config_file"
      machine_processed_count=$((machine_processed_count + 1))
      continue
    fi

    if [[ "$line" == src=* && -n "$current_user" && -n "$current_host" ]]; then
      raw_path="${line#src=}"
      # eval is a potential security risk if $raw_path is not trusted
      expanded_path=$(eval echo "$raw_path")
      backup_paths+=("$expanded_path")
    fi
  done < "$config_file"

  if [[ -n "$current_user" && -n "$current_host" ]]; then
    flush_backup || echo "WARN: A problem occurred in flush_backup for $current_user@$current_host (end of file: $config_file), continuing." >&2
  fi
done

# --- Post-backup Summary and Hook Execution ---
if [[ "$config_file_found_in_enabled_dir" == false ]]; then
    echo "No machine configuration files found in $MACHINES_ENABLED_DIR."
elif [[ "$machine_processed_count" -eq 0 ]]; then
    echo "Machine configuration files were found, but no valid [user@host] sections were processed."
fi

if [[ ${#target_machine_roots[@]} -eq 0 ]]; then
    if [[ "$machine_processed_count" -gt 0 ]]; then
        echo "Machines were processed, but no valid backup target directories were recorded. Skipping hooks."
    else
        echo "No machines processed. Skipping hooks."
    fi
elif [[ -d "$HOOKS_DIR" ]]; then
  declare -a hook_target_dirs_final=()
  for path_val in "${target_machine_roots[@]}"; do
    if [[ -d "$path_val" ]]; then
      hook_target_dirs_final+=("$path_val")
    fi
  done
  IFS=$'\n' read -d '' -ra unique_final_paths < <(printf "%s\n" "${hook_target_dirs_final[@]}" | sort -u && printf '\0')

  if [[ ${#unique_final_paths[@]} -gt 0 ]]; then
    for hook in "$HOOKS_DIR"/*; do
      if [[ -f "$hook" && -x "$hook" ]]; then
        echo ""
        echo "Hooks: Running post-backup hook: $hook on targets: ${unique_final_paths[*]}"
        "$hook" "${unique_final_paths[@]}"
      elif [[ -f "$hook" ]]; then
        echo ""
        echo "Hooks: Skipping non-executable file hook: $hook"
      else
        echo ""
        echo "Hooks: Skipping non-file or non-executable item in hooks directory: $hook"
      fi
    done
  else
    echo ""
    echo "Hooks: No valid target directories available for hooks after processing."
  fi
else
  if [[ ! -d "$HOOKS_DIR" ]]; then
    echo ""
    echo "Hooks: No hooks directory found at $HOOKS_DIR, or directory is empty."
  fi
fi
echo ""
echo "All operations complete."
