param(
    [string]$FlutterRoot = $env:FLUTTER_ROOT,
    [string]$PubCache = $env:PUB_CACHE,
    [switch]$Debug,
    [string]$TargetPlatform = '',
    [string]$ServerUrl = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($PubCache) { $env:PUB_CACHE = $PubCache }
$flutter = if ($FlutterRoot) { Join-Path $FlutterRoot 'bin/flutter' } else { 'flutter' }
if ($env:OS -eq 'Windows_NT') { $flutter += '.bat' }
if (-not $Debug -and -not (Test-Path -LiteralPath "$projectRoot/android/key.properties")) {
    throw 'Release builds require android/key.properties and your own signing key. See docs/BUILD.md.'
}

Push-Location $projectRoot
try {
    $versionLine = Get-Content -Encoding UTF8 pubspec.yaml | Where-Object { $_ -match '^version:' }
    if ($versionLine -notmatch '^version:\s*([^+\s]+)\+(\d+)') { throw 'Invalid pubspec version' }
    $versionName = $matches[1]
    $versionCode = $matches[2]
    $commit = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the source commit' }
    $arguments = @(
        'build', 'apk', '--no-pub',
        "--dart-define=pili.name=$versionName",
        "--dart-define=pili.code=$versionCode",
        "--dart-define=pili.hash=$commit",
        "--dart-define=pili.time=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    )
    if ($Debug) { $arguments += '--debug' } else { $arguments += @('--release', '--split-per-abi') }
    if ($TargetPlatform) { $arguments += "--target-platform=$TargetPlatform" }
    if ($ServerUrl) { $arguments += "--dart-define=WATCH_TOGETHER_URL=$ServerUrl" }
    if ($env:OS -eq 'Windows_NT') {
        # Kotlin incremental caches cannot relativize a C: Pub cache against a D: project.
        # Restrict this workaround to this invocation; Linux/CI keeps incremental builds.
        $arguments += @('--android-project-arg=kotlin.incremental=false', '--android-project-arg=kotlin.compiler.execution.strategy=in-process')
    }
    $ErrorActionPreference = 'Continue'
    & $flutter @arguments
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($buildExit -ne 0) { throw "Android build failed ($buildExit)" }
} finally { Pop-Location }
