#Requires -Version 5.1
<#
.SYNOPSIS
  One-shot Study Smart bootstrap: install prerequisites, dependencies, .venv, free ports, start stack.

.EXAMPLE
  .\scripts\setup-and-run.ps1
  .\scripts\setup-and-run.ps1 -SkipSoftwareInstall
#>
param(
    [switch]$SkipSoftwareInstall,
    [switch]$SkipBuild,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent $PSScriptRoot
$Backend = Join-Path $Root "backend"
$Frontend = Join-Path $Root "frontend"
$AiService = Join-Path $Root "ai-service"
$Tools = Join-Path $Backend "tools"
$MavenBin = Join-Path $Tools "apache-maven-3.9.9\bin\mvn.cmd"
$RunDir = Join-Path $Root ".run"
$LogFile = Join-Path $RunDir "setup-and-run.log"

$DefaultApiPort = 8080
$DefaultFePort = 5173
$DefaultAiPort = 8001
$script:AiServiceReady = $false

function Write-Step([string]$Message) {
    $line = "==> $Message"
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o) $line"
}

function Write-Ok([string]$Message) {
    Write-Host "    OK: $Message" -ForegroundColor Green
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o) OK: $Message"
}

function Write-Warn([string]$Message) {
    Write-Host "    WARN: $Message" -ForegroundColor Yellow
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o) WARN: $Message"
}

function Refresh-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Test-Cli([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Native {
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        return & $Command
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-JavaVersion {
    if (-not (Test-Cli "java")) { return $null }
    $raw = Invoke-Native { java -version 2>&1 | Out-String }
    if ($raw -match 'version "(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$DisplayName,
        [scriptblock]$AlreadyInstalled
    )
    if (& $AlreadyInstalled) {
        Write-Ok "$DisplayName already available"
        return
    }
    if (-not (Test-Cli "winget")) {
        throw "Missing $DisplayName and winget is not installed. Install $DisplayName manually, then re-run this script."
    }
    Write-Host "    Installing $DisplayName via winget (may take several minutes)..."
    & winget install --id $Id -e --accept-source-agreements --accept-package-agreements --disable-interactivity
    Refresh-SessionPath
    if (-not (& $AlreadyInstalled)) {
        throw "$DisplayName install finished but command is still not on PATH. Open a new terminal or reboot, then re-run."
    }
    Write-Ok "$DisplayName installed"
}

function Ensure-Prerequisites {
    if ($SkipSoftwareInstall) {
        Write-Warn "Skipping software install (-SkipSoftwareInstall)"
    } else {
        Write-Step "Checking / installing required software (JDK 17, Node.js, Python)"
        Install-WingetPackage -Id "EclipseAdoptium.Temurin.17.JDK" -DisplayName "JDK 17" -AlreadyInstalled {
            $v = Get-JavaVersion
            $null -ne $v -and $v -ge 17
        }
        Install-WingetPackage -Id "OpenJS.NodeJS.LTS" -DisplayName "Node.js LTS" -AlreadyInstalled {
            Test-Cli "node" -and Test-Cli "npm"
        }
        Install-WingetPackage -Id "Python.Python.3.12" -DisplayName "Python 3.12" -AlreadyInstalled {
            Test-Cli "python"
        }
    }

    if (-not (Test-Cli "java")) { throw "java not found. Install JDK 17 and re-run." }
    $javaVer = Get-JavaVersion
    if ($null -eq $javaVer -or $javaVer -lt 17) {
        throw "JDK 17+ required (found version $javaVer)."
    }
    if (-not (Test-Cli "node")) { throw "node not found. Install Node.js LTS and re-run." }
    if (-not (Test-Cli "npm")) { throw "npm not found. Install Node.js LTS and re-run." }
    if (-not (Test-Cli "python")) { throw "python not found. Install Python 3 and re-run." }

    if (-not $env:JAVA_HOME) {
        $javaExe = (Get-Command java).Source
        $env:JAVA_HOME = (Get-Item $javaExe).Directory.Parent.FullName
    }
    $nodeVer = Invoke-Native { node -v }
    $pythonVer = (Invoke-Native { python --version 2>&1 } | Out-String).Trim()
    Write-Ok "java $javaVer, node $nodeVer, python $pythonVer"
}

function Ensure-Maven {
    if (Test-Path $MavenBin) {
        Write-Ok "Maven already in backend\tools"
        return
    }
    Write-Step "Downloading Apache Maven into backend\tools"
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    $zip = Join-Path $Tools "maven.zip"
    Invoke-WebRequest `
        -Uri "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.9/apache-maven-3.9.9-bin.zip" `
        -OutFile $zip `
        -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $Tools -Force
    Remove-Item $zip -Force
    if (-not (Test-Path $MavenBin)) { throw "Maven download failed." }
    Write-Ok "Maven ready"
}

function Build-Backend {
    if ($SkipBuild) {
        Write-Warn "Skipping backend build (-SkipBuild)"
        return
    }
    Ensure-Maven
    Write-Step "Building backend (Maven package, tests skipped)"
    Push-Location $Backend
    try {
        & $MavenBin "-DskipTests" "package"
        if ($LASTEXITCODE -ne 0) {
            throw "Maven build failed. Check network/proxy and backend\target logs."
        }
    } finally {
        Pop-Location
    }
    Write-Ok "Backend JAR built"
}

function Get-BackendJar {
    $jar = Get-ChildItem -Path (Join-Path $Backend "target") -Filter "studysmart-backend-*.jar" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "sources|javadoc|original" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $jar) {
        throw "No runnable JAR in backend\target. Run without -SkipBuild first."
    }
    return $jar
}

function Install-FrontendDeps {
    Write-Step "Installing frontend npm dependencies"
    Push-Location $Frontend
    try {
        if (-not (Test-Path (Join-Path $Frontend ".npmrc"))) {
            "strict-ssl=false" | Set-Content -Path (Join-Path $Frontend ".npmrc") -Encoding ascii
            Write-Warn "Created frontend\.npmrc (strict-ssl=false) for TLS-inspecting networks"
        }
        & npm.cmd install --no-fund --no-audit
        if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
    } finally {
        Pop-Location
    }
    Write-Ok "Frontend dependencies installed"
}

function Get-VenvPythonLauncher {
    if (Test-Cli "py") {
        foreach ($ver in @("-3.12", "-3.11", "-3.10")) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            & py $ver -c "import sys" 2>$null | Out-Null
            $ok = ($LASTEXITCODE -eq 0)
            $ErrorActionPreference = $prev
            if ($ok) {
                return @{ Exe = "py"; Args = @($ver) }
            }
        }
    }
    return @{ Exe = "python"; Args = @() }
}

function Install-AiVenv {
    Write-Step "Creating ai-service .venv and installing Python dependencies"
    Push-Location $AiService
    try {
        $launcher = Get-VenvPythonLauncher
        $venvPython = Join-Path $AiService ".venv\Scripts\python.exe"
        if (Test-Path $venvPython) {
            $venvVer = (& $venvPython -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')").Trim()
            if ([version]$venvVer -ge [version]"3.13" -and $launcher.Exe -eq "py") {
                Write-Warn "Removing .venv (Python $venvVer) to recreate with $($launcher.Args -join ' ')"
                Remove-Item -Recurse -Force (Join-Path $AiService ".venv")
                $venvPython = Join-Path $AiService ".venv\Scripts\python.exe"
            }
        }
        if (-not (Test-Path $venvPython)) {
            $createArgs = @($launcher.Args + @("-m", "venv", ".venv"))
            Invoke-Native { & $launcher.Exe @createArgs }
            if ($LASTEXITCODE -ne 0) {
                throw "Could not create .venv with $($launcher.Exe) $($launcher.Args -join ' ')"
            }
        }
        & $venvPython -m pip install -r requirements.txt `
            --trusted-host pypi.org `
            --trusted-host files.pythonhosted.org `
            --trusted-host pypi.python.org
        if ($LASTEXITCODE -ne 0) {
            throw "pip install failed (try Python 3.12 via: py -3.12 -m venv .venv)"
        }
        $script:AiServiceReady = $true
    } catch {
        Write-Warn "AI service setup skipped: $($_.Exception.Message)"
        Write-Warn "Core app (API + React) will still run. AI is optional."
        $script:AiServiceReady = $false
    } finally {
        Pop-Location
    }
    if ($script:AiServiceReady) {
        Write-Ok "ai-service .venv ready"
    }
}

function Test-PortListening([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Stop-ProcessOnPort([int]$Port) {
    $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    foreach ($conn in $conns) {
        $procId = $conn.OwningProcess
        if (-not $procId -or $procId -eq 0) { continue }
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        $name = if ($proc) { $proc.ProcessName } else { "pid:$procId" }
        Write-Host "    Stopping $name (PID $procId) on port $Port"
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
}

function Resolve-Port {
    param(
        [int]$Preferred,
        [string]$Label
    )
    if (-not (Test-PortListening $Preferred)) {
        Write-Ok "$Label port $Preferred is free"
        return $Preferred
    }
    Write-Warn "$Label port $Preferred is in use - stopping listener(s)"
    Stop-ProcessOnPort $Preferred
    if (-not (Test-PortListening $Preferred)) {
        Write-Ok "$Label port $Preferred freed"
        return $Preferred
    }
    for ($p = $Preferred + 1; $p -lt ($Preferred + 100); $p++) {
        if (-not (Test-PortListening $p)) {
            Write-Warn "$Label using alternate port $p"
            return $p
        }
    }
    throw "No free port found near $Preferred for $Label"
}

function Wait-HttpOk {
    param(
        [string]$Url,
        [int]$TimeoutSec = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) { return $true }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Start-StudySmartStack {
    param(
        [int]$ApiPort,
        [int]$FePort,
        [int]$AiPort
    )

    $jar = Get-BackendJar
    $jarCopy = Join-Path $env:TEMP "studysmart-backend.jar"
    Copy-Item -Force $jar.FullName $jarCopy

    Write-Step "Starting backend on http://127.0.0.1:$ApiPort"
    $backendArgs = @(
        "-jar", $jarCopy,
        "--spring.profiles.active=local",
        "--server.port=$ApiPort"
    )
    $backendProc = Start-Process -FilePath "java" -ArgumentList $backendArgs -PassThru -WindowStyle Hidden
    Write-Ok "Backend PID $($backendProc.Id)"

    $apiHealth = "http://127.0.0.1:$ApiPort/actuator/health"
    if (-not (Wait-HttpOk -Url $apiHealth -TimeoutSec 90)) {
        throw "Backend did not become healthy at $apiHealth"
    }
    Write-Ok "Backend health UP"

    Write-Step "Starting frontend on http://127.0.0.1:$FePort"
    $apiTarget = "http://127.0.0.1:$ApiPort"
    $feScriptPath = Join-Path $RunDir "start-frontend.cmd"
    $feScript = @(
        "@echo off"
        "title Study Smart - Frontend"
        "cd /d `"$Frontend`""
        "set VITE_API_PROXY_TARGET=$apiTarget"
        "set VITE_DEV_PORT=$FePort"
        "echo Study Smart frontend - keep this window open"
        "echo API proxy: %VITE_API_PROXY_TARGET%"
        "echo URL: http://127.0.0.1:$FePort"
        "call npm.cmd run dev"
        "pause"
    ) -join "`r`n"
    $feScript | Set-Content -Path $feScriptPath -Encoding ASCII
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/k", "`"$feScriptPath`"")
    Write-Ok "Frontend CMD window launched"
    Start-Sleep -Seconds 4

    $feUrl = "http://127.0.0.1:$FePort/"
    if (-not (Wait-HttpOk -Url $feUrl -TimeoutSec 120)) {
        throw "Frontend did not respond at $feUrl (check the frontend CMD window)."
    }
    Write-Ok "Frontend responding"

    Write-Step "Starting AI service on http://127.0.0.1:$AiPort (optional microservice)"
    if ($script:AiServiceReady) {
        $aiPython = Join-Path $AiService ".venv\Scripts\python.exe"
        $aiScriptPath = Join-Path $RunDir "start-ai.cmd"
        $aiScript = @(
            "@echo off"
            "title Study Smart - AI Service"
            "cd /d `"$AiService`""
            "echo Study Smart AI service - keep this window open"
            "`"$aiPython`" -m uvicorn app.main:app --host 127.0.0.1 --port $AiPort"
            "pause"
        ) -join "`r`n"
        $aiScript | Set-Content -Path $aiScriptPath -Encoding ASCII
        Start-Process -FilePath "cmd.exe" -ArgumentList @("/k", "`"$aiScriptPath`"")
        Write-Ok "AI service CMD window launched"
    } else {
        Write-Warn "AI service not started (venv setup failed or skipped)"
    }

    @{
        apiPort = $ApiPort
        fePort = $FePort
        aiPort = $AiPort
        backendPid = $backendProc.Id
        aiReady = $script:AiServiceReady
        startedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json | Set-Content -Path (Join-Path $RunDir "runtime.json") -Encoding UTF8

    return @{
        ApiPort = $ApiPort
        FePort = $FePort
        AiPort = $AiPort
        FeUrl = $feUrl
        ApiUrl = "http://127.0.0.1:$ApiPort"
        SwaggerUrl = "http://127.0.0.1:$ApiPort/swagger-ui.html"
    }
}

# --- main ---
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
"Setup started $(Get-Date -Format o)" | Set-Content -Path $LogFile -Encoding UTF8

Write-Host ""
Write-Host "Study Smart - setup and run" -ForegroundColor White
Write-Host "Project: $Root"

try {
    Ensure-Prerequisites
    Build-Backend
    Install-FrontendDeps
    Install-AiVenv

    Write-Step "Resolving ports (stop stale processes or pick alternates)"
    $apiPort = Resolve-Port -Preferred $DefaultApiPort -Label "API"
    $fePort = Resolve-Port -Preferred $DefaultFePort -Label "Frontend"
    $aiPort = Resolve-Port -Preferred $DefaultAiPort -Label "AI"

    $urls = Start-StudySmartStack -ApiPort $apiPort -FePort $fePort -AiPort $aiPort

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Study Smart is running" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Web app:    $($urls.FeUrl)"
    Write-Host " API:        $($urls.ApiUrl)"
    Write-Host " Swagger:    $($urls.SwaggerUrl)"
    Write-Host " AI service: $(if ($script:AiServiceReady) { "http://127.0.0.1:$($urls.AiPort)" } else { "not started (optional)" })"
    Write-Host ""
    Write-Host " Leave the frontend and AI CMD windows open."
    Write-Host " Log: $LogFile"
    Write-Host (" Runtime: " + (Join-Path $RunDir "runtime.json"))
    Write-Host ""

    if (-not $NoBrowser) {
        Start-Process $urls.FeUrl
    }
} catch {
    Write-Host ""
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o) FAILED: $($_.Exception.Message)"
    exit 1
}
