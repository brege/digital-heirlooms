#!/bin/bash

# Collect all userhost:path pairs
userhost_paths=()
for config_file in ~/.config/digital-heirlooms/machines-enabled/*; do
    while IFS= read -r line; do
        # If line starts with '[', record userhost
        if [[ "$line" =~ ^\[.*\]$ ]]; then
            userhost="${line//[\[\]]/}"
        fi
        # If line starts with 'src=', append combined info
        if [[ "$line" =~ ^src= ]]; then
            path="${line#src=}"
            userhost_paths+=("$userhost:$path")
        fi
    done < "$config_file"
done

# Now check remote existence for each userhost:path
for entry in "${userhost_paths[@]}"; do
    userhost="${entry%%:*}"
    path="${entry#*:}"
    if ssh -q "$userhost" test -e "$path" 2>/dev/null; then
        echo "✓ $userhost:$path"
    else
        echo "✗ $userhost:$path"
    fi
done

