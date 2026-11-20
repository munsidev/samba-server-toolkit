# Samba Server Setup and Management Toolkit

> **Course:** Operating Systems Course Project  
> **Target OS:** Ubuntu Linux 24.04 LTS 
> **Language:** Bash Shell Script (`samba-toolkit.sh`)  
> **Author:** Khalid hasan Munsi  

---

## 1. Project Purpose & Scope

The **Samba Server Setup and Management Toolkit** is an automated, modular, and security-hardened administration utility written primarily in Bash. It allows system administrators to deploy, configure, inspect, and manage production-grade Samba file shares on Ubuntu Linux systems without manual, error-prone edits to `/etc/samba/smb.conf`.

### Core Objectives
* **Automation & Usability:** Provide a clean, intuitive terminal menu alongside non-interactive CLI flags.
* **Safety First:** Never apply changes to Samba configuration without a timestamped backup and automatic syntax verification via `testparm`. If validation fails, changes are instantly reverted.
* **Idempotency:** Maintain configuration sections using explicit delimiter blocks so that shares can be updated or removed cleanly without disrupting existing or unmanaged shares.
* **Security & Least Privilege:** Enforce strict password-protected access; explicitly forbid anonymous guest access; avoid dangerous permission changes (e.g., no `chmod 777`); prevent credential exposure in shell history, process tables, or logs.

---

## 2. System Requirements & Prerequisites

* **Operating System:** Ubuntu 22.04 LTS or 24.04 LTS (x86_64, aarch64, or arm64).
* **Shell:** GNU Bash 4.4+.
* **Privileges:** `sudo` or root user (`EUID == 0`) for live execution (dry-run mode is available without root).
* **Core Utilities:** `systemctl`, `ip` (or `hostname`), `grep`, `sed`, `awk`, `mktemp`.
* **Samba Packages (installed via toolkit):** `samba`, `smbclient`, `samba-common-bin`.

---

## 3. Architecture & Safety Features

```
+-----------------------------------------------------------------------------+
|                             samba-toolkit.sh                                |
+-----------------------------------------------------------------------------+
                                       |
          +----------------------------+----------------------------+
          |                                                         |
          v                                                         v
  [1] Environment & Privs                                   [2] Configuration
  - Verify Ubuntu 22.04/24.04                               - Create timestamped backup
  - Verify EUID 0 or Dry-Run                                - Stage edits in /tmp/
  - Detect systemctl & networking                           - Delimiter-scoped block
          |                                                         |
          +----------------------------+----------------------------+
                                       |
                                       v
                             [3] Atomic Validation
                             - Run `testparm -s` on staged file
                             - If PASS: copy to /etc/samba/smb.conf
                             - If FAIL: discard stage, restore backup
                                       |
                                       v
                             [4] Daemon Reload
                             - `systemctl reload-or-restart smbd`
                             - Zero downtime for unaffected shares
```

### Key Safety Mechanisms
1. **Timestamped Backups:** Before any alteration to `/etc/samba/smb.conf`, a backup is generated in the format `/etc/samba/smb.conf.bak.YYYYMMDD_HHMMSS`.
2. **Atomic Staging & Rollback:** Changes are built in an isolated temporary buffer using `mktemp`. `testparm` inspects the candidate file. The production configuration is updated if and only if `testparm` succeeds with return code 0. If syntax fails, the toolkit rolls back and surfaces the exact error.
3. **Delimiter Markers:** Managed shares are encapsulated within explicit comment banners:
   ```ini
   # === BEGIN SAMBA-TOOLKIT MANAGED SHARE: [share_name] ===
   [share_name]
       comment = ...
       path = /srv/samba/...
       valid users = username
       read only = no
       browsable = yes
       guest ok = no
       create mask = 0660
       directory mask = 0770
   # === END SAMBA-TOOLKIT MANAGED SHARE: [share_name] ===
   ```
   This prevents duplication and ensures removal actions delete only the targeted section.
4. **Credential Isolation:** Passwords for `smbpasswd` are captured via silent terminal input (`read -s`) and piped directly via stdin (`printf "%s\n%s\n" ... | smbpasswd -s -a ...`). The variable is unset immediately, ensuring passwords never appear in `/proc/$PID/cmdline`, shell history, configuration files, or logs.
5. **No Dangerous Permissions:** Shared directories default to mode `2770` (setgid + owner/group read-write-execute, others zero access). The toolkit strictly avoids `chmod 777`.

---

## 4. Installation & Getting Started

### 1. Download or Clone the Toolkit
Ensure the script is located on your Ubuntu machine or VM:
```bash
chmod +x samba-toolkit.sh
```

### 2. Run in Dry-Run Mode (Preview / Demonstration)
To test the interface and preview all operations without modifying system packages, files, or services:
```bash
./samba-toolkit.sh --dry-run
```
*(On non-Ubuntu developer workstations, add `--skip-os-check` to preview menu workflows).*

### 3. Run with Sudo (Live Management)
On your Ubuntu server:
```bash
sudo ./samba-toolkit.sh
```

---

## 5. Command-Line Options

The toolkit supports both an interactive text menu and non-interactive status flags:

| Flag | Description |
| :--- | :--- |
| `-d`, `--dry-run` | Run in simulation mode without making real changes. |
| `--skip-os-check` | Bypass Ubuntu distribution verification (for dry-run testing). |
| `-c`, `--config PATH` | Override configuration file path (default: `/etc/samba/smb.conf`). |
| `--status` | Print current `smbd` / `nmbd` service status and exit. |
| `--start` | Start Samba service and exit. |
| `--stop` | Stop Samba services (`smbd` & `nmbd`) and exit. |
| `--restart` | Restart Samba service (severs active sessions) and exit. |
| `--list` | List all toolkit-managed shares and exit. |
| `--validate` | Run `testparm` validation against the configuration and exit. |
| `--info` | Display host IP addresses and client connection instructions. |
| `-h`, `--help` | Display usage instructions and available arguments. |
| `-v`, `--version` | Display toolkit version. |

---

## 6. Menu Options Walkthrough

When launched without non-interactive flags, the toolkit presents an interactive menu:

```
================================================================================
  Samba Server Setup and Management Toolkit (v1.0.0)
================================================================================
 Course: Operating Systems Project | Target: Ubuntu 22.04 / 24.04 LTS
 MODE: [LIVE EXECUTION] (EUID: 0)
 Config File: /etc/samba/smb.conf
================================================================================
  [1] System Diagnostics & Environment Check
  [2] Install / Verify Samba Packages
  [3] Create or Update Password-Protected Share
  [4] List Managed Shares & Settings
  [5] Validate Configuration (testparm)
  [6] Check Samba Service Status
  [7] Remove a Managed Share
  [8] Client Connection Instructions & IP Addresses
  [9] View Audit Log
  [S] Start / Stop / Restart Samba Service
  [T] Toggle Dry-Run Mode (Disabled)
  [0] Exit Toolkit (Option to stop Samba on exit)
================================================================================
```

### Option 1: System Diagnostics & Environment Check
* Evaluates Linux distribution and release against supported targets.
* Verifies effective execution privileges (`EUID`).
* Inspects whether essential binaries (`testparm`, `smbd`, `smbpasswd`, `systemctl`, `ip`, `awk`, `sed`) are installed and reports their paths.

### Option 2: Install / Verify Samba Packages
* Detects whether Samba is already installed.
* Explains planned `apt-get` actions and explicitly requests confirmation before installing `samba`, `samba-common-bin`, and `smbclient`.
* Automatically enables and starts `smbd` daemon upon package installation.

### Option 3: Create or Update Password-Protected Share
* Prompts for share name, validating against RFC and SMB naming rules (alphanumeric, hyphens, underscores; disallows reserved keywords like `global`, `homes`, `ipc$`).
* Prompts for directory path (default `/srv/samba/<share_name>`) and protects system roots (`/`, `/etc`, `/usr`, etc.).
* Validates that the authorized user exists in `/etc/passwd`. Offers to create an unprivileged system user (`nologin`) if needed.
* Allows choosing Read-Write or Read-Only mode.
* Securely prompts for Samba password via `read -s` with confirmation, synchronizing `smbpasswd`.
* Creates directory with `chmod 2770` and `chown user:user`.
* Atomically validates and applies configuration block into `/etc/samba/smb.conf` with automatic rollback on error.
* Gracefully reloads `smbd`.

### Option 4: List Managed Shares & Settings
* Scans `smb.conf` for toolkit delimiter blocks.
* Displays a structured summary table showing share name, directory path, authorized user, and read-only status.

### Option 5: Validate Configuration (`testparm`)
* Directly triggers `testparm -s` on the active configuration file and displays parsed service definitions and any warnings.

### Option 6: Check Samba Service Status
* Queries `systemctl is-active` and `systemctl is-enabled` for `smbd` and `nmbd`.
* Pulls recent journald log entries (`journalctl -u smbd -n 10`) for live diagnostics.

### Option 7: Remove a Managed Share
* Lists currently managed shares for interactive selection.
* Explains the exact impact of removal.
* Creates a timestamped backup before touching the config.
* Excises only the target delimiter block.
* Asks whether to keep the directory files (safe default) or delete them (requires typing `DELETE`).
* Validates resulting configuration with `testparm` and reloads `smbd`.

### Option 8: Client Connection Instructions & IP Addresses
* Discovers all active non-loopback IPv4 addresses.
* Formats copy-pasteable client connection strings for Windows UNC paths, macOS Finder SMB URLs, and Linux `smbclient` or `mount -t cifs`.
* Explains UFW firewall port requirements (139, 445 TCP; 137, 138 UDP).

### Option 9: View Audit Log
* Displays recent timestamped operational logs from `/var/log/samba-toolkit.log` (or local fallback).

### Option S: Start / Stop / Restart Samba Service
* Dedicated service control sub-menu allowing administrators to manually start `smbd`, stop `smbd` & `nmbd`, reload configuration, or restart to terminate active client sessions.

### Option T: Toggle Dry-Run Mode
* Instantly switches between Live Execution and Dry-Run mode without exiting the script.

### Option 0: Exit Toolkit (with Samba Service Stop prompt)
* Safely exits the toolkit. If Samba is running, it prompts:
  `Would you like to stop the Samba service before exiting? [Y/n]`
  Default is **Yes** (`Y`), allowing you to completely stop Samba upon exit with a single keystroke.

---

## 7. Connecting from Client Operating Systems

Assuming server IP `192.168.1.50`, share `project_files`, and username `os_user`:

### Windows Clients
1. Open **File Explorer** and enter in the address bar:
   ```
   \\192.168.1.50\project_files
   ```
2. Enter username `os_user` and the Samba password configured via the toolkit.
3. Or map to drive `Z:` via Command Prompt:
   ```cmd
   net use Z: \\192.168.1.50\project_files /user:os_user *
   ```

### macOS Clients
1. Open **Finder** and press `Command + K` (Connect to Server).
2. Enter the address:
   ```
   smb://os_user@192.168.1.50/project_files
   ```
3. Enter credentials when prompted.

### Linux Clients
* Using `smbclient` (CLI interactive session):
  ```bash
  smbclient //192.168.1.50/project_files -U os_user
  ```
* Mounting as a file system:
  ```bash
  sudo mkdir -p /mnt/samba_share
  sudo mount -t cifs //192.168.1.50/project_files /mnt/samba_share -o username=os_user
  ```

---

## 8. Security Analysis & Best Practices

1. **Explicit Authentication Only:** The share definition forces `guest ok = no` and `valid users = <user>`. Anonymous access is blocked at the protocol level.
2. **Zero Password Leakage:** Passwords are never placed into positional parameters, command-line arguments, environment exports, or log files. Variables holding passwords are wiped immediately with `unset`.
3. **Defense-in-Depth File Permissions:**
   - Directory: `chmod 2770` ensures only the owner and members of the owner's group can list or modify files. The `setgid` bit guarantees that any newly created files inherit the directory's group ownership.
   - Files: `create mask = 0660` prevents world-readable file creation.
   - Directories: `directory mask = 0770` prevents world-accessible folder creation.
4. **Network Scoping:** Samba is intended for trusted local networks (LANs). Do not expose ports 139 or 445 directly to the public internet. If remote access is needed, route traffic through a secure WireGuard or OpenVPN tunnel.
5. **No `eval`:** Script execution utilizes strict quoting (`"$var"`) and avoids dynamic shell code evaluation (`eval`), eliminating shell injection vulnerabilities.

---

## 9. Troubleshooting

* **Permission Denied when connecting:**
  - Verify that the Linux user exists: `id <username>`
  - Verify Samba credentials: run Option 3 in the toolkit to re-set the Samba password via `smbpasswd`.
  - Ensure the local directory permissions match: `ls -ld <path>`.
* **Cannot find server / Host unreachable:**
  - Check if UFW firewall is active: `sudo ufw status`. Allow Samba traffic with:
    ```bash
    sudo ufw allow samba
    ```
  - Verify `smbd` daemon is running: run Option 6 in the toolkit or execute `systemctl status smbd`.
* **Removed a share, but connected clients still see files or have access:**
  - **Why it happens:** Samba uses a multi-process architecture where a child worker process is forked for each connected client. A simple service reload (`SIGHUP`) prevents *new* connections from accessing the removed share, but existing TCP/SMB sessions remain open in the child worker until the client unmounts or the process terminates. Additionally, Windows and macOS aggressively cache SMB session tokens and file handles in memory.
  - **Server Fix:** Run `sudo smbcontrol smbd close-share <share_name>` or restart the Samba daemon with `sudo systemctl restart smbd` to immediately sever all active client connections.
  - **Client Fix (Windows):** Open Command Prompt and run:
    ```cmd
    net use \\<server-ip>\<share_name> /delete
    ```
    or clear all active connections:
    ```cmd
    net use * /delete /y
    ```
  - **Client Fix (macOS):** In Finder, click the **Eject** button next to the network share in the sidebar, or in Terminal run:
    ```bash
    umount /Volumes/<share_name>
    ```

* **Configuration syntax error:**
  - Run Option 5 in the toolkit to execute `testparm -s` and inspect syntax line by line.

---

## 10. File Summary

* `samba-toolkit.sh`: Main executable Bash program.
* `README.md`: Project documentation and user manual.
* `report-outline.md`: Academic OS course report outline.
* `test-plan.md`: Comprehensive verification and test guide.
* `sample-smb.conf`: Example reference configuration with delimiter markers.
