# stop-lua-stack.ps1 - Stop local Lua backend/frontend processes on Windows
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$RuntimeDir = Join-Path $ProjectDir ".runtime\lua-stack"

function Stop-ProcessIfRunning {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Write-Host "Stopped PID $ProcessId"
    }
    catch {
        Write-Host "Skip PID $ProcessId"
    }
}

function Stop-ListenerOnPort {
    param([int]$Port)

    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -eq $Port } |
        Select-Object -ExpandProperty OwningProcess -Unique

    foreach ($pidValue in $listeners) {
        Stop-ProcessIfRunning -ProcessId $pidValue
    }
}

Write-Host "Stopping Lua stack processes..."

foreach ($name in @("backend.pid", "frontend.pid")) {
    $pidFile = Join-Path $RuntimeDir $name
    if (Test-Path $pidFile) {
        $pidValue = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pidValue -match '^\d+$') {
            Stop-ProcessIfRunning -ProcessId ([int]$pidValue)
        }
    }
}

foreach ($port in 5000, 5001) {
    Stop-ListenerOnPort -Port $port
}

$repoProcesses = Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -eq "lua5.1.exe" -and $_.CommandLine -like "*main.lua*") -or
    ($_.Name -eq "node.exe" -and ($_.CommandLine -like "*server.js*" -or $_.CommandLine -like "*react-scripts*"))
}

foreach ($process in $repoProcesses) {
    Stop-ProcessIfRunning -ProcessId $process.ProcessId
}

if (Test-Path $RuntimeDir) {
    Get-ChildItem $RuntimeDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host "Lua stack stopped."
