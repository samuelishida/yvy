# run-lua.ps1 - Backward-compatible wrapper for the Lua backend
param(
    [int]$Port = 5000,
    [string]$SqlitePath,
    [switch]$NoEnv
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Target = Join-Path $ScriptDir "run-lua-backend.ps1"

& $Target @PSBoundParameters
