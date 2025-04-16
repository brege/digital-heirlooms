# Backup Kit for System Backups and Archiving

This toolkit simplifies backing up directories from local or remote machines, using modular config files, excludes, and hooks. It supports incremental syncs, customizable archiving, and optional automation via `systemd`.

## Table of Contents

- [Installation](#installation)
- [Config Layout](#config-layout)
- [Setup and Test Mode](#setup-and-test-mode)
- [Environment File](#environment-file)
- [Machine and Exclude Files](#machine-and-exclude-files)
- [Hooks](#hooks)
- [Service Integration](#service-integration)
- [Backup Logic](#backup-logic)
- [Bloatscan Tool](#bloatscan-tool)
- [Notes](#notes)
- [License](#license)

---

## Installation

Clone the repo and run the setup script:

```bash
git clone https://github.com/brege/backup-kit ~/backup-kit
cd ~/backup-kit
./setup
```

This initializes your user config at `~/.config/backup-kit/`.

## Config Layout

```bash
/home/user/.config/backup-kit
├── env
│   └── user@hostname_.env
├── excludes
│   ├── default.exclude
│   └── user@hostname
├── hooks-available
│   ├── 01_crontab.sh
│   └── 90_archive.sh
├── hooks-enabled
├── machines-available
│   └── user@hostname
└── machines-enabled
    └── user@hostname -> /home/user/.config/backup-kit/machines-available/user@hostname
```

## Setup and Test Mode

Running `./setup` populates the config directory with templates and symlinks `config/backup.env` to the machine-specific env file (e.g. `user@hostname_.env`) in `~/.config/backup-kit/env/`. It also copies the repo's `hooks/` directory to your config's `hooks-available/`.

For test mode, use:

```bash
./setup --test
```

This links a test configuration and runs a local backup from `test/source/` to `test/target/` with an archive hook enabled. It verifies include/exclude rules and archive creation without touching real data. Only the hooks symlinked during test mode will be unlinked afterward, preserving any user-added hooks.

## Environment File

The active environment file is:

```bash
~/.config/backup-kit/env/<user@host>_.env
```

It defines local/remote base paths and archive destinations. Customize variables like `REMOTE_PUSH_TARGET` and `REMOTE_ARCHIVE_BASE`.

To support multiple push targets, use separate config dirs (e.g., `~/.config/backup-kit-to-nas`, etc.). Run backups against each:

```bash
./run_backup.sh --config ~/.config/backup-kit-to-nas
```

## Machine and Exclude Files

Each source machine has its own config file in `machines-available/`, e.g.:

```ini
# ~/.config/backup-kit/machines-available/user@hostname
[user@hostname]
exclude-from=config/excludes/user@hostname
src=/var/lib/plexmediaserver
src=/home/user
```

This example backs up Plex Media Server data, which is notoriously difficult to restore cleanly due to its mix of heirloom content and volatile runtime data. Careful excludes are essential.

A matching exclude file might look like:

```bash
# config/excludes/user@hostname
/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/{Cache,Codecs}
/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml # protected
/home/user/.cache/
/home/user/.local/share/Trash/
```

Enable a machine by symlinking its config to `machines-enabled/`. Use `machine_state.sh` to manage symlinks:

```bash
./machine_state.sh enable user@hostname
```

## Hooks

Hooks live in `hooks-available/`. During setup, any you want to run must be linked into `hooks-enabled/`.

Hook filenames should start with a numeric prefix to define execution order, like:

```bash
10_crontab.sh   # regenerate cron entries
90_archive.sh   # archive the synced output
```

You can write your own custom hooks—just place them in `hooks-available/` and symlink to `hooks-enabled/` as needed. The prefix ensures proper execution order, and all hooks receive environment variables from `backup.env`.

## Service Integration

The setup script can install a `systemd` user service and timer. To enable it:

```bash
systemctl --user daemon-reexec
systemctl --user enable backup.timer
systemctl --user start backup.timer
```

To check the timer:

```bash
systemctl --user status backup.timer
```

Edit the timer file in your config to customize frequency (default: daily).

## Backup Logic

`bin/run_backup.sh` handles the core logic:

- Sources `backup.env` (which is linked to `~/.config/backup-kit/env/user@hostname_.env`) to load config
- Reads machines from `machines-enabled/`
- Rsyncs each listed `src` while respecting excludes
- Executes any hooks post-rsync

Rsync is incremental. Hooks like `90_archive.sh` will overwrite the archive by default unless modified to version them.

## Bloatscan Tool

`bloatscan.sh` helps identify large subdirectories that might be wasteful to back up:

```bash
./bloatscan.sh /home/user --depth=3 --limit=10
```

Run remotely:

```bash
cat bin/bloatscan.sh | ssh user@host 'bash -s' -- /home/user --depth=2 --limit=5
```

Use it iteratively: look for folders with massive file counts or disk usage. Consider whether those are really worth preserving—often they come from package managers like `npm`, `pip`, or `node_modules`, and can be reinstalled later.

## Notes

- Rsync is incremental; archives are not yet versioned
- Backup doesn't reinstall software, just preserves config and data
- To test changes, use `--test` to isolate from real data

## License

This project is licensed under the MIT License.


