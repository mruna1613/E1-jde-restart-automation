# JDE_ValidateLogs.ps1
# Place on EACH target server
# Exit 0 = logs OK, Exit 1 = not ready yet

param(
    [string] $LogPath,
    [int]    $MinCount,
    [int]    $MaxCount,
    [int]    $MaxKB
)

try {
    if (-not (Test-Path -LiteralPath $LogPath)) { exit 1 }
    $files     = @(Get-ChildItem -LiteralPath $LogPath -File -Recurse -ErrorAction SilentlyContinue)
    $oversized = @($files | Where-Object { $_.Length -gt ($MaxKB * 1024) })
    if ($files.Count -ge $MinCount -and $files.Count -le $MaxCount -and $oversized.Count -eq 0) {
        exit 0
    } else {
        exit 1
    }
} catch {
    exit 1
}
