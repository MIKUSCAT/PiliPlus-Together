param(
    [Parameter(Mandatory = $true)][string]$FlutterRoot,
    [string]$PubCache = $env:PUB_CACHE
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$FlutterRoot = (Resolve-Path -LiteralPath $FlutterRoot).Path
if ($PubCache) { $env:PUB_CACHE = $PubCache }
$env:FLUTTER_ROOT = $FlutterRoot
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
if ($env:OS -eq 'Windows_NT') {
    # Git's default Windows path limit can silently leave long plugin filenames
    # missing from a Pub checkout. Apply this only to this build process.
    $configIndex = 0
    if ($env:GIT_CONFIG_COUNT) { $configIndex = [int]$env:GIT_CONFIG_COUNT }
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$configIndex", 'core.longpaths', 'Process')
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$configIndex", 'true', 'Process')
    $env:GIT_CONFIG_COUNT = ($configIndex + 1).ToString()
}
$flutter = Join-Path $FlutterRoot 'bin/flutter'
if ($env:OS -eq 'Windows_NT') { $flutter += '.bat' }

function Apply-ProjectPatch([string]$Directory, [string]$Patch) {
    $patchPath = Join-Path $projectRoot "lib/scripts/$Patch"
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C $Directory apply --reverse --check -- $patchPath 2>$null
    $alreadyApplied = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $previousPreference
    if ($alreadyApplied) { return }
    & git -C $Directory apply --check -- $patchPath
    if ($LASTEXITCODE -ne 0) { throw "Patch does not match the SDK/package: $Patch" }
    & git -C $Directory apply -- $patchPath
    if ($LASTEXITCODE -ne 0) { throw "Could not apply $Patch" }
    Write-Output "Applied $Patch"
}

# Match the project's Android workflow, without resetting an SDK or deleting caches.
$frameworkPatches = @(
    'modal_barrier.patch', 'text_selection.patch', 'mouse_cursor.patch',
    'image_anim.patch', 'layout_builder.patch', 'navigation_drawer.patch',
    'popup_menu.patch', 'fab.patch', 'null_safety_for_selectable_region.patch',
    'selectable_region.patch', 'editable_text.patch', 'text_field.patch',
    'scroll_position.patch', 'scrollable.patch', 'scrollable_gesture.patch',
    'draggable_scrollable_sheet.patch', 'scaffold.patch', 'text.patch',
    'text_painter.patch', 'sliver.patch', 'refresh_indicator.patch',
    'double_tap_gesture.patch', 'media_query.patch', 'bottom_sheet_android.patch',
    'scroll_view.patch', 'navigator.patch'
)
foreach ($patch in $frameworkPatches) { Apply-ProjectPatch $FlutterRoot $patch }

Push-Location $projectRoot
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
    $configPath = Join-Path $projectRoot '.dart_tool/package_config.json'
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $material = $config.packages | Where-Object { $_.name -eq 'material_ui' }
    if (-not $material) { throw 'material_ui was not resolved' }
    $baseUri = [Uri]::new($configPath)
    $materialDir = [Uri]::new($baseUri, $material.rootUri).LocalPath
    $materialPatches = @(
        'modal_barrier_material.patch', 'navigation_drawer.patch',
        'popup_menu.patch', 'fab.patch', 'text_field.patch', 'scaffold.patch',
        'refresh_indicator.patch', 'tabs.patch', 'bottom_sheet_android.patch'
    )
    foreach ($patch in $materialPatches) {
        Apply-ProjectPatch $materialDir "material/$patch"
    }
} finally { Pop-Location }

Write-Output 'Flutter and material_ui patches are ready.'
