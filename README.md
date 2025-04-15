# Backup Package for Server Management `backup-kit`

This package automates the process of backing up specified directories from remote servers to a local backup location. It includes a service and timer to handle backups on a scheduled basis, with options for daily, hourly, or custom intervals.

## Table of Contents

- [Installation](#installation)
- [Configuration](#configuration)
  - [Backup Configuration (`backup.paths`)](#backup-configuration-backuppaths)
  - [Backup Excludes (`backup_excludes`)](#backup-excludes-backup_excludes)
- [Service Setup](#service-setup)
  - [User-Specific Service and Timer](#user-specific-service-and-timer)
- [Backup Script (`run_backup.sh`)](#backup-script-run_backups)
- [Logs](#logs)
- [Important Notes](#important-notes)
- [License](#license)

---

## Installation

1. Clone or download the repository:
   
   ```bash
   git clone <repo-url>
   ```

2. Place the package in the desired location. For example, `/home/notroot/backup-kit`.

3. Ensure the directory structure looks like this:
   ```bash
   backup-kit/
   ├── backup_excludes/
   │   ├── notroot@beelink
   │   ├── notroot@server
   │   └── scraper@server
   ├── backup.paths
   ├── run_backup.sh
   ├── .gitignore
   └── README.md
   ```

## Configuration

Backup Configuration (`backup.paths`)

This file defines which directories are backed up from each source. Each section corresponds to a remote server user, followed by the directories to be backed up, and any exclusions.

**Example:**
```ini
[notroot@beelink]
exclude-from=/home/notroot/backup_excludes/notroot@beelink
src=/opt/jellyseerr/config
src=/etc/jellyseerr
src=/etc/systemd/system/jellyseerr.service
src=/home/notroot/
src=/var/lib/plexmediaserver/

[scraper@server]
src=/home/scraper
exclude-from=/home/notroot/backup_excludes/scraper@server
src=/var/lib/prowlarr
src=/var/lib/sonarr
src=/opt/jellyseerr/config

[notroot@server]
src=/home/notroot
exclude-from=/home/notroot/backup_excludes/notroot@server
src=/usr/share/nginx
src=/etc/systemd/system/radarr.service
```

## Backup Excludes (`backup_excludes`)

This folder contains exclusions for each user or server, preventing unnecessary files (e.g., cache, temporary files) from being included in backups. Each file is named according to the format `user@host`.

## Service Setup

### User-Specific Service and Timer

The backup service and timer can be set up to run automatically at scheduled intervals using `systemd`. This can be installed on a per-user basis, ensuring it doesn't affect system-wide services.

1. **Service File** (`backup.service`)

The `backup.service` file specifies the script to run for backups.

Create the service file at`~/.config/systemd/user/backup.service`:
```
[Unit]
Description=Run Backup

[Service]
ExecStart=/home/notroot/backup_package/run_backup.sh
```

2. **Timer File** (`backup.timer`)

The `backup.timer` file defines when the service should run. You can choose from various schedules, such as daily, hourly, or every 6 hours.

Create the timer file at `~/.config/systemd/user/backup.timer`:
```
[Unit]
Description=Run Backup Timer

[Timer]
OnCalendar=daily
# For hourly backups, uncomment the next line:
# OnCalendar=hourly
# For backups every 6 hours, uncomment the next line:
# OnCalendar=*-*-* 00,06,12,18:00:00

Unit=backup.service

[Install]
WantedBy=timers.target
```

3. **Enabling and Starting the Timer**

Once the service and timer files are created, enable and start the timer for the user:
```bash
systemctl --user daemon-reload
systemctl --user enable backup.timer
systemctl --user start backup.timer
```

This will schedule the backup task as defined in the timer file.

4. **Check the Timer Status**

You can check the status of the timer with:
```bash
systemctl --user status backup.timer
```

## Backup Script (`run_backup.sh`)

The backup script uses rsync to copy the specified directories from remote servers to the local backup location.

**Important:** The script runs based on the configuration in `backup.paths`, excluding directories specified in `backup_excludes`.

You can customize the backup script (`run_backup.sh`) as necessary, but the default script works as follows:

- It reads the `backup.paths` file and pulls the directories listed under each user/server.
- It then runs `rsync` to transfer those directories to the local backup folder.
- Afterward, it saves the current crontab for `notroot` to allow easy restoration.

## Logs

Logs for the backup process can be viewed using standard `systemd` commands. Since this is a user-specific service, logs are saved under the user's journal.

To view the logs:
```bash
journalctl --user -u backup.service
```

## Bonus Tool: `bloatscan.sh` - Disk Usage Scanner

This utility script helps you identify the largest directories in your system by walking the filesystem tree up to a specified depth and sorting by total size. It's useful for investigating bloated directories and optimizing backup targets.

**Usage**
```bash
./bloatscan.sh [TARGET_DIR] [--depth=N] [--limit=N]
```
- `TARGET_DIR` (optional) – the base directory to scan (defaults to $HOME)

- `--depth=N` – how deep the directory tree should be scanned (default: 4)

- `--limit=M` – how many of the largest directories to show (default: 30)

**Example**
```bash
~/backup-kit/bin/bloatscan.sh /home/notroot --depth=3 --limit=10
```

Sample output:
```bash
🔍 Scanning: /home/notroot/
🧭 Max depth: 3
📉 Showing top 10 entries

Size             Files      Dirs  Top-Level             Path
4.3GiB           17361         4  docker                /home/notroot/docker
3.9GiB           15920         2  docker                /home/notroot/docker/jellyfin
3.8GiB           13671         6  docker                /home/notroot/docker/jellyfin/config
2.6GiB           74143         2  .local                /home/notroot/.local
1.4GiB              35         3  .local                /home/notroot/.local/state
1.4GiB              31         1  .local                /home/notroot/.local/state/syncthing
1.3GiB           74108        13  .local                /home/notroot/.local/share
1.3GiB           74090         1  .local                /home/notroot/.local/share/pnpm
1.2GiB           12530        15  .cache                /home/notroot/.cache
1.1GiB           11414         2  .cache                /home/notroot/.cache/mozilla/firefox
```
You can rerun the script and zoom in on a bloated directory like this:
```bash
~/backup-kit/bin/bloatscan.sh /home/notroot/.local --depth=2 --limit=5
```
That is:
```
🔍 Scanning: /home/notroot/.local
🧭 Max depth: 2
📉 Showing top 5 entries

Size             Files      Dirs  Top-Level             Path
1.4GiB              35         3  .local                /home/notroot/.local/state
1.4GiB              31         1  .local                /home/notroot/.local/state/syncthing
1.3GiB           74108        13  .local                /home/notroot/.local/share
1.3GiB           74090         1  .local                /home/notroot/.local/share/pnpm
296KiB               1         1  .local                /home/notroot/.local/share/nautilus
```
This is helpful for drilling down into suspected large usage paths and identifying directories you may want to **exclude from backup** by editing the appropriate `backup_excludes/<user>@<host>` file.

You can also check on directories on a remote server you're interested in backing up:
```
cat ~/backup-kit/bin/bloatscan.sh | ssh scraper@server 'bash -s' -- /home/scraper  --depth=3 --limit=20
```

## Important Notes

This script **creates a duplicate** of the specified files and directories at each run. That means **it copies the entire data set** into a separate backup location rather than synchronizing changes or storing incremental differences.

**Recommended Usage:**

- Set the backup target to a directory that’s:

  * **Watched by [Syncthing](https://syncthing.net/downloads/)** or a similar sync tool to move it offsite.

  * **Mounted on a storage or network volume** if boot/OS drive is low on space (e.g. an external drive, NAS share, or cloud mount).

Because this script runs at a fixed interval (e.g. daily or hourly), it works well with systems that **don’t need real-time sync** but do need consistent snapshots of critical data.

**Tip:** Monitor backup growth live with:
```bash   
watch -n 1 'du -sh /home/notroot/Syncthing/server_backup/*'
```
This helps spot unexpectedly large changes and ensures backup behavior is as expected.

## License

This project is licensed under the MIT License.
