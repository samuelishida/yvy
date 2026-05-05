# run-lua.ps1 — Run Yvy Lua backend (Windows PowerShell)
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

Set-Location "$ProjectDir/backend-lua"

# Load .env
if (Test-Path "$ProjectDir/.env") {
    Get-Content "$ProjectDir/.env" | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2].Trim('"').Trim("'"))
        }
    }
}

$env:SQLITE_PATH = if ($env:SQLITE_PATH) { $env:SQLITE_PATH } else { "$ProjectDir/backend/data/yvy.db" }
$env:PORT = if ($env:PORT) { $env:PORT } else { "5000" }
$env:AUTH_REQUIRED = if ($env:AUTH_REQUIRED) { $env:AUTH_REQUIRED } else { "0" }
$env:LOG_LEVEL = if ($env:LOG_LEVEL) { $env:LOG_LEVEL } else { "INFO" }

Write-Host "=== Yvy Lua Backend ==="
Write-Host "Port: $env:PORT"
Write-Host "SQLite: $env:SQLITE_PATH"

lua main.lua
