[CmdletBinding()]
param(
    [switch] $VerboseLogs,
    [switch] $BipOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$SchTasks = "C:\Windows\System32\schtasks.exe"
if ($VerboseLogs) { $VerbosePreference = 'Continue' }

$Config = [pscustomobject]@{
    Servers = [pscustomobject]@{
        Logic = "SERVER_NAME"
        UBE   = "SERVER_NAME"
        BIP   = "SERVER_NAME"
        Web   = "SERVER_NAME"
        BSSV  = "SERVER_NAME"
    }
    LogRoot = "path_to_the_logs"
    Scripts = [pscustomobject]@{
        Stop = [pscustomobject]@{
            BSSV  = "path_to_bat_scripts_to_stop"
            Web   = "path_to_bat_scripts_to_stop"
            Logic = "path_to_bat_scripts_to_stop"
            UBE   = "path_to_bat_scripts_to_stop"
            BIP   = "path_to_bat_scripts_to_stop"
        }
        Start = [pscustomobject]@{
            Logic     = "path_to_bat_scripts_to_start"
            UBE       = "path_to_bat_scripts_to_start"
            BIP       = "path_to_bat_scripts_to_start"
            BSSV      = "path_to_bat_scripts_to_start"
            Web       = "path_to_bat_scripts_to_start"
            Subsystem = "path_to_bat_scripts_to_start"
        }
    }
    Tasks = [pscustomobject]@{
        Stop = [pscustomobject]@{
            BSSV  = 'JDE_Stop_BSSV'
            Web   = 'JDE_Stop_Web'
            Logic = 'JDE_Stop_Logic'
            UBE   = 'JDE_Stop_UBE'
            BIP   = 'JDE_Stop_BIP'
        }
        Start = [pscustomobject]@{
            Logic     = 'task_name_to_Start_service_on_each_server'
            UBE       = 'task_name_to_Start_service_on_each_server'
            BIP       = 'task_name_to_Start_service_on_each_server'
            BSSV      = 'task_name_to_Start_service_on_each_server'
            Web       = 'task_name_to_Start_service_on_each_server'
            Subsystem = 'task_name_to_Start_service_on_each_server'
        }
    }
    Validation = [pscustomobject]@{
        MaxFileSizeKB      = 3
        LogicExpectedCount = 220
        LogicTolerance     = 40
        UBEExpectedCount   = 120
        UBETolerance       = 40
        BIPExpectedCount   = 120
        BIPTolerance       = 40
        PollSeconds        = 10
        MaxWaitSeconds     = 400
    }
    Timeouts = [pscustomobject]@{
        Stop  = 180
        Start = 300
    }
    TranscriptPath = Join-Path $env:TEMP ("restart_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
}

function Write-Stage {
    param([string] $Title)
    Write-Host "`n==== $Title ====" -ForegroundColor Cyan
}

function Convert-ToUnc {
    param([string] $ComputerName, [string] $LocalPath)
    "\\$ComputerName\$($LocalPath.Substring(0,1))`$$($LocalPath.Substring(3))"
}

function Test-TaskSchedulerReachable {
    param([string] $ComputerName)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $SchTasks /query /s $ComputerName >$null 2>&1
    $result = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    return $result
}

function Test-TaskExists {
    param([string] $ComputerName, [string] $TaskName)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $SchTasks /query /s $ComputerName /tn $TaskName >$null 2>&1
    $result = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    return $result
}

function Ensure-Task {
    param(
        [string] $ComputerName,
        [string] $TaskName,
        [string] $BatPath
    )
    if (Test-TaskExists $ComputerName $TaskName) {
        Write-Verbose "[$ComputerName] Task '$TaskName' already exists - skipping"
        return
    }
    Write-Host "[$ComputerName] Creating task '$TaskName' ..."
    $startTime = (Get-Date).AddMinutes(1).ToString('HH:mm')
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $SchTasks /create `
        /s  $ComputerName `
        /tn $TaskName `
        /tr "`"C:\Windows\System32\cmd.exe`" /c `"$BatPath`"" `
        /sc ONCE `
        /st $startTime `
        /ru SYSTEM `
        /rl HIGHEST `
        /f >$null 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($exit -ne 0) {
        throw "Failed to create task '$TaskName' on $ComputerName (exit $exit)"
    }
    Write-Host "[$ComputerName] Task '$TaskName' created." -ForegroundColor Green
}

function Get-TaskStatus {
    param([string] $ComputerName, [string] $TaskName)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $SchTasks /query /s $ComputerName /tn $TaskName /fo LIST /v 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($exit -ne 0 -or -not $out) {
        throw "Unable to query task '$TaskName' on $ComputerName"
    }
    $statusLine = $out | Where-Object { $_ -match '^\s*Status\s*:'              } | Select-Object -First 1
    $resultLine = $out | Where-Object { $_ -match '^\s*Last\s+Run\s+Result\s*:' } | Select-Object -First 1
    $status = if ($statusLine) { ($statusLine -split ':', 2)[1].Trim() } else { '' }
    $last   = if ($resultLine) { ($resultLine -split ':', 2)[1].Trim() } else { '' }
    if ($last -match '^\s*0\s*$')   { $last = '0'   }
    if ($last -match '^\s*0x0\s*$') { $last = '0x0' }
    [pscustomobject]@{ State = $status; LastResult = $last }
}

function Invoke-Task {
    param([string] $ComputerName, [string] $TaskName, [int] $TimeoutSec)
    Write-Host "[$ComputerName] Running task '$TaskName' ..."
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $SchTasks /run /s $ComputerName /tn $TaskName >$null 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($exit -ne 0) { throw "Failed to start task '$TaskName' on $ComputerName" }
    Start-Sleep -Seconds 3
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 10
        $status = Get-TaskStatus $ComputerName $TaskName
    } while ($status.State -like '*Running*' -and (Get-Date) -lt $deadline)
    if ($status.State -like '*Running*') {
        throw "$TaskName on $ComputerName timed out after $TimeoutSec seconds"
    }
    if ([string]::IsNullOrWhiteSpace($status.LastResult)) {
        Write-Verbose "[$ComputerName] Task '$TaskName' completed with no reported result (treated as success)."
    }
    elseif ($status.LastResult -ne '0' -and $status.LastResult -ne '0x0') {
        throw "$TaskName on $ComputerName failed (Result $($status.LastResult))"
    }
    Write-Host "[$ComputerName] Task '$TaskName' completed successfully." -ForegroundColor Green
}

function Clear-RemoteLogs {
    param([string] $ComputerName, [string] $LogPath)
    $unc = Convert-ToUnc $ComputerName $LogPath
    Write-Host "[$ComputerName] Clearing logs at $unc ..."
    if (Test-Path $unc) {
        Get-ChildItem $unc -File -Recurse -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "[$ComputerName] Logs cleared." -ForegroundColor Green
    } else {
        Write-Warning "[$ComputerName] Log path not found - skipping: $unc"
    }
}

function Ensure-LogCheckTask {
    param(
        [string] $ComputerName,
        [string] $TaskName,
        [string] $LogPath,
        [int]    $MinCount,
        [int]    $MaxCount,
        [int]    $MaxKB
    )
    $startTime  = (Get-Date).AddMinutes(1).ToString('HH:mm')
    $psExe      = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = 'path_to_validation_script'
    $tr = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -LogPath `"$LogPath`" -MinCount $MinCount -MaxCount $MaxCount -MaxKB $MaxKB"
    Write-Verbose "[$ComputerName] Ensure-LogCheckTask /tr length: $($tr.Length) chars"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $SchTasks /create `
        /s  $ComputerName `
        /tn $TaskName `
        /tr $tr `
        /sc ONCE `
        /st $startTime `
        /ru SYSTEM `
        /rl HIGHEST `
        /f >$null 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($exit -ne 0) {
        throw "[$ComputerName] Failed to create log-check task '$TaskName' (exit $exit)"
    }
}

function Invoke-LogCheckTask {
    param(
        [string] $ComputerName,
        [string] $TaskName,
        [int]    $TimeoutSec
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $SchTasks /run /s $ComputerName /tn $TaskName >$null 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($exit -ne 0) {
        throw "[$ComputerName] Failed to start log-check task '$TaskName'"
    }
    Start-Sleep -Seconds 5
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 5
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & $SchTasks /query /s $ComputerName /tn $TaskName /fo LIST /v 2>&1
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -ne 0 -or -not $out) { continue }
        $stateLine  = $out | Where-Object { $_ -match '^\s*Status\s*:'              } | Select-Object -First 1
        $resultLine = $out | Where-Object { $_ -match '^\s*Last\s+Run\s+Result\s*:' } | Select-Object -First 1
        $state = if ($stateLine)  { ($stateLine  -split ':', 2)[1].Trim() } else { '' }
        $lr    = if ($resultLine) { ($resultLine -split ':', 2)[1].Trim() } else { '' }
        if ($state -like '*Running*') { continue }
        if ([string]::IsNullOrWhiteSpace($lr)) { continue }
        if ($lr -eq '0' -or $lr -eq '0x0') { return $true } else { return $false }
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Wait-ForLogsOk {
    param(
        [string] $ComputerName,
        [string] $Role,
        [string] $LogPath,
        [int]    $Expected,
        [int]    $Tolerance,
        [int]    $MaxKB,
        [int]    $Poll,
        [int]    $MaxWait
    )
    $min      = $Expected - $Tolerance
    $max      = $Expected + $Tolerance
    $taskName = "JDE_ValidateLogs_$Role"
    $deadline = (Get-Date).AddSeconds($MaxWait)
    Write-Host "[$ComputerName] Waiting for $Role logs (target: $min-$max files, max ${MaxKB}KB)..."
    Write-Verbose "[$ComputerName] Creating log-check task '$taskName' (target=$min-$max, MaxKB=$MaxKB)"
    Ensure-LogCheckTask `
        -ComputerName $ComputerName `
        -TaskName     $taskName `
        -LogPath      $LogPath `
        -MinCount     $min `
        -MaxCount     $max `
        -MaxKB        $MaxKB
    do {
        $ok = Invoke-LogCheckTask `
            -ComputerName $ComputerName `
            -TaskName     $taskName `
            -TimeoutSec   ([Math]::Max(30, $Poll))
        Write-Verbose "[$ComputerName] $Role log check: $(if ($ok) { 'PASS' } else { 'FAIL - not ready yet' })"
        if ($ok) {
            Write-Host "[$ComputerName] $Role log validation PASSED." -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds $Poll
    } while ((Get-Date) -lt $deadline)
    Write-Host "[$ComputerName] $Role log validation FAILED - timed out." -ForegroundColor Red
    return $false
}

Start-Transcript -Path $Config.TranscriptPath -Force | Out-Null
Write-Host "Script     : restart.ps1"
Write-Host "Started    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Mode       : $(if ($BipOnly) { 'BIP-Only Smoke Test' } else { 'Full Restart' })"
Write-Host "Running as : $(whoami)"

try {
    $S = $Config.Servers
    $V = $Config.Validation
    $T = $Config.Timeouts
    $L = $Config.LogRoot

    if ($BipOnly) {
        Write-Stage "BIP-only Smoke Test"
        Write-Host "[BIP] Ensuring tasks..." -ForegroundColor Yellow
        Ensure-Task $S.BIP $Config.Tasks.Stop.BIP        $Config.Scripts.Stop.BIP
        Ensure-Task $S.BIP $Config.Tasks.Start.BIP       $Config.Scripts.Start.BIP
        Ensure-Task $S.BIP $Config.Tasks.Start.Subsystem $Config.Scripts.Start.Subsystem
        Write-Host "[BIP] Stopping..." -ForegroundColor Yellow
        Invoke-Task $S.BIP $Config.Tasks.Stop.BIP $T.Stop
        Write-Host "[BIP] Clearing logs..." -ForegroundColor Yellow
        Clear-RemoteLogs $S.BIP $L
        Write-Host "[BIP] Starting..." -ForegroundColor Yellow
        Invoke-Task $S.BIP $Config.Tasks.Start.BIP $T.Start
        Write-Host "[BIP] Validation Starting..." -ForegroundColor Yellow
        if (-not (Wait-ForLogsOk $S.BIP 'BIP' $L $V.BIPExpectedCount $V.BIPTolerance $V.MaxFileSizeKB $V.PollSeconds $V.MaxWaitSeconds)) {
            throw "BIP validation failed"
        }
        Write-Host "[BIP] Starting Subsystem..." -ForegroundColor Yellow
        Invoke-Task $S.BIP $Config.Tasks.Start.Subsystem $T.Start
        Write-Host "`nSUCCESS: BIP-only smoke test completed successfully." -ForegroundColor Green
        Write-Host "Finished   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        return
    }

    Write-Stage "Ensuring Tasks Exist"
    Ensure-Task $S.BSSV  $Config.Tasks.Stop.BSSV      $Config.Scripts.Stop.BSSV
    Ensure-Task $S.Web   $Config.Tasks.Stop.Web        $Config.Scripts.Stop.Web
    Ensure-Task $S.Logic $Config.Tasks.Stop.Logic      $Config.Scripts.Stop.Logic
    Ensure-Task $S.UBE   $Config.Tasks.Stop.UBE        $Config.Scripts.Stop.UBE
    Ensure-Task $S.BIP   $Config.Tasks.Stop.BIP        $Config.Scripts.Stop.BIP
    Ensure-Task $S.Logic $Config.Tasks.Start.Logic     $Config.Scripts.Start.Logic
    Ensure-Task $S.UBE   $Config.Tasks.Start.UBE       $Config.Scripts.Start.UBE
    Ensure-Task $S.BIP   $Config.Tasks.Start.BIP       $Config.Scripts.Start.BIP
    Ensure-Task $S.BSSV  $Config.Tasks.Start.BSSV      $Config.Scripts.Start.BSSV
    Ensure-Task $S.Web   $Config.Tasks.Start.Web       $Config.Scripts.Start.Web
    Ensure-Task $S.BIP   $Config.Tasks.Start.Subsystem $Config.Scripts.Start.Subsystem

    Write-Stage "Stopping Services"
    Invoke-Task $S.BSSV  $Config.Tasks.Stop.BSSV  $T.Stop
    Invoke-Task $S.Web   $Config.Tasks.Stop.Web   $T.Stop
    Invoke-Task $S.Logic $Config.Tasks.Stop.Logic $T.Stop
    Invoke-Task $S.UBE   $Config.Tasks.Stop.UBE   $T.Stop
    Invoke-Task $S.BIP   $Config.Tasks.Stop.BIP   $T.Stop

    Write-Stage "Clearing Logs"
    Clear-RemoteLogs $S.Logic $L
    Clear-RemoteLogs $S.UBE   $L
    Clear-RemoteLogs $S.BIP   $L

    Write-Stage "Starting Logic"
    Invoke-Task $S.Logic $Config.Tasks.Start.Logic $T.Start
    if (-not (Wait-ForLogsOk $S.Logic 'Logic' $L $V.LogicExpectedCount $V.LogicTolerance $V.MaxFileSizeKB $V.PollSeconds $V.MaxWaitSeconds)) {
        throw "Logic validation failed"
    }

    Write-Stage "Starting UBE and BIP"
    Invoke-Task $S.UBE $Config.Tasks.Start.UBE $T.Start
    Invoke-Task $S.BIP $Config.Tasks.Start.BIP $T.Start
    if (-not (Wait-ForLogsOk $S.UBE 'UBE' $L $V.UBEExpectedCount $V.UBETolerance $V.MaxFileSizeKB $V.PollSeconds $V.MaxWaitSeconds)) {
        throw "UBE validation failed"
    }
    if (-not (Wait-ForLogsOk $S.BIP 'BIP' $L $V.BIPExpectedCount $V.BIPTolerance $V.MaxFileSizeKB $V.PollSeconds $V.MaxWaitSeconds)) {
        throw "BIP validation failed"
    }

    Write-Stage "Starting BSSV and Web"
    Invoke-Task $S.BSSV $Config.Tasks.Start.BSSV $T.Start
    Invoke-Task $S.Web  $Config.Tasks.Start.Web  $T.Start

    Write-Stage "Starting Subsystem"
    Invoke-Task $S.BIP $Config.Tasks.Start.Subsystem $T.Start

    Write-Host "`nSUCCESS: <ENV_NAME> Restart Completed Successfully" -ForegroundColor Green
    Write-Host "Finished   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}
catch {
    Write-Host "`nFAILED: $(if ($BipOnly) { 'BIP Smoke Test' } else { '<ENV_NAME> Restart' }) FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Failed at  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    throw
}
finally {
    Write-Host "Transcript saved at $($Config.TranscriptPath)"
    Stop-Transcript | Out-Null
}
