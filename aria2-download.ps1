# aria2-download.ps1 - Aria2 download entry (box script)
# Reads the box JSON param file from $args[0], then runs aria2c in the
# foreground so progress/speed is shown in the terminal window.
# Modes: manual (pause on error) / scheduled (no pause) / node (envelope reply).

$ErrorActionPreference = 'Stop'

function Pause-Message([string]$msg) {
  Write-Host
  Write-Host $msg
  cmd /c pause | Out-Null
}

function Write-Envelope([string]$path, [int]$code, [string]$msg, [hashtable]$extra = @{}) {
  $envOut = [ordered]@{ code = $code; msg = $msg }
  foreach ($k in $extra.Keys) { $envOut[$k] = $extra[$k] }
  $envOut | ConvertTo-Json -Compress | Set-Content -LiteralPath $path -Encoding UTF8
}

# ── parse payload ──
if (-not $args[0]) {
  Write-Host 'Error: no param file'
  exit 1
}

try {
  $payload = Get-Content -LiteralPath $args[0] -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  Write-Host "Error: failed to read param file: $($_.Exception.Message)"
  exit 1
}

$env = $payload.environment
$invokeMode = [string]$env.invoke_mode
$isNode = ($invokeMode -eq 'node')
$interactive = ($invokeMode -eq 'manual')

$links = @(@($payload.data.download_link) | Where-Object { $_ } | ForEach-Object { [string]$_ })

if ($links.Count -eq 0) {
  $msg = 'Error: empty download link'
  if ($isNode) { Write-Envelope $env.output_json 1 $msg; exit 1 }
  if ($interactive) { Pause-Message $msg } else { Write-Host $msg }
  exit 1
}

$dir = [string]$payload.params.download_dir
if (-not $dir) {
  $dir = Join-Path $env:USERPROFILE 'Downloads'
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

$aria2Cmd = Get-Command aria2 -ErrorAction SilentlyContinue
if (-not $aria2Cmd) { $aria2Cmd = Get-Command aria2c -ErrorAction SilentlyContinue }
if (-not $aria2Cmd) {
  $msg = 'Error: aria2 not found (binary not installed by the box)'
  if ($isNode) { Write-Envelope $env.output_json 1 $msg; exit 1 }
  if ($interactive) { Pause-Message $msg } else { Write-Host $msg }
  exit 1
}

$aria2Args = @(
  "--conf-path=$PSScriptRoot\aria2-box.conf",
  "--dir=$dir"
)

$maxSpeed = [string]$payload.params.max_speed
if ($maxSpeed -and $maxSpeed -ne '0') {
  $aria2Args += "--max-overall-download-limit=$maxSpeed"
}

$linksFile = $null
if ($links.Count -eq 1) {
  $aria2Args += $links[0]
} else {
  $linksFile = Join-Path $env:TEMP ("aria2-links-" + $PID + ".txt")
  [IO.File]::WriteAllLines($linksFile, $links, [Text.UTF8Encoding]::new($false))
  $aria2Args += "--input-file=$linksFile"
}

& $aria2Cmd.Source @aria2Args
$code = $LASTEXITCODE

if ($linksFile -and (Test-Path -LiteralPath $linksFile)) {
  Remove-Item -LiteralPath $linksFile -Force -ErrorAction SilentlyContinue
}

$extra = @{ download_dir = $dir; links_count = [string]$links.Count }

if ($isNode) {
  if ($code -eq 0) {
    Write-Envelope $env.output_json 0 'ok' $extra
  } else {
    Write-Envelope $env.output_json 1 "download failed (exit code $code)" $extra
  }
  exit $code
}

if ($code -ne 0) {
  $msg = "Download finished with error (exit code $code)."
  if ($interactive) { Pause-Message "$msg Press any key to close." } else { Write-Host $msg }
  exit $code
}
exit 0