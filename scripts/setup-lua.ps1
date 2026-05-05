# setup-lua.ps1 — Install Lua dependencies for Yvy backend (Windows)
# Requires: Lua 5.1 + LuaRocks installed via Chocolatey or manually
#   choco install lua51 luarocks

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

Write-Host "=== Yvy Lua Backend Setup (Windows) ==="

# ── Check Lua ─────────────────────────────────────────────────────────────
$lua = Get-Command lua5.1 -ErrorAction SilentlyContinue
if (-not $lua) { $lua = Get-Command lua -ErrorAction SilentlyContinue }
if (-not $lua) {
    Write-Host "ERROR: Lua 5.1 not found. Install via: choco install lua51 luarocks"
    exit 1
}
Write-Host "Using Lua: $($lua.Source)"

# ── Check LuaRocks ────────────────────────────────────────────────────────
$luarocks = Get-Command luarocks -ErrorAction SilentlyContinue
if (-not $luarocks) {
    Write-Host "ERROR: LuaRocks not found. Install via: choco install luarocks"
    exit 1
}

# ── Install rocks ─────────────────────────────────────────────────────────
Write-Host "Installing Lua dependencies..."

luarocks install luasocket
luarocks install copas
luarocks install lsqlite3
luarocks install lua-cjson
luarocks install luaexpat
luarocks install lua-csv
luarocks install busted

Write-Host "=== Setup complete ==="
Write-Host "Run: cd backend-lua; lua main.lua"
