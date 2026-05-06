# kill-rogue-yvy.ps1 - Kill stray Yvy local dev processes on Windows
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$RuntimeDir = Join-Path $ProjectDir ".runtime\lua-stack"

function Add-Candidate {
    param(
        [hashtable]$Map,
        [int]$ProcessId,
        [string]$Reason
    )

    if ($ProcessId -le 0) {
        return
    }

    if (-not $Map.ContainsKey($ProcessId)) {
        $Map[$ProcessId] = [System.Collections.Generic.List[string]]::new()
    }

    $Map[$ProcessId].Add($Reason)
}

function Stop-Candidate {
    param(
        [int]$ProcessId,
        [string[]]$Reasons,
        [switch]$DryRunMode
    )

    $reasonText = ($Reasons | Select-Object -Unique) -join ", "
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    $name = if ($proc) { $proc.Name } else { "unknown" }

    if ($DryRunMode) {
        Write-Host ("DRY RUN  PID {0}  {1}  [{2}]" -f $ProcessId, $name, $reasonText)
        return
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Write-Host ("STOPPED  PID {0}  {1}  [{2}]" -f $ProcessId, $name, $reasonText)
    }
    catch {
        Write-Host ("SKIPPED  PID {0}  {1}  [{2}]  -> {3}" -f $ProcessId, $name, $reasonText, $_.Exception.Message)
    }
}

$candidates = @{}

$processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -in @("lua5.1.exe", "lua.exe", "node.exe", "python.exe", "python3.exe", "hypercorn.exe", "bash.exe", "git-bash.exe", "powershell.exe")
}

foreach ($proc in $processes) {
    $cmd = [string]$proc.CommandLine
    $name = [string]$proc.Name
    $pidValue = [int]$proc.ProcessId

    if ($name -match '^lua(5\.1)?\.exe$' -and $cmd -like '*main.lua*') {
        Add-Candidate -Map $candidates -ProcessId $pidValue -Reason "lua main.lua"
    }

    if ($name -eq 'node.exe' -and ($cmd -like '*server.js*' -or $cmd -like '*react-scripts*')) {
        Add-Candidate -Map $candidates -ProcessId $pidValue -Reason "frontend node"
    }

    if (($name -eq 'python.exe' -or $name -eq 'python3.exe') -and $cmd -like '*backend.py*') {
        Add-Candidate -Map $candidates -ProcessId $pidValue -Reason "python backend"
    }

    if ($name -eq 'hypercorn.exe' -or ($name -eq 'python.exe' -and $cmd -like '*hypercorn*backend:app*')) {
        Add-Candidate -Map $candidates -ProcessId $pidValue -Reason "hypercorn backend"
    }

    if ($name -eq 'powershell.exe' -and (
        $cmd -like '*run-lua-backend.ps1*' -or
        $cmd -like '*run-lua-frontend.ps1*' -or
        $cmd -like '*start-lua-stack.ps1*' -or
        $cmd -like '*run-lua.ps1*'
    )) {
        Add-Candidate -Map $candidates -ProcessId $pidValue -Reason "lua powershell wrapper"
    }

    if (($name -eq 'bash.exe' -or $name -eq 'git-bash.exe') -and (
        $cmd -like '*run-frontend.sh*' -or
        $cmd -like '*run-lua.sh*' -or
        $cmd -like '*run-backend.sh*' -or
        $cmd -like '*run-local.sh*'
    )) {
        Add-Candidate -Map $candidates -ProcessId $pidValue -Reason "shell wrapper"
    }
}

$listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {
    $_.LocalPort -in 5000, 5001
}

foreach ($listener in $listeners) {
    Add-Candidate -Map $candidates -ProcessId ([int]$listener.OwningProcess) -Reason ("listening on :" + $listener.LocalPort)
}

Write-Host "=== Rogue Yvy Process Cleanup ==="
Write-Host "Project: $ProjectDir"
if ($DryRun) {
    Write-Host "Mode: dry run"
}

if ($candidates.Count -eq 0) {
    Write-Host "No rogue Yvy processes found."
}
else {
    foreach ($entry in $candidates.GetEnumerator() | Sort-Object Name) {
        Stop-Candidate -ProcessId ([int]$entry.Key) -Reasons $entry.Value.ToArray() -DryRunMode:$DryRun
    }
}

if (-not $DryRun -and (Test-Path $RuntimeDir)) {
    Get-ChildItem $RuntimeDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host "Done."
