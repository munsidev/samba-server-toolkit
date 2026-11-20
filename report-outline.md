# Operating Systems Course Project Report Outline
## Project: Samba Server Setup and Management Toolkit

**Author:** Khalid hasan munsi  
**Course:** Operating Systems  
**Instructor:** Sayeda Parvin  
**Date:** 21/11/2026  
**Target Environment:** Ubuntu Linux 22.04 LTS (Jammy Jellyfish)

---

### Abstract
A concise summary (150–250 words) outlining the design and implementation of an automated, security-hardened Samba Server Setup and Management Toolkit written in Bash. The project bridges theoretical operating systems concepts—such as the Virtual File System (VFS), POSIX user/group discretionary access control (DAC), Inter-Process Communication (IPC), service daemons, and network file sharing protocols (SMB/CIFS)—with real-world systems administration on modern Ubuntu Linux. Key mechanisms highlighted include delimiter-based idempotent configuration editing, atomic syntax verification with `testparm`, automated rollback on syntax corruption, and secure credential passing without disk or log leakage.

---

### Table of Contents
1. **Introduction & Motivation**
2. **Theoretical Background & OS Concepts**
   - 2.1 Network File Systems vs. Local File Systems (VFS Abstraction)
   - 2.2 The SMB/CIFS Protocol Family & Protocol Evolution
   - 2.3 Operating System Security Models: POSIX DAC vs. NT ACLs
   - 2.4 Authentication Mechanisms and Credential Management
   - 2.5 Daemon Architecture, Concurrency, and File Locking
   - 2.6 Service Supervision and Daemon Lifecycle under `systemd`
3. **Architecture and Design of the Toolkit**
   - 3.1 Design Philosophy: Safety, Modularity, and Idempotency
   - 3.2 Delimiter-Scoped Configuration Block Model
   - 3.3 Transactional Configuration Updates and Atomic Rollback
   - 3.4 Dry-Run Emulation Engine
4. **Implementation Details**
   - 4.1 Shell Script Architecture & Defensive Programming (`set -euo pipefail`)
   - 4.2 System & Privilege Verification (`/etc/os-release`, `EUID`)
   - 4.3 Secure Password Ingestion via Stdin Pipe (`smbpasswd`)
   - 4.4 Non-Destructive File Permission Hardening (Mode 2770 vs. 777)
   - 4.5 Configuration Parser and Awk-based Block Replacement
   - 4.6 IP Address Discovery and Multi-OS Client Instruction Engine
5. **Testing, Verification, and Evaluation**
   - 5.1 Test Environment Specification
   - 5.2 Static Code Analysis & Syntax Verification (`bash -n`)
   - 5.3 Dry-Run Simulation Verification
   - 5.4 Live Integration Testing on Ubuntu 22.04 / 24.04 LTS
   - 5.5 Fault Injection: Intentional Syntax Corruption & Rollback Validation
   - 5.6 Multi-Client Access Verification (Windows, macOS, Linux `smbclient`)
6. **Security Analysis & Threat Model**
   - 6.1 Threat Vectors and Mitigations
   - 6.2 Credential Exposure Prevention (Process Table, History, Logs)
   - 6.3 Principle of Least Privilege in File System Permissions
   - 6.4 Denial-of-Service and Fault Tolerance
7. **Discussion, Limitations, and Future Work**
   - 7.1 Key Findings & Engineering Trade-offs
   - 7.2 Current Limitations (Standalone Server vs. Active Directory Domain)
   - 7.3 Future Enhancements (Kerberos SSO, ZFS/Btrfs Snapshot integration, Quota Management)
8. **Conclusion**
9. **References & Standards**

---

### Detailed Section Breakdown

#### 1. Introduction & Motivation
- **Context:** The necessity of heterogeneous resource sharing across POSIX (Linux/UNIX) and non-POSIX (Windows, macOS) operating systems.
- **Problem Statement:** Manual configuration of Samba via `/etc/samba/smb.conf` is error-prone, risks service disruption from minor typos, frequently leads to dangerous permission shortcuts (such as `chmod 777`), and lacks transactional rollback protections.
- **Project Goal:** Develop a robust, modular Bash toolkit that automates package installation, idempotent share configuration, user credentialing, validation, and maintenance on Ubuntu LTS while strictly enforcing OS-level security constraints.

#### 2. Theoretical Background & OS Concepts
- **2.1 Network File Systems vs. Local File Systems (VFS Abstraction):**
  - How Linux Virtual File System (VFS) abstracts storage backends (`ext4`, `xfs`, `btrfs`) behind standard system call interfaces (`open()`, `read()`, `write()`, `close()`).
  - How a network file server intercept client requests over TCP/IP sockets and maps remote operations onto the local VFS.
- **2.2 The SMB/CIFS Protocol Family & Protocol Evolution:**
  - Historical transition from NetBIOS/SMB1 (chatty, unencrypted, security vulnerabilities such as WannaCry/EternalBlue) to SMB2 and modern SMB3 (AES encryption, message signing, multi-channel performance, multichannel failover).
- **2.3 Operating System Security Models: POSIX DAC vs. NT ACLs:**
  - Contrast between POSIX 9-bit permission masks (Owner, Group, Others) with setuid/setgid/sticky bits and Windows Security Identifiers (SIDs) with Access Control Lists (ACLs).
  - How Samba mediates between these two disparate security paradigms.
  - Justification for rejecting `chmod 777` and employing `chmod 2770` with `create mask = 0660` and `directory mask = 0770`.
- **2.4 Authentication Mechanisms and Credential Management:**
  - Decoupling of UNIX authentication (`/etc/shadow`, PAM) from SMB authentication (NTLMv2 / Kerberos).
  - Role of Samba’s password database (`smbpasswd` / `tdbsam`) and why Samba requires storing NT password hashes independently from standard Linux password hashes.
- **2.5 Daemon Architecture, Concurrency, and File Locking:**
  - Analysis of Samba’s multi-process architecture: parent listener daemon `smbd` accepting connections on port 445/139 and forking client-specific worker processes.
  - Concurrency control: POSIX byte-range record locks (`fcntl()`) vs. SMB opportunistic locks (oplocks) and client caching leases.
- **2.6 Service Supervision and Daemon Lifecycle under `systemd`:**
  - Role of `systemd` as PID 1, cgroup isolation, process tracking, socket activation, and configuration reloading (`systemctl reload` sending `SIGHUP` to re-read configuration without terminating active client connections).

#### 3. Architecture and Design of the Toolkit
- **3.1 Design Philosophy:**
  - Defensive shell programming, idempotency, strict non-destructive defaults, explicit confirmation gates, and absolute zero password leakage.
- **3.2 Delimiter-Scoped Configuration Block Model:**
  - Using machine-parseable comment banners to define share boundaries:
    `# === BEGIN SAMBA-TOOLKIT MANAGED SHARE: [<name>] ===`
    `# === END SAMBA-TOOLKIT MANAGED SHARE: [<name>] ===`
  - Preservation of system-wide `[global]` directives and unmanaged shares.
- **3.3 Transactional Configuration Updates and Atomic Rollback:**
  - Three-stage commit pipeline:
    1. *Backup:* Capture timestamped copy of `/etc/samba/smb.conf`.
    2. *Staging:* Assemble new configuration in a secure volatile temporary file (`mktemp`).
    3. *Validation Gate:* Execute `testparm -s` against candidate configuration.
    4. *Commit / Revert:* If validation passes, copy into place and trigger `systemctl reload smbd`. If validation fails, discard staged buffer, restore original backup, and surface diagnostic messages.
- **3.4 Dry-Run Emulation Engine:**
  - Architecture of the `--dry-run` flag: intercepts mutating commands (`mkdir`, `chown`, `chmod`, `smbpasswd`, `apt-get`, `cp`, `systemctl`) and emits structured descriptions of planned state transitions without modifying the host OS.

#### 4. Implementation Details
- **4.1 Shell Script Architecture:**
  - Use of `set -euo pipefail` to abort on unhandled errors, unset variables, and piped command failures.
  - Signal trapping (`trap cleanup EXIT INT TERM`) to guarantee destruction of temporary directories created via `mktemp`.
- **4.2 System & Privilege Verification:**
  - Verification of `/etc/os-release` detecting Ubuntu ID and version strings (22.04 / 24.04).
  - Validation of effective user ID (`EUID == 0`) with descriptive guidance to invoke `sudo`.
- **4.3 Secure Password Ingestion:**
  - Use of `read -s` to disable terminal echo during password entry.
  - Piping password through standard input directly to `smbpasswd -s -a <user>`, preventing exposure in `/proc/<pid>/cmdline` or shell history files. Immediate cleanup using `unset`.
- **4.4 Non-Destructive File Permission Hardening:**
  - Enforcing `chmod 2770` on the shared folder and ownership `user:user`.
  - Explanation of setgid bit (2xxx) to ensure all newly created subdirectories inherit group permissions.
  - Configuration of Samba create mask (`0660`) and directory mask (`0770`) to prevent world access.
- **4.5 Configuration Parser (`awk`):**
  - Clean state machine in `awk` to excise or replace share blocks based on boundary patterns without corrupting surrounding comments or whitespace.
- **4.6 Network Discovery:**
  - Automated detection of non-loopback IPv4 addresses using `ip -4 -o addr show scope global`.
  - Generation of OS-tailored connection strings for Windows UNC (`\\IP\share`), macOS (`smb://user@IP/share`), and Linux CIFS mounts.

#### 5. Testing, Verification, and Evaluation
- **5.1 Test Environment Specification:**
  - Hardware/VM specifications (e.g., Ubuntu 22.04 LTS VM, Ubuntu 24.04 LTS VM, 2 vCPUs, 2GB RAM, bridged/host-only networking).
- **5.2 Static Code Analysis:**
  - Syntax verification via `bash -n samba-toolkit.sh`.
  - ShellCheck validation ensuring strict POSIX compatibility and absence of common pitfalls (unquoted variables, unsafe globbing).
- **5.3 Dry-Run Simulation Results:**
  - Verification that invoking with `-d` prints planned commands and produces zero file system or package state changes.
- **5.4 Live Integration Testing:**
  - Step-by-step log of package installation, user creation, directory creation, config modification, and service reload.
- **5.5 Fault Injection & Rollback Testing:**
  - Injecting intentional syntax errors (e.g., malformed directive `path = ` or invalid boolean values) to verify that `testparm` catches the error and the backup file is restored without service disruption.
- **5.6 Multi-Client Access Verification:**
  - Successful read/write operations from Windows 11, macOS Sequoia, and Ubuntu Linux clients using valid credentials.
  - Verification that unauthenticated (guest) access is rejected with `NT_STATUS_ACCESS_DENIED`.

#### 6. Security Analysis & Threat Model
- Detailed matrix analyzing threats:
  - *Threat: Password snooping in process table.* (Mitigated by stdin piping to `smbpasswd`).
  - *Threat: Unauthorized guest reading files.* (Mitigated by `guest ok = no` and `valid users = user`).
  - *Threat: World-writable data exposure.* (Mitigated by `chmod 2770`, avoiding `777`).
  - *Threat: Command injection via input parameters.* (Mitigated by regex whitelisting for share names and paths, avoidance of `eval`).
  - *Threat: Service disruption due to malformed configuration.* (Mitigated by atomic `testparm` validation gate).

#### 7. Discussion, Limitations, and Future Work
- **Trade-offs:** Shell scripting provides zero-dependency portability across any standard Ubuntu deployment, though an object-oriented language (e.g., Python with `libsmbconf`) could offer native configuration AST parsing.
- **Limitations:** Focuses on standalone workgroup file sharing rather than Active Directory Domain Controller (AD DC) joined environments.
- **Future Directions:**
  - Integration with Kerberos / SSSD for enterprise domain logins.
  - Automated ZFS or Btrfs snapshot management for share shadow copies (Previous Versions).
  - Disk quota enforcement via `edquota` / `setquota`.

#### 8. Conclusion
- Summary of learning outcomes: mastery of Linux daemon administration, SMB networking architecture, UNIX permission hierarchies, secure input handling, and fault-tolerant systems programming in Bash.

#### 9. References & Standards
- Microsoft SMB Protocol Specification (MS-SMB2 / MS-SMB)
- Samba Official Documentation & HOWTO Collection (Samba.org)
- RFC 1001 / RFC 1002: Protocol Standard for a NetBIOS Service on a TCP/UDP Transport
- Ubuntu Server Guide: File Servers (Samba)
- POSIX IEEE Std 1003.1 Standard for Discretionary Access Control
