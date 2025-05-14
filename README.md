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
- [Origins / Motivation](#origins-motivation)
- [Backup Logic](#backup-logic)
- [Bloatscan Tool](#bloatscan-tool)
- [Notes](#notes)
- [License](#license)

---

## Installation

Clone the repo and run the setup script:

```bash
git clone https://github.com/brege/backup-kit
cd ~/backup-kit
./setup
```

This initializes your user config at `~/.config/backup-kit/`.

### Requirements

**Debian/Ubuntu:**

```bash
sudo apt update && sudo apt install rsync openssh-client zstd pv
```

**Fedora:**

```bash
sudo dnf install rsync openssh-clients zstd pv
```

## Config Layout

```bash
/home/user/.config/backup-kit
├── env
│   └── user@hostname_.env
├── excludes
│   ├── default.exclude
│   └── user@hostname
├── hooks-available
│   ├── 10_crontab.sh
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

The active environment file is symlinked to `config/backup.env` within the Backup-Kit directory, typically pointing to a file like:

```bash
~/.config/backup-kit/env/<user@host>_.env
```

It defines local/remote base paths for backups (`LOCAL_TARGET_BASE`, `REMOTE_TARGET_BASE`) and archive destinations (`LOCAL_ARCHIVE_BASE`, `REMOTE_ARCHIVE_BASE`). Customize these variables as needed. For example, `REMOTE_TARGET_BASE` might be `user@remoteserver:/backup/dest` and `REMOTE_ARCHIVE_BASE` could be `user@remoteserver:/backup/archives`.

To support multiple push targets or distinct configurations, you can use separate main configuration directories (e.g., `~/.config/backup-kit-main`, `~/.config/backup-kit-alternate`) and run backups against each using the `--config` flag:

```bash
./bin/run_backup.sh --config ~/.config/backup-kit-alternate
```

Alternatively, use the `bin/use_env.sh` script to change the `config/backup.env` symlink to point to different environment files within your active configuration directory.

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
./bin/machine_state.sh enable user@hostname
```

## Hooks

Hooks live in `hooks-available/`. During setup, any you want to run must be symlinked into `hooks-enabled/`.

Hook filenames should start with a numeric prefix to define execution order, like:

```bash
10_crontab.sh   # regenerate cron entries
90_archive.sh   # archive the synced output
```

You can write your own custom hooks—just place them in `hooks-available/` and symlink to `hooks-enabled/` as needed. The prefix ensures proper execution order, and all hooks receive environment variables from the active `backup.env` file. Hooks are passed the paths to the root directories where each machine's data was backed up.

## Service Integration

The setup script can install a `systemd` user service and timer. To enable it:

```bash
systemctl --user daemon-reexec # Run if you modified or added user service files
systemctl --user enable backup-kit.timer
systemctl --user start backup-kit.timer
```

To check the timer:

```bash
systemctl --user list-timers backup-kit.timer
```

Edit the timer file (e.g., `~/.config/systemd/user/backup-kit.timer` if installed via setup, or the one in the repo's `systemd/` directory before setup) to customize frequency (default: daily).


## Origins / Motivation

Backup Kit was born from several personal experiences. Early efforts to back up a laptop with limited disk space, often over slow home internet (where upload speeds can be particularly constrained), made just "backing up everything" infeasible. I did have access to other machines, however, where I could stage my backups to another machine with a larger disk.  This naturally led to the need for flexible targets (local or remote staging, remote destinations) to manage data across a growing mesh of personal devices--laptops, home servers, a Raspberry Pi music box.

At another moment, I tried to backup to my laptop to my android phone over the (old) Syncthing app, which introduced a second challenge: it choked on large file counts.  This has since been resolved in a new app, but the constraint forced me to be mindful of 100K+ small files common spread across various package management systems and repositories (e.g., `.git` metadata, `node_modules`). 

### Extracting the "You" in `~/`

The primary, overarching goal is to secure data that is time-consuming to reproduce (like intricate software configurations refined through trial-and-error, or databases for tools like Plex or Beets where indexing is significant) or truly impossible to reproduce bits (personal photos, journals, unique documents, application profiles for Firefox/Thunderbird, and essential keys like SSH/GPG). **This is your heirloom.**

### Ignoring the "Us" in `/`

Conversely, Backup Kit isn't designed to back up what the wider world already has a copy of, or what your system can easily regenerate. This includes things like common system binaries, "Linux ISOs," or easily reinstalled application packages. The former are big files; the latter are high file counts. **This is your furniture.**

  * **Declarative Configuration for Your Heirlooms:** To manage what's backed up, Backup Kit provides a declarative framework. Through simple text files (environment settings, machine definitions, exclude lists), you define *what* heirlooms to secure, *from where*, *to where*, and *what furniture to ignore*. The scripts then imperatively carry out these instructions. This framework helps you apply your backup strategy consistently across devices.

  * **`bloatscan.sh` – Whittling to the Heartwood:** Identifying what to exclude is key. `bloatscan.sh` was developed to help with this, allowing you to "whittle" down the backup set to its essential core. It's okay to be "sloppy" with excludes at first; refining them is a logarithmic pursuit of trimming unnecessary data. Think of it like alphabetizing a physical media collection: a focused effort initially makes long-term maintenance much simpler. This tool helps capture that hard-won knowledge of what's truly important on *your* systems.

  * **Embrace, Don't Reinvent, Core Tools:** Backup Kit leverages robust, well-understood Unix utilities like `rsync` for efficient data transfer and `tar`/`zstd` for archiving. It also sees tools like Syncthing as complementary; for instance, Syncthing can be great for getting data from a phone or laptop to an always-on home server/NAS, which can then be a source for Backup Kit's more structured, asynchronous backups.  And its "Untrusted" feature, coupled with distributed syncing, is fantastic at securing data on a more compromisable machine.

  * **Inspired Management:** The `machines-available`/`machines-enabled` structure offers a nod to the clear and effective configuration style of Nginx, providing a logical way to manage different backup sets or hooks.  This, plus the use of different `--config` paths for different sets, with potentially different hooks, provides a lot of extensibility.

In essence, Backup Kit is a pragmatic, script-based toolkit that's transparent, customizable, and a resource-aware method for extracting digital assets.


## Backup Logic

`bin/run_backup.sh` handles the core logic:

  - Sources the active `backup.env` file (symlinked at `config/backup.env`, typically pointing to a file within `~/.config/backup-kit/env/`) to load its configuration variables.
  - Reads enabled machine configurations from the `machines-enabled/` directory.
  - For each machine:
      - Rsyncs each listed `src` path while respecting global (`excludes/default.exclude`) and machine-specific exclude files (e.g., `excludes/user@hostname`).
      - **Staging Behavior**:
          - If only `LOCAL_TARGET_BASE` is defined, data is synced to this local path.
          - If only `REMOTE_TARGET_BASE` is defined, data is synced directly to this remote path (requires SSH access configured for the target).
          - If both `LOCAL_TARGET_BASE` (for local staging) and `REMOTE_TARGET_BASE` are defined, data for the current machine is first synced to the local stage. Immediately after the local staging for that machine is complete, its staged data is then pushed (rsynced) to the `REMOTE_TARGET_BASE`. This sequence (local stage then remote push) completes for one machine before the script proceeds to the next.
  - After all machines are processed, it executes any enabled hook scripts found in the `hooks-enabled/` directory. Each hook is passed the paths to the root directories where each machine's data was backed up (e.g., `/path/to/target/user@hostA`, `/path/to/target/user@hostB`).

Rsync operations are incremental by default, preserving attributes and efficiently transferring only changed files. Note that the standard `90_archive.sh` hook, by default, will overwrite an existing archive for a given machine if run multiple times, unless the hook script itself is modified to implement a versioning scheme (e.g., by including timestamps in archive filenames).

## Bloatscan Tool

`bloatscan.sh` helps identify large subdirectories that might be wasteful to back up:

```bash
./bin/bloatscan.sh /home/user --depth=3 --limit=10
```

This command scans `/home/user` down to a depth of 3 levels and shows the top 10 largest directories.

Run remotely:

```bash
cat bin/bloatscan.sh | ssh user@host 'bash -s -- /remote/path/to/scan --depth=2 --limit=5'
```

The remote execution also supports flags like `--depth` and `--limit` after the path.

Use it iteratively: look for folders with massive file counts or disk usage. Consider whether those are really worth preserving—often they come from package managers like `npm`, `pip`, or `node_modules`, and can be reinstalled later. The tool can also use an exclude file similar to the backup excludes (by default `~/.config/backup-kit/excludes/user@host` or specify with `--excludes-file=path/to/file`).

## Notes

  - Rsync is incremental; archives created by the default `90_archive.sh` hook are not versioned by default.
  - This backup solution primarily preserves configuration and data files. It does not reinstall software packages.
  - To test changes to your backup configuration (e.g., new exclude rules), use the `./setup --test` mode to run a simulated backup against test data, which isolates the test from your real data and production backup destination.

## License

This project is licensed under the MIT License.

