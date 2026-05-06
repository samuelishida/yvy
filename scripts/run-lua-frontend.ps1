# run-lua-frontend.ps1 - Run Yvy frontend against Lua backend on Windows
# Uses Lua baremetal server instead of Node.js/Express

param(
    [int]$Port = 5001,
    [string]$BackendUrl = "http://127.0.0.1:5000",
    [switch]$NoEnv
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$BackendLuaDir = Join-Path $ProjectDir "backend-lua"

function Find-MsysRoot {
    foreach ($candidate in @("C:\tools\msys64", "C:\msys64")) {
        if (Test-Path (Join-Path $candidate "mingw64\bin\lua5.1.exe")) {
            return $candidate
        }
    }

    throw "MSYS2 Lua 5.1 runtime not found. Run scripts/setup-lua.ps1 first."
}

function Import-DotEnv {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#' -or $line -notmatch '=') {
            continue
        }

        $parts = $line -split '=', 2
        $name = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"').Trim("'")

        if ($name) {
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}

$MsysRoot = Find-MsysRoot
$MingwRoot = Join-Path $MsysRoot "mingw64"
$MingwBin = Join-Path $MingwRoot "bin"
$Lua51 = Join-Path $MingwBin "lua5.1.exe"
$LuaRocksTree = Join-Path $env:USERPROFILE ".luarocks"
$WindowsBasePath = "C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0"

$env:HOME = $env:USERPROFILE
$env:MSYSTEM = "MINGW64"
$env:PATH = "$MingwBin;$MsysRoot\usr\bin;$LuaRocksTree\bin;$WindowsBasePath"
$env:LUA_PATH = "$LuaRocksTree\share\lua\5.1\?.lua;$LuaRocksTree\share\lua\5.1\?\init.lua;$MingwRoot\share\lua\5.1\?.lua;$MingwRoot\share\lua\5.1\?\init.lua"
$env:LUA_CPATH = "$LuaRocksTree\lib\lua\5.1\?.dll;$MingwRoot\lib\lua\5.1\?.dll"

if (-not $NoEnv) {
    Import-DotEnv -Path (Join-Path $ProjectDir ".env")
}

$env:PORT = [string]$Port
$env:BACKEND_URL = $BackendUrl
$env:API_KEY = $env:API_KEY
$env:STATIC_DIR = Join-Path $ProjectDir "frontend\build"

Set-Location $BackendLuaDir
Write-Host "=== Yvy Lua Frontend ==="
Write-Host "Lua: $Lua51"
Write-Host "Port: $($env:PORT)"
Write-Host "Backend URL: $($env:BACKEND_URL)"
Write-Host "Static files: $($env:STATIC_DIR)"

& $Lua51 "main_frontend.lua"
exit $LASTEXITCODE
