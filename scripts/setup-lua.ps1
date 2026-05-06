# setup-lua.ps1 - Install Lua dependencies for Yvy backend (Windows)
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

function Find-MsysRoot {
    foreach ($candidate in @("C:\tools\msys64", "C:\msys64")) {
        if (Test-Path (Join-Path $candidate "usr\bin\bash.exe")) {
            return $candidate
        }
    }
    throw "MSYS2 not found. Install it first: choco install msys2 -y"
}

function Find-SevenZipDir {
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) {
        return Split-Path -Parent $cmd.Source
    }

    foreach ($candidate in @("C:\Program Files\7-Zip", "C:\Program Files (x86)\7-Zip")) {
        if (Test-Path (Join-Path $candidate "7z.exe")) {
            return $candidate
        }
    }

    throw "7z.exe not found. Install 7-Zip first."
}

$MsysRoot = Find-MsysRoot
$MingwRoot = Join-Path $MsysRoot "mingw64"
$MingwBin = Join-Path $MingwRoot "bin"
$MsysBin = Join-Path $MsysRoot "usr\bin"
$Lua51 = Join-Path $MingwBin "lua5.1.exe"
$LuaDriver = Join-Path $MingwBin "lua.exe"
$LuaRocksScript = Join-Path $MingwBin "luarocks"
$Bash = Join-Path $MsysBin "bash.exe"
$Gcc = Join-Path $MingwBin "gcc.exe"
$Curl = Join-Path $MsysBin "curl.exe"
$Unzip = Join-Path $MsysBin "unzip.exe"
$SevenZipDir = Find-SevenZipDir

$LuaDirUnix = $MingwRoot -replace "\\", "/"
$LuaBinUnix = (Join-Path $MingwRoot "bin") -replace "\\", "/"
$LuaIncludeUnix = (Join-Path $MingwRoot "include\lua5.1") -replace "\\", "/"
$LuaLibUnix = (Join-Path $MingwRoot "lib") -replace "\\", "/"
$WindowsBasePath = "C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0"
$ToolPath = "$SevenZipDir;$MingwBin;$MsysBin;$WindowsBasePath"
$LuaRocksTree = Join-Path $env:USERPROFILE ".luarocks"

function Use-LuaBuildEnv {
    $env:HOME = $env:USERPROFILE
    $env:MSYSTEM = "MINGW64"
    $env:PATH = $ToolPath
    $env:LIBRARY_PATH = ""
    $env:LDFLAGS = ""
    $env:CPPFLAGS = ""
    $env:CPATH = ""
}

function Invoke-MsysPacman {
    param([string[]]$Packages)

    $quoted = $Packages | ForEach-Object { "'$_'" }
    & $Bash -lc ("pacman -S --needed --noconfirm " + ($quoted -join " "))
    if ($LASTEXITCODE -ne 0) {
        throw "pacman failed installing MSYS2 packages."
    }
}

function Write-LuaRocksConfig {
    $configDir = Join-Path $env:USERPROFILE ".luarocks"
    $configPath = Join-Path $configDir "config-5.1.lua"

    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    @"
variables = variables or {}
variables.LUA_DIR = "$LuaDirUnix"
variables.LUA_BINDIR = "$LuaBinUnix"
variables.LUA_INCDIR = "$LuaIncludeUnix"
variables.LUA_LIBDIR = "$LuaLibUnix"
variables.LUALIB = "liblua5.1.dll.a"
"@ | Set-Content -Path $configPath -Encoding ASCII
}

function Stop-RunningLuaProcesses {
    $running = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -like "lua*" -and $_.Path -eq $Lua51
    }

    if (-not $running) {
        return
    }

    Write-Host "Stopping running Lua processes that lock installed DLLs..."
    foreach ($proc in $running) {
        Write-Host "  Stopping PID $($proc.Id): $($proc.Path)"
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
    }

    Start-Sleep -Milliseconds 500
}

function Invoke-LuaRocks51 {
    param([string[]]$Arguments)

    Use-LuaBuildEnv
    & $LuaDriver $LuaRocksScript "--lua-version=5.1" @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "LuaRocks failed: $($Arguments -join ' ')"
    }
}

function Install-ManualLuaSocket {
    Write-Host "Installing: luasocket (manual build)"

    Use-LuaBuildEnv
    Stop-RunningLuaProcesses

    $tempRoot = Join-Path $env:TEMP "yvy-luasocket-build"
    $rockPath = Join-Path $tempRoot "luasocket-3.1.0-1.src.rock"
    $extractRoot = Join-Path $tempRoot "extract"
    $sourceDir = Join-Path $extractRoot "luasocket"
    $shareDir = Join-Path $LuaRocksTree "share\lua\5.1"
    $libDir = Join-Path $LuaRocksTree "lib\lua\5.1"

    Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $shareDir "socket") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $libDir "socket") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $libDir "mime") | Out-Null

    & $Curl "-L" "https://raw.githubusercontent.com/rocks-moonscript-org/moonrocks-mirror/master/luasocket-3.1.0-1.src.rock" "-o" $rockPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed downloading LuaSocket rock."
    }

    & $Unzip "-q" $rockPath "-d" $extractRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed extracting LuaSocket rock."
    }

    Copy-Item (Join-Path $sourceDir "src\ltn12.lua") (Join-Path $shareDir "ltn12.lua") -Force
    Copy-Item (Join-Path $sourceDir "src\mime.lua") (Join-Path $shareDir "mime.lua") -Force
    Copy-Item (Join-Path $sourceDir "src\socket.lua") (Join-Path $shareDir "socket.lua") -Force
    Copy-Item (Join-Path $sourceDir "src\ftp.lua") (Join-Path $shareDir "socket\ftp.lua") -Force
    Copy-Item (Join-Path $sourceDir "src\headers.lua") (Join-Path $shareDir "socket\headers.lua") -Force
    Copy-Item (Join-Path $sourceDir "src\http.lua") (Join-Path $shareDir "socket\http.lua") -Force
    Copy-Item (Join-Path $sourceDir "src\smtp.lua") (Join-Path $shareDir "socket\smtp.lua") -Force
    Copy-Item (Join-Path $sourceDir "src\tp.lua") (Join-Path $shareDir "socket\tp.lua") -Force
    Copy-Item (Join-Path $sourceDir "src\url.lua") (Join-Path $shareDir "socket\url.lua") -Force

    Push-Location $sourceDir
    try {
        $socketObjects = @(
            "luasocket", "timeout", "buffer", "io", "auxiliar", "options",
            "inet", "except", "select", "tcp", "udp", "compat", "wsocket"
        )

        foreach ($name in $socketObjects) {
            & $Gcc "-O2" "-fPIC" "-c" "-o" "src/$name.o" "-I$LuaIncludeUnix" "src/$name.c" "-DLUASOCKET_DEBUG" "-DWINVER=0x0501"
            if ($LASTEXITCODE -ne 0) {
                throw "Failed compiling LuaSocket object: $name"
            }
        }

        $socketOut = Join-Path $tempRoot "socket.core.dll"
        $mimeOut = Join-Path $tempRoot "mime.core.dll"
        $socketTarget = Join-Path $libDir "socket\core.dll"
        $mimeTarget = Join-Path $libDir "mime\core.dll"

        & $Gcc "-shared" "-o" $socketOut `
            "src/luasocket.o" "src/timeout.o" "src/buffer.o" "src/io.o" `
            "src/auxiliar.o" "src/options.o" "src/inet.o" "src/except.o" `
            "src/select.o" "src/tcp.o" "src/udp.o" "src/compat.o" "src/wsocket.o" `
            "-lws2_32" (Join-Path $MingwRoot "lib\liblua5.1.dll.a") "-lm"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed linking socket/core.dll"
        }

        Remove-Item $socketTarget -Force -ErrorAction SilentlyContinue
        Move-Item -Force $socketOut $socketTarget

        & $Gcc "-O2" "-fPIC" "-c" "-o" "src/mime.o" "-I$LuaIncludeUnix" "src/mime.c" "-DLUASOCKET_DEBUG" "-DWINVER=0x0501"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed compiling mime.o"
        }

        & $Gcc "-shared" "-o" $mimeOut `
            "src/mime.o" "src/compat.o" `
            (Join-Path $MingwRoot "lib\liblua5.1.dll.a") "-lm"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed linking mime/core.dll"
        }

        Remove-Item $mimeTarget -Force -ErrorAction SilentlyContinue
        Move-Item -Force $mimeOut $mimeTarget
    }
    finally {
        Pop-Location
    }
}

function Test-LuaRuntime {
    Use-LuaBuildEnv

    $env:LUA_PATH = "$LuaRocksTree\share\lua\5.1\?.lua;$LuaRocksTree\share\lua\5.1\?\init.lua;$MingwRoot\share\lua\5.1\?.lua;$MingwRoot\share\lua\5.1\?\init.lua"
    $env:LUA_CPATH = "$LuaRocksTree\lib\lua\5.1\?.dll;$MingwRoot\lib\lua\5.1\?.dll"

    & $Lua51 "-e" "require('cjson'); require('lsqlite3'); require('copas'); require('socket'); require('socket.http'); require('lxp'); require('dkjson'); require('lua-csv.csv'); print('ok')"
    if ($LASTEXITCODE -ne 0) {
        throw "Lua smoke test failed."
    }
}

Write-Host "=== Yvy Lua Backend Setup (Windows) ==="
Write-Host "MSYS2 root: $MsysRoot"
Write-Host "Lua runtime: $Lua51"

if (-not (Test-Path $Lua51)) {
    throw "Lua 5.1 runtime not found at $Lua51"
}

if (-not (Test-Path $LuaRocksScript)) {
    throw "LuaRocks script not found at $LuaRocksScript"
}

if (-not (Test-Path $Gcc)) {
    throw "gcc not found at $Gcc"
}

Write-Host "Installing MSYS2 packages..."
Invoke-MsysPacman @(
    "mingw-w64-x86_64-gcc",
    "mingw-w64-x86_64-make",
    "mingw-w64-x86_64-lua51",
    "mingw-w64-x86_64-lua51-cjson",
    "mingw-w64-x86_64-lua51-lsqlite3",
    "mingw-w64-x86_64-lua-luarocks",
    "mingw-w64-x86_64-sqlite3",
    "mingw-w64-x86_64-expat"
)

Write-Host "Writing LuaRocks config..."
Write-LuaRocksConfig

Write-Host "Installing runtime/test rocks..."
Invoke-LuaRocks51 @("install", "--local", "luaexpat", "EXPAT_DIR=$LuaDirUnix")
Invoke-LuaRocks51 @("install", "--local", "coxpcall")
Invoke-LuaRocks51 @("install", "--local", "binaryheap")
Invoke-LuaRocks51 @("install", "--local", "timerwheel")
Invoke-LuaRocks51 @("install", "--local", "lua-csv")
Invoke-LuaRocks51 @("install", "--local", "dkjson")
Invoke-LuaRocks51 @("install", "--local", "busted")

Install-ManualLuaSocket
Invoke-LuaRocks51 @("install", "--local", "--deps-mode=none", "copas")

Write-Host "Running Lua smoke test..."
Test-LuaRuntime

Write-Host ""
Write-Host "Setup complete."
Write-Host "Run: powershell -File scripts/run-lua.ps1"
