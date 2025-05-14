# Backup Kit: Archiving and Whittling Digital Heirlooms

This toolkit simplifies backing up directories from local or remote machines, using modular config files, excludes, and hooks. It supports incremental syncs, customizable archiving, and optional automation via `systemd`.

## Preface

**The primary audience for Backup-Kit is people who:**

* are proficient with the `*nix` command line and prefer transparent, script-based tools.
* want modular, plain-text configuration to selectively back up their hard-time (heirloom) data and extend functionality with custom shell hooks.
* need to manage backups for multiple machines and desire direct control over their backup strategy (sources, destinations, exclusions).

**This project should *not* be one's primary choice if they:**

* prefer a simple graphical user interface (GUI) or "one-click" backup solutions.
* are uncomfortable with shell scripting, manual configuration editing, or a command-line-only workflow.
* require advanced built-in features like global deduplication, integrated key management, or a guided data restoration process out-of-the-box.

Many will find this tool a bit too specialized, but others might find this system suitable for their needs.    

## Table of Contents

- [Installation](#installation)
- [Config Layout](#config-layout-multiple-machines)
- [Setup and Test Mode](#setup-and-test-mode)
- [Environment File](#environment-file)
- [Machine and Exclude Files](#machine-and-exclude-files)
- [Hooks](#hooks)
- [Service Integration](#service-integration)
- [Origins / Motivation](#origins-motivation)
- [Backup Logic](#backup-logic)
- [Bloatscan Tool](#bloatscan-tool)
- [Notes](#notes)
- [Future Features](#future-features)
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

## Config Layout - Multiple Machines

The `setup` script initializes a configuration directory, typically at `~/.config/backup-kit/`. Over time, as you configure backups for multiple machines and enable hooks, it might resemble the following structure. This example shows a setup managing backups for a laptop, a desktop, a file server, and a Raspberry Pi, with a Pi-hole configuration also available.

Assume the user's home directory is `/home/user/` for the absolute paths shown in the symlinks.

```bash
/home/user/.config/backup-kit/
├── backup.env -> /home/user/.config/backup-kit/env/alice@laptop_main.env  
│                                   # (Symlink to the active environment)
├── env/
│   ├── alice@laptop_main.env       # <-- You only link directly to one environment,
│   ├── bob@desktop_local.env       #  but you can copy this directory of all your 
│   ├── fileserver_offsite.env      #  machine-specific environments to other hosts
│   └── raspberrypi.env
├── excludes/
│   ├── default.exclude             # Global default excludes
│   ├── alice@laptop.exclude        # Excludes syntax derived via: 
│   │                               #   rsync --exclude-from="alice@laptop.exclude" 
│   ├── bob@desktop.exclude 
│   ├── fileserver.exclude          # Use ./bloatscan.sh to discover paths to add
│   ├── raspberrypi.exclude         # to these exclude files
│   └── pihole.exclude
├── hooks-available/                # You can create more post-hooks here, ordered
│   ├── 10_crontab.sh               # numerically by execution order
│   └── 90_archive.sh
├── hooks-enabled/
│   │                               # Toggle hooks here to [enable]/disable them 
│   └── 90_archive.sh -> /home/user/.config/backup-kit/hooks-available/90_archive.sh 
│ 
├── machines-available/             # Customize which directories of each machine you
│   ├── alice@laptop                # want to back up
│   ├── bob@desktop                 #    rsync: src=/home/bob/ 
│   ├── fileserver                  #           src=/var/lib/plexmediaserver
│   ├── raspberrypi                 #           ...
│   └── pihole
└── machines-enabled/               # Toggle machines here to enable/disable their backups
    │                               # via the machine you are currently executing from 
    ├── alice@laptop  -> /home/user/.config/backup-kit/machines-available/alice@laptop
    ├── fileserver    -> /home/user/.config/backup-kit/machines-available/fileserver
    └── raspberrypi   -> /home/user/.config/backup-kit/machines-available/raspberrypi
```

The directory layout is as follows (this is a working example of ["Machine and Exclude Files"](#machine-and-exclude-files))

* **`backup.env` (in repo `config/`)**: 
  * A symlink (created by `./setup`) to the active default environment file within your user configuration (e.g., 
    `~/.config/backup-kit/env/alice@laptop_main.env`). This is the environment `./bin/run_backup.sh` uses if called without the `--config` flag.

* **`env/`**: 
  * Holds various environment configurations (e.g., `alice@laptop_main.env`, `bob@desktop_local.env`). Each defines variables like `LOCAL_TARGET_BASE`, `REMOTE_TARGET_BASE`, and `DRY_RUN` for different backup scenarios or machines. While you can have many, only one is linked as the active default at a time.

* **`excludes/`**: 
  * Contains `default.exclude` for global patterns and machine-specific exclude files (e.g., `alice@laptop.exclude`). Use `./bin/bloatscan.sh` to help identify patterns to add here.

* **`hooks-available/ --> hooks-enabled/`**:
  * Manage optional post-backup scripts. Place custom or provided hooks in `hooks-available/` and symlink them into `hooks-enabled/` to activate them. They are executed in numerical order based on their filename prefix.

* **`machines-available/ --> machines-enabled/`**: 
  * Define which machines and their specific source paths (`src=`) are part of the backup. Enable a machine for backup by symlinking its definition from `machines-available/` into `machines-enabled/`. The `bin/machine_state.sh` script helps manage these symlinks via 
    `./bin/machine_state.sh enable alice@laptop`

This structure allows for a modular and organized approach to managing multiple backup sources and configurations. For entirely separate backup *profiles*, see
[/tree/feature/multi-profile](https://github.com/brege/backup-kit/tree/feature/multi-profile)
for a more advanced solution.

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

It defines local/remote base paths for backups 

`LOCAL_TARGET_BASE`, `REMOTE_TARGET_BASE`

and archive destinations 

`LOCAL_ARCHIVE_BASE`, `REMOTE_ARCHIVE_BASE`. 

Customize these variables as needed. For example, 

`REMOTE_TARGET_BASE` 

might be 

`user@remoteserver:/backup/dest` 

and 

`REMOTE_ARCHIVE_BASE` 

could be 

`user@remoteserver:/backup/archives`.

To support multiple push targets or distinct configurations, you can use separate main configuration directories (e.g., `~/.config/backup-kit-main`, `~/.config/backup-kit-alternate`) and run backups against each using the `--config` flag:

```bash
./bin/run_backup.sh --config ~/.config/backup-kit-alternate
```

Alternatively, use the `./bin/use_env.sh` script to change the `config/backup.env` symlink to point to different environment files within your active configuration directory.

There is a branch available at [/tree/feature/multi-profile](https://github.com/brege/backup-kit/tree/feature/multi-profile) for better multi-profile support (**Work-in-progress**)

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

Enable a machine by symlinking its config to `machines-enabled/`. Use `./bin/machine_state.sh` to manage symlinks:

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
      1. Rsyncs each listed `src` path while respecting global (`excludes/default.exclude`) and machine-specific exclude files (e.g., `excludes/user@hostname`).
      2. **Staging Behavior**:
          - Scenario 1: only sync to a local target (like a mounted USB drive)
            - `LOCAL_TARGET_BASE = /path/to/local/target`
            - `REMOTE_TARGET_BASE = ""`
          - Scenario 2: only sync to a remote target (like a remote server)
            - `LOCAL_TARGET_BASE = ""`
            - `REMOTE_TARGET_BASE = /path/to/remote/target`
          - Scenario 3: sync to both a local and remote target
            - `LOCAL_TARGET_BASE = /path/to/local/target`
            - `REMOTE_TARGET_BASE = /path/to/remote/target`
            
            This scenario syncs to the local target first, then rsyncs the local target to the remote target.  For multiple machines, it does *all* the staging first, then syncs *all* of the staged targets to their corresponding remote targets.  
       3. After all machines are processed, it executes any enabled hook scripts found in the `hooks-enabled/` directory. Each hook is passed the paths to the root directories where each machine's data was backed up (e.g., `/path/to/target/user@hostA`, `/path/to/target/user@hostB`).

Rsync operations are incremental by default, preserving attributes and efficiently transferring only changed files. Note that the standard `90_archive.sh` hook, by default, will overwrite an existing archive for a given machine if run multiple times.

**TODO:** Add support for versioning archives by including a timestamp in the archive name and a congiurable archive retention period.

## Bloatscan Tool

**`bin/bloatscan.sh`** helps identify large subdirectories that might be wasteful to back up:

**Run locally:**
```bash
./bin/bloatscan.sh /var/lib/plexmediaserver --depth=3 --limit=10
```

This command scans `/var/lib/plexmediaserver` down to a depth of 3 levels and shows the top 10 largest directories.

**Run remotely:**
```bash
cat bin/bloatscan.sh | ssh user@host 'bash -s -- /remote/path/to/scan --depth=2 --limit=5'
```

The remote execution also supports flags like `--depth` and `--limit` after the path.

**Run iteratively:**
Look for folders with massive file counts or disk usage. Consider whether those are really worth preserving--often they come from package managers like `npm`, `pip`, `docker` etc, and can be reinstalled later. The tool can also use an exclude file similar to the backup excludes (by default `~/.config/backup-kit/excludes/user@host` or specify with `--excludes-file=path/to/file`).

## Notes

  - Rsync is incremental; archives created by the default `90_archive.sh` hook are not versioned by default.  (**TODO**).
  - This backup solution primarily preserves configuration and data files. It does not reinstall software packages.  **There is no provided restore process here.**  
  - To simulate a backup configuration (e.g., new exclude rules), use the `./setup --test` mode to run a simulated backup against test data, which isolates the test from your real data and production backup destination.

## Future Features

 - [**Multiple Profiles**](/tree/feature/multi-profile)
 - [**Encrypted Backups**] using `95_encrypt_archive.sh` for encrypted backups, using `gpg` and `gpg-agent`
 - [**Archive Versioning**] by including a timestamp in the archive name and a congiurable archive retention period

## License

This project is licensed under the [GNU GPL v3 LICENSE](/LICENSE).
