# run-c-frontend.ps1 - Build and run C frontend server on Windows
param(
    [int]$Port = 5001,
    [string]$BackendUrl = "http://127.0.0.1:5000",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$FrontendDir = Join-Path $ProjectDir "frontend"
$BackendLuaDir = Join-Path $ProjectDir "backend-lua"
$RuntimeDir = Join-Path $ProjectDir ".runtime\c-frontend"

# Find MinGW gcc
function Find-Gcc {
    $candidates = @(
        "C:\tools\msys64\mingw64\bin\gcc.exe",
        "C:\msys64\mingw64\bin\gcc.exe",
        "C:\tools\msys64\ucrt64\bin\gcc.exe",
        "C:\msys64\ucrt64\bin\gcc.exe",
        "C:\Program Files\mingw-w64\*\bin\gcc.exe"
    )
    
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    # Try PATH
    $gcc = Get-Command gcc -ErrorAction SilentlyContinue
    if ($gcc) {
        return $gcc.Source
    }
    
    throw "gcc not found. Install MSYS2 or MinGW."
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

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

$Gcc = Find-Gcc
$Exe = Join-Path $BackendLuaDir "yvy-server.exe"

if (-not $SkipBuild -or -not (Test-Path $Exe)) {
    Write-Host "Building C frontend server..."
    Set-Location $BackendLuaDir
    & $Gcc -Wall -O2 -o $Exe $BackendLuaDir\yvy-server.c -lws2_32
    if ($LASTEXITCODE -ne 0) {
        throw "Compilation failed."
    }
    Write-Host "Build complete: $Exe"
}

Import-DotEnv -Path (Join-Path $ProjectDir ".env")

$BackendHost = $BackendUrl -replace 'https?://', '' -replace ':.*', ''
$ApiKey = $env:API_KEY

Write-Host "=== Yvy C Frontend Server ==="
Write-Host "Port: $Port"
Write-Host "Backend: $BackendHost:5000"
Write-Host "Static: $BackendLuaDir\..\frontend\build"

Set-Location $BackendLuaDir
& $Exe --port $Port --backend $BackendHost --static "../frontend/build" --api-key $ApiKey
exit $LASTEXITCODE
