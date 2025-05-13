#!/usr/bin/env bash

echo "Crontab Export: Starting hook..."

declare -A seen_targets

for target_dir in "$@"; do
  [[ -n "${seen_targets["$target_dir"]}" ]] && continue
  seen_targets["$target_dir"]=1

  [[ ! -d "$target_dir" ]] && continue

  target_name=$(basename "$target_dir")
  crontab_output=$(ssh "$target_name" 'crontab -l' 2>/dev/null)

  if [[ -n "$crontab_output" ]]; then
    echo "$crontab_output" > "$target_dir/crontab.txt"
    echo "Crontab Export: $target_name: Crontab saved to crontab.txt."
  else
    echo "Crontab Export: $target_name: No crontab found."
  fi
done

echo "Crontab Export: Hook finished."
