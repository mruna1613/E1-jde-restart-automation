# JDE Environment Restart Automation

> **PowerShell automation suite for orchestrating a full JD Edwards (JDE) environment restart — with sequential service control, remote log validation, and scheduled task management — across multiple servers via Windows Task Scheduler.**

---

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [File Structure](#file-structure)
- [Configuration](#configuration)
- [Usage](#usage)
- [How It Works](#how-it-works)
- [Log Validation Logic](#log-validation-logic)
- [Error Handling](#error-handling)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

Managing a JD Edwards environment restart manually is time-consuming, error-prone, and requires coordinating multiple servers in the correct sequence. This project automates the entire process using PowerShell and Windows Task Scheduler — no third-party tools, no agents, no additional software required.

The suite handles:
- Stopping all JDE services in the correct order
- Clearing stale log files remotely
- Starting services in the correct dependency order
- Validating each server's log output before proceeding
- Full transcript logging for audit trails

Designed for **JDE system administrators** and **infrastructure engineers** who manage JDE environments and need a reliable, repeatable restart process.

---

## Features

- ✅ **Full Environment Restart** — Orchestrates stop/start across Logic, UBE, BIP, BSSV, and Web servers in the correct order
- ✅ **BIP-Only Smoke Test** (`-BipOnly` switch) — Quickly restart and validate only the BIP server without touching other components
- ✅ **Remote Log Validation** — Waits for each server's logs to reach expected file count and size thresholds before proceeding
- ✅ **Task Scheduler Integration** — Creates and runs remote scheduled tasks automatically via `schtasks.exe` (no PowerShell remoting required)
- ✅ **Auto Task Creation** — Idempotent task setup: skips creation if the task already exists
- ✅ **Transcript Logging** — Every run saves a full timestamped log to `%TEMP%`
- ✅ **Verbose Mode** — Optional `-VerboseLogs` switch for detailed diagnostic output
- ✅ **No Third-Party Dependencies** — Pure PowerShell + native Windows tools only

---

## Architecture

```
restart.ps1  (Orchestrator — runs from any management workstation)
    │
    ├── Connects to each server via schtasks.exe (no PSRemoting needed)
    │
    ├── Creates/runs Stop tasks   ──► Logic, UBE, BIP, BSSV, Web servers
    │
    ├── Clears remote logs via UNC path
    │
    ├── Creates/runs Start tasks  ──► Logic → (UBE + BIP in parallel) → BSSV + Web → Subsystem
    │
    └── Validates logs on each server
            │
            └── JDE_ValidateLogs.ps1  (placed on each target server)
                    │
                    └── Checks: file count within range & no oversized files
                        Exit 0 = Ready | Exit 1 = Not ready yet
```

**Startup sequence (order matters for JDE):**

```
Logic  →  UBE + BIP  →  BSSV + Web  →  Subsystem
```

---

## Prerequisites

| Requirement | Details |
|---|---|
| PowerShell | Version 5.1 or later |
| OS | Windows Server 2016+ (management machine and target servers) |
| Permissions | The account running the script must have admin rights on all target servers |
| Network | Management machine must reach all target servers via `schtasks.exe` (typically port 135 + dynamic RPC) |
| UNC Access | Management machine must have read/write access to log shares on target servers |

---

## File Structure

```
├── restart.ps1              # Main orchestration script (run from management machine)
└── JDE_ValidateLogs.ps1     # Log validation helper (deploy to each target server)
```

---

## Configuration

All configuration is centralised in the `$Config` block at the top of `restart.ps1`. Before running, update the following placeholders:

### Servers

```powershell
Servers = [pscustomobject]@{
    Logic = "YOUR_LOGIC_SERVER"
    UBE   = "YOUR_UBE_SERVER"
    BIP   = "YOUR_BIP_SERVER"
    Web   = "YOUR_WEB_SERVER"
    BSSV  = "YOUR_BSSV_SERVER"
}
```

### Log Root

```powershell
LogRoot = "C:\JDE\Logs\PrintQueue"   # Local path on each target server
```

### Script Paths (Stop/Start `.bat` files on each server)

```powershell
Stop = [pscustomobject]@{
    BSSV  = "C:\Scripts\Stop\stop_bssv.bat"
    Web   = "C:\Scripts\Stop\stop_web.bat"
    # ... etc
}
```

### Validation Thresholds

```powershell
Validation = [pscustomobject]@{
    MaxFileSizeKB      = 3      # Reject any log file larger than this
    LogicExpectedCount = 220    # Expected number of log files after Logic start
    LogicTolerance     = 40     # Acceptable +/- range
    UBEExpectedCount   = 120
    UBETolerance       = 40
    BIPExpectedCount   = 120
    BIPTolerance       = 40
    PollSeconds        = 10     # How often to re-check logs
    MaxWaitSeconds     = 400    # Give up after this many seconds
}
```

### Deploying the Validation Script

Copy `JDE_ValidateLogs.ps1` to each target server at the path configured in `path_to_validation_script`, for example:

```
C:\Scripts\JDE_ValidateLogs.ps1
```

---

## Usage

### Full Environment Restart

```powershell
.\restart.ps1
```

### Full Restart with Verbose Output

```powershell
.\restart.ps1 -VerboseLogs
```

### BIP-Only Smoke Test

```powershell
.\restart.ps1 -BipOnly
```

### BIP Smoke Test with Verbose Output

```powershell
.\restart.ps1 -BipOnly -VerboseLogs
```

> **Transcript** is automatically saved to `%TEMP%\restart_YYYYMMDD_HHmmss.log` for every run.

---

## How It Works

### 1. Task Verification (`Ensure-Task`)
Before running anything, the script checks whether each required scheduled task already exists on the target server. If not, it creates it automatically using `schtasks /create`. This makes the script **idempotent** — safe to run repeatedly.

### 2. Service Stop (Sequential)
Services are stopped in this order to avoid dependency conflicts:
```
BSSV → Web → Logic → UBE → BIP
```
Each stop task is monitored until completion or timeout.

### 3. Log Clearing (`Clear-RemoteLogs`)
After stopping, old log files are deleted from Logic, UBE, and BIP servers via UNC path (`\\SERVER\share`), giving the validation step a clean baseline.

### 4. Service Start (Ordered)
Services are started in JDE dependency order:
```
Logic → UBE + BIP → BSSV + Web → Subsystem
```
Each start is followed by log validation before proceeding to the next step.

### 5. Log Validation (`Wait-ForLogsOk`)
A scheduled task running `JDE_ValidateLogs.ps1` is created on the target server and polled repeatedly until:
- Log file count falls within the expected range (`Expected ± Tolerance`)
- No individual log file exceeds `MaxFileSizeKB`

This confirms the service has actually started and is producing healthy output — not just that the process launched.

---

## Log Validation Logic

`JDE_ValidateLogs.ps1` is a lightweight helper that accepts four parameters:

| Parameter | Description |
|---|---|
| `-LogPath` | Path to the log directory on the local server |
| `-MinCount` | Minimum acceptable number of log files |
| `-MaxCount` | Maximum acceptable number of log files |
| `-MaxKB` | Maximum allowed size (KB) for any single log file |

**Exit codes:**
- `0` — Logs are within expected range and all files are within size limit ✅
- `1` — Not ready yet (or error occurred) ❌

---

## Error Handling

- All critical operations are wrapped in `try/catch` blocks
- Any failure throws an exception that is caught at the top level
- On failure, a clear `FAILED:` message is printed with the error detail
- The transcript is always saved in the `finally` block, even on failure
- Timeouts are enforced for both stop and start tasks to prevent indefinite hangs

---

## Contributing

Contributions, issues, and feature requests are welcome. Please open an issue first to discuss what you would like to change.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

*Built for JDE administrators who'd rather spend time on improvements than manual restarts.*
