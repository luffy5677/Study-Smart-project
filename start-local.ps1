param(
    [switch]$Build
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $root "backend"
$frontend = Join-Path $root "frontend"
$tools = Join-Path $backend "tools"
$mavenBin = Join-Path $tools "apache-maven-3.9.9\bin\mvn.cmd"

if (-not $env:JAVA_HOME) {
    $javaExe = (Get-Command java -ErrorAction Stop).Source
    $env:JAVA_HOME = (Get-Item $javaExe).Directory.Parent.FullName
}

if ($Build) {
    if (-not (Test-Path $mavenBin)) {
        Write-Host "Downloading Apache Maven once into backend\tools (avoids Maven Wrapper + Java HTTPS issues on some PCs)..."
        New-Item -ItemType Directory -Force -Path $tools | Out-Null
        $zip = Join-Path $tools "maven.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest `
            -Uri "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.9/apache-maven-3.9.9-bin.zip" `
            -OutFile $zip `
            -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $tools -Force
        Remove-Item $zip -Force
    }
    Write-Host "Building backend JAR..."
    Push-Location $backend
    try {
        & $mavenBin "-DskipTests" "package"
        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "If Maven could not download dependencies, try another network/VPN or a JDK that trusts your environment."
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
}

$jar = Get-ChildItem -Path (Join-Path $backend "target") -Filter "studysmart-backend-*.jar" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch "sources|javadoc|original" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $jar) {
    Write-Host ""
    Write-Host "No runnable JAR in backend\target yet. Run:"
    Write-Host "  .\scripts\start-local.ps1 -Build"
    Write-Host ""
    exit 1
}

$jarCopy = Join-Path $env:TEMP "studysmart-backend.jar"
Copy-Item -Force $jar.FullName $jarCopy
Write-Host "Starting API: http://localhost:8080  (profile local = in-memory H2)"

Start-Process -FilePath "java" -ArgumentList @('-jar', $jarCopy, '--spring.profiles.active=local')


Write-Host ""
Write-Host "Starting UI (separate CMD window stays open — wait until it shows http://localhost:5173)."
$frontBat = Join-Path $frontend "start-dev.bat"
if (-not (Test-Path $frontBat)) {
    Write-Host "ERROR: Missing frontend\start-dev.bat"
    exit 1
}
Start-Process -FilePath $frontBat

Write-Host ""
Write-Host "When the frontend window reports VITE ready, refresh: http://localhost:5173"
Write-Host "API + Swagger: http://localhost:8080"
Write-Host "If Chrome/Edge refuses connection too early — wait ~10s or run frontend\start-dev.bat yourself."
