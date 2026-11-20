# Samba Server Toolkit: Test Plan and Verification Guide

> **Course:** Operating Systems Course Project  
> **Document Purpose:** Systematic validation of `samba-toolkit.sh` covering static analysis, dry-run simulation, and live Ubuntu integration testing.

---

## 1. Test Matrix Overview

| Test Case ID | Test Category | Target Component | Execution Environment | Expected Outcome |
| :--- | :--- | :--- | :--- | :--- |
| **TC-01** | Static Analysis | Bash syntax parser | Any OS / macOS / Ubuntu | `bash -n` returns exit code 0 |
| **TC-02** | CLI Interface | Help & version flags | Any OS / macOS / Ubuntu | Displays usage text and exits 0 |
| **TC-03** | Safety Guard | Non-root live execution | Non-root user | Blocks execution and instructs `sudo` |
| **TC-04** | Emulation | Dry-run mode (`-d`) | Non-root / Developer PC | Simulates actions without changes |
| **TC-05** | OS Detection | Non-Ubuntu OS check | macOS / Debian / RHEL | Rejects non-Ubuntu unless bypassed |
| **TC-06** | Package Install | Samba installation | Ubuntu 22.04 / 24.04 | Installs packages with confirmation |
| **TC-07** | Configuration | Share creation & perms | Ubuntu 22.04 / 24.04 | Creates dir with 2770, updates config |
| **TC-08** | Credentials | User Samba password | Ubuntu 22.04 / 24.04 | Sets `smbpasswd` without logging |
| **TC-09** | Fault Tolerance | Syntax error rollback | Ubuntu 22.04 / 24.04 | Catches error via `testparm`, rolls back |
| **TC-10** | Service Mgmt | Daemon reload | Ubuntu 22.04 / 24.04 | `smbd` reloaded without downtime |
| **TC-11** | Connectivity | Client authentication | Windows / macOS / Linux | Authenticated user OK; Guest denied |
| **TC-12** | Teardown | Share removal | Ubuntu 22.04 / 24.04 | Removes block, keeps or cleans files |
| **TC-13** | Service Control | Stop daemon on exit / CLI | Ubuntu 22.04 / 24.04 | Stops `smbd` & `nmbd` cleanly |

---

## 2. Non-Destructive Offline Tests (Developer Workstation / Local Machine)

These tests can be executed on any workstation (including macOS or Linux development machines) without requiring root privileges or touching system files.

### Test Case TC-01: Bash Syntax Validation
* **Objective:** Ensure the script contains no syntax errors, unmatched quotes, or illegal parameter expansions.
* **Command:**
  ```bash
  bash -n samba-toolkit.sh
  ```
* **Success Criteria:** Command completes with exit code `0` and zero output.

### Test Case TC-02: Command-Line Flags Validation
* **Objective:** Validate `--help`, `--version`, and argument parsing.
* **Commands:**
  ```bash
  ./samba-toolkit.sh --help
  ./samba-toolkit.sh --version
  ```
* **Success Criteria:** Displays formatted help documentation and version string `1.0.0` with exit code `0`.

### Test Case TC-03: OS Check & Bypass Mechanism
* **Objective:** Verify that the script properly detects non-Ubuntu operating systems, and allows safe dry-run inspection via `--skip-os-check`.
* **Commands:**
  ```bash
  # Attempt 1: Expect clean distribution error on non-Ubuntu machine
  ./samba-toolkit.sh --dry-run
  
  # Attempt 2: Expect successful dry-run execution with skip flag
  ./samba-toolkit.sh --dry-run --skip-os-check --info
  ```
* **Success Criteria:**
  - Attempt 1 surfaces a clear message that Ubuntu is required.
  - Attempt 2 executes the diagnostics and info output cleanly.

### Test Case TC-04: Non-Interactive CLI Query Commands
* **Objective:** Verify non-interactive operational queries without entering the interactive loop.
* **Commands:**
  ```bash
  ./samba-toolkit.sh --skip-os-check --info
  ./samba-toolkit.sh --skip-os-check --list
  ```
* **Success Criteria:** Outputs detected IP addresses and connection guides without entering an interactive loop.

---

## 3. Simulated Configuration Unit Test

To test the delimiter parser and configuration generator in isolation on a test configuration file:

### Test Case TC-05: Staged Configuration Modification
* **Objective:** Validate that the delimiter-based insertion and deletion logic preserves unrelated configuration.
* **Procedure:**
  1. Create a temporary dummy configuration file:
     ```bash
     cat << 'EOF' > /tmp/test_smb.conf
     [global]
         workgroup = WORKGROUP
         server string = Test Server
         log file = /var/log/samba/log.%m

     [existing_share]
         path = /srv/existing
         read only = yes
     EOF
     ```
  2. Invoke the toolkit pointing to `/tmp/test_smb.conf` in dry-run mode:
     ```bash
     ./samba-toolkit.sh --dry-run --skip-os-check -c /tmp/test_smb.conf
     ```
  3. Verify that the toolkit detects existing configuration without damaging it.
  4. Clean up:
     ```bash
     rm -f /tmp/test_smb.conf
     ```

---

## 4. Live Ubuntu Integration Testing (Ubuntu 22.04 / 24.04 Target VM)

The following procedures must be run on an Ubuntu test machine with `sudo` privileges.

### Phase 1: Environment & Package Verification
1. Launch toolkit with administrative rights:
   ```bash
   sudo ./samba-toolkit.sh
   ```
2. Select **[1] System Diagnostics & Environment Check**:
   - Verify that Ubuntu release (22.04 or 24.04) is recognized.
   - Confirm Effective User is `root (UID 0)`.
3. Select **[2] Install / Verify Samba Packages**:
   - Confirm the installation prompt.
   - Verify `apt-get` installs `samba`, `samba-common-bin`, and `smbclient`.
   - Confirm `smbd` daemon starts successfully.

### Phase 2: Share Creation & Authentication
1. Select **[3] Create or Update Password-Protected Share**:
   - Enter Share Name: `test_docs`
   - Directory Path: `/srv/samba/test_docs` (press enter for default)
   - Linux Username: `ubuntu` (or existing user on your VM)
   - Read-Only Mode: `N` (Read-Write)
   - Comment: `Integration Test Share`
   - Samba Password: enter a test password (e.g., `TestPassword123!`)
2. Confirm the planned summary.
3. Validate result:
   - Check directory permissions:
     ```bash
     ls -ld /srv/samba/test_docs
     # Must show: drwxrws--- (mode 2770) owned by ubuntu:ubuntu
     ```
   - Check `smb.conf` delimiters:
     ```bash
     grep -A 10 "BEGIN SAMBA-TOOLKIT MANAGED SHARE: \[test_docs\]" /etc/samba/smb.conf
     ```
   - Verify `guest ok = no` and `valid users = ubuntu`.

### Phase 3: Configuration Syntax & Intentional Fault Injection
1. Select **[5] Validate Configuration (testparm)**:
   - Verify `testparm` returns `Loaded services file OK`.
2. **Intentional Fault Test (Rollback Verification):**
   - Corrupt `/etc/samba/smb.conf` manually in a test run to confirm that the toolkit refuses to apply corrupt files and automatically rolls back:
     ```bash
     # Verify that timestamped backup exists
     ls -la /etc/samba/smb.conf.bak.*
     ```

### Phase 4: Network Access & smbclient Verification
1. Select **[8] Client Connection Instructions & IP Addresses** to find the server IP (e.g. `192.168.122.50`).
2. Run an authenticated client test:
   ```bash
   smbclient //127.0.0.1/test_docs -U ubuntu
   ```
   - Enter the test password.
   - Inside the SMB prompt, test file creation:
     ```smb: \>
     mkdir remote_test_dir
     put /etc/issue test_file.txt
     ls
     exit
     ```
   - Verify file permissions on the Linux host:
     ```bash
     ls -la /srv/samba/test_docs/test_file.txt
     # Must show mode -rw-rw---- (create mask 0660)
     ```
3. Test unauthenticated / guest access (Must be blocked):
   ```bash
   smbclient //127.0.0.1/test_docs -N
   ```
   - Expected output: `NT_STATUS_ACCESS_DENIED` or `anonymous logon failed`.

### Phase 5: Managed Share Removal
1. Select **[7] Remove a Managed Share**:
   - Select share `test_docs`.
   - Review removal impact summary.
   - Confirm configuration block removal.
   - Choose whether to retain files or delete directory.
2. Verify:
   - Delimiter block for `[test_docs]` is gone from `/etc/samba/smb.conf`.
   - Global settings and other shares remain intact.
   - `testparm` succeeds.
   - `smbcontrol smbd close-share` signals worker processes to close active connections.
   - `smbd` restarts/reloads cleanly, severing active client sessions.
   - Connected clients (Windows/macOS) are disconnected once client caches are cleared.

### Phase 6: Audit Log Inspection
1. Select **[9] View Audit Log**:
   - Confirm log entries recorded timestamped entries for:
     - `INFO: Backup created: ...`
     - `INFO: Samba credentials updated for user 'ubuntu'`
     - `INFO: testparm validation passed`
     - `INFO: smbd service reloaded`
   - Verify that NO passwords or credentials appear in the log file (`/var/log/samba-toolkit.log`).

---

## 5. Security & Edge Case Checklist

- [x] Variable Quoting: All Bash variables quoted to protect against word splitting and pathname expansion.
- [x] Input Validation: Share names restricted to `^[a-zA-Z0-9_-]{1,30}$`.
- [x] Path Protection: Prohibited paths (`/`, `/etc`, `/bin`, `/usr`, `/root`) prevented from being exposed as shares.
- [x] No `eval`: Script contains zero dynamic evaluations.
- [x] No `chmod 777`: Strict directory mask `2770` and file mask `0660` enforced.
- [x] No Password Leaks: Passwords piped directly to `smbpasswd` via stdin and wiped with `unset`.
- [x] Safe Signal Trapping: Temporary staging files in `/tmp` destroyed automatically via `trap cleanup EXIT INT TERM`.
