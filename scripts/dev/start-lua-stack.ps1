# start-lua-stack.ps1 - Start Lua backend and frontend in background on Windows
param(
    [switch]$DevFrontend,
    [switch]$SkipFrontendBuild
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$RuntimeDir = Join-Path $ProjectDir ".runtime\lua-stack"
$BackendScript = Join-Path $ScriptDir "run-lua-backend.ps1"
$FrontendScript = Join-Path $ScriptDir "run-c-frontend.ps1"
$StopScript = Join-Path $ScriptDir "stop-lua-stack.ps1"
$PowerShellExe = Join-Path $PSHOME "powershell.exe"

function Wait-ForPort {
    param(
        [int]$Port,
        [int]$ProcessId,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) {
            return $false
        }

        $listening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -eq $Port }
        if ($listening) {
            return $true
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Read-LogTail {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return ""
    }

    return ((Get-Content $Path -Tail 20 -ErrorAction SilentlyContinue) -join [Environment]::NewLine)
}

$FrontendDir = Join-Path $ProjectDir "frontend"

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

& $StopScript

if (-not $SkipFrontendBuild) {
    Write-Host "Building frontend..."
    $buildLog = Join-Path $RuntimeDir "build.log"
    & npm --prefix $FrontendDir run build > $buildLog
    if ($LASTEXITCODE -ne 0) {
        Write-Host (Get-Content $buildLog -Raw -ErrorAction SilentlyContinue)
        throw "Frontend build failed (exit $LASTEXITCODE). See: $buildLog"
    }
    Write-Host "Frontend build done."
} else {
    Write-Host "Skipping frontend build (-SkipFrontendBuild)."
}

$BackendOut = Join-Path $RuntimeDir "backend.out.log"
$BackendErr = Join-Path $RuntimeDir "backend.err.log"
$FrontendOut = Join-Path $RuntimeDir "frontend.out.log"
$FrontendErr = Join-Path $RuntimeDir "frontend.err.log"

foreach ($path in @($BackendOut, $BackendErr, $FrontendOut, $FrontendErr)) {
    if (Test-Path $path) {
        Remove-Item -Force $path
    }
}

Write-Host "Starting Lua backend..."
$backendProc = Start-Process -FilePath $PowerShellExe `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $BackendScript) `
    -WorkingDirectory $ProjectDir `
    -WindowStyle Hidden `
    -RedirectStandardOutput $BackendOut `
    -RedirectStandardError $BackendErr `
    -PassThru

Set-Content -Path (Join-Path $RuntimeDir "backend.pid") -Value $backendProc.Id -Encoding ASCII

if (-not (Wait-ForPort -Port 5000 -ProcessId $backendProc.Id -TimeoutSeconds 30)) {
    $backendProc.Refresh()
    throw "Lua backend did not start on port 5000.`n$(Read-LogTail -Path $BackendErr)"
}

Write-Host "Starting C frontend..."
$FrontendExe = Join-Path $ProjectDir "backend-lua\yvy-server.exe"
$frontendArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $FrontendScript)
if (Test-Path $FrontendExe) { $frontendArgs += "-SkipBuild" }

$frontendProc = Start-Process -FilePath $PowerShellExe `
    -ArgumentList $frontendArgs `
    -WorkingDirectory $ProjectDir `
    -WindowStyle Hidden `
    -RedirectStandardOutput $FrontendOut `
    -RedirectStandardError $FrontendErr `
    -PassThru

Set-Content -Path (Join-Path $RuntimeDir "frontend.pid") -Value $frontendProc.Id -Encoding ASCII

if (-not (Wait-ForPort -Port 5001 -ProcessId $frontendProc.Id -TimeoutSeconds 30)) {
    $frontendProc.Refresh()
    throw "C frontend did not start on port 5001.`n$(Read-LogTail -Path $FrontendOut)`n$(Read-LogTail -Path $FrontendErr)"
}

Write-Host "Lua stack running."
Write-Host "Backend PID: $($backendProc.Id)"
Write-Host "Frontend PID: $($frontendProc.Id)"
Write-Host "Logs: $RuntimeDir"
Write-Host ""
Write-Host "Access the app at: http://localhost:5001/"
Write-Host "Backend API at: http://localhost:5000/api/"
Write-Host ""
Write-Host "Run .\stop-lua-stack.ps1 to stop."
