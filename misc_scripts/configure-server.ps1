# --- Variables ---
$chefBase         = 'C:\chef'
$chefCache        = 'C:\chef\cache'
$chefDownloadRoot = 'C:\Users\gdepadmin'
$esriZipName      = 'arcgis-5.2.0-cookbooks.zip'
$customZipPattern = 'arcgis-cookbook*.zip'
$templateJsonTarget = 'C:\chef\arcgis-server.json'
$serverOkMarker   = 'C:\chef\server_configured.ok'
$serverTranscript = 'C:\chef\configure-server.transcript.txt'

# Start a transcript so background runs write to a log file.
try {
  Start-Transcript -Path $serverTranscript -Append -ErrorAction SilentlyContinue | Out-Null
} catch {}

# If we've already successfully configured ArcGIS Server, exit quickly.
if (Test-Path $serverOkMarker) {
  Write-Host ("Server configuration marker found at {0}; skipping Cinc run." -f $serverOkMarker)
  try { Stop-Transcript | Out-Null } catch {}
  return
}

Write-Host "=== Preparing C:\chef workspace for ArcGIS Server ==="

# Create base and cache dirs
New-Item -ItemType Directory -Path $chefBase,$chefCache -Force | Out-Null

# Archive any existing client.log
$clientLogPath = Join-Path $chefBase 'client.log'
if (Test-Path $clientLogPath) {
  $logsDir = Join-Path $chefBase 'logs'
  New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
  $ts      = Get-Date -Format 'yyyyMMddHHmmss'
  $archive = Join-Path $logsDir ("client-{0}.log" -f $ts)
  Move-Item -Path $clientLogPath -Destination $archive -Force
}

# Clean previous cookbooks/templates/custom content
$cookbooksDir = Join-Path $chefBase 'cookbooks'
$templatesDir = Join-Path $chefBase 'templates'
$customRoot   = Join-Path $chefBase 'custom-cookbook'

foreach ($p in @($cookbooksDir,$templatesDir,$customRoot)) {
  if (Test-Path $p) {
    Remove-Item -Path $p -Recurse -Force
  }
}

# Minimal client.rb for local-mode runs
$clientRbPath = Join-Path $chefBase 'client.rb'
$clientRbLines = @(
  'local_mode true',
  'cache_path "C:/chef/cache"',
  'file_cache_path "C:/chef/cache"',
  'log_location "C:/chef/client.log"'
)
$clientRbLines -join "`r`n" | Out-File -FilePath $clientRbPath -Encoding ASCII -Force
Write-Host "Wrote C:\chef\client.rb"

Write-Host "=== Extracting Esri arcgis-5.2.0-cookbooks.zip for Server ==="

$esriZip = Get-ChildItem -Path $chefDownloadRoot -Filter $esriZipName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $esriZip) {
  Write-Host "Esri cookbooks zip ($esriZipName) not found under $chefDownloadRoot. Aborting."
  return
}

Expand-Archive -Path $esriZip.FullName -DestinationPath $chefBase -Force

# Normalize cookbooks/templates to be directly under C:\chef
if (-not (Test-Path $cookbooksDir)) {
  $rootWithCookbooks = Get-ChildItem -Path $chefBase -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'cookbooks') } |
    Select-Object -First 1

  if ($rootWithCookbooks) {
    $sourceCookbooks = Join-Path $rootWithCookbooks.FullName 'cookbooks'
    Move-Item -Path $sourceCookbooks -Destination $cookbooksDir -Force

    $sourceTemplates = Join-Path $rootWithCookbooks.FullName 'templates'
    if (Test-Path $sourceTemplates) {
      Move-Item -Path $sourceTemplates -Destination $templatesDir -Force
    }
  }
}

if (-not (Test-Path $cookbooksDir)) {
  Write-Host "C:\chef\cookbooks not found after extraction. Aborting."
  return
}

Write-Host "=== Creating base arcgis-server.json from Esri template ==="

$templateJsonSource = Join-Path $chefBase 'templates\arcgis-server\11.5\windows\arcgis-server.json'
if (Test-Path $templateJsonSource) {
  Copy-Item -Path $templateJsonSource -Destination $templateJsonTarget -Force
  Write-Host "Copied Esri Server template to $templateJsonTarget"
} else {
  Write-Host "Esri server template not found at $templateJsonSource; continuing without it."
}

Write-Host "=== Overlaying custom arcgis-server.json from arcgis-cookbook zip (if present) ==="

# Look anywhere under C:\Users\gdepadmin for the custom arcgis-cookbook zip
$customZip = Get-ChildItem -Path $chefDownloadRoot -Filter $customZipPattern -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($customZip) {
  if (Test-Path $customRoot) {
    Remove-Item -Path $customRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $customRoot -Force | Out-Null

  Expand-Archive -Path $customZip.FullName -DestinationPath $customRoot -Force

  $customJsonSource = Join-Path $customRoot 'templates\arcgis-server\11.5\windows\arcgis-server.json'
  if (Test-Path $customJsonSource) {
    Copy-Item -Path $customJsonSource -Destination $templateJsonTarget -Force
    Write-Host "Overrode $templateJsonTarget with custom template from $customJsonSource"
  } else {
    Write-Host "Custom arcgis-server.json not found in $customRoot; keeping Esri template."
  }
} else {
  Write-Host "No custom arcgis-cookbook*.zip found under $chefDownloadRoot; using Esri template only."
}

Write-Host "=== Running Cinc to configure ArcGIS Server ==="

$cincClientCandidates = @(
  "C:\cinc-project\cinc\bin\cinc-client.bat",
  "C:\opscode\cinc\bin\cinc-client.bat",
  "C:\opscode\cinc\bin\cinc-client.exe",
  "$env:ProgramFiles\cinc-project\cinc\bin\cinc-client.bat",
  "$env:ProgramFiles\cinc-project\cinc\bin\cinc-client.exe"
)

$clientExePath = $cincClientCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $clientExePath) {
  Write-Host "cinc-client not found in common install locations; ensure Cinc is installed and retry."
  return
}

Push-Location $chefBase
& $clientExePath -z -c 'C:\chef\client.rb' -j 'C:\chef\arcgis-server.json' -L 'C:\chef\client.log'
$exitCode = $LASTEXITCODE
Pop-Location

Write-Host ("cinc-client exited with code {0}" -f $exitCode)

if ($exitCode -eq 0) {
  # Mark Server as successfully configured so future runs can be skipped.
  New-Item -ItemType File -Path $serverOkMarker -Force | Out-Null
  Write-Host ("Wrote Server configuration marker to {0}" -f $serverOkMarker)
}

if (Test-Path $clientLogPath) {
  Write-Host "----- BEGIN C:\chef\client.log (last 200 lines) -----"
  Get-Content -Path $clientLogPath -Tail 200 | ForEach-Object { Write-Host $_ }
  Write-Host "----- END C:\chef\client.log (last 200 lines) -----"
} else {
  Write-Host "C:\chef\client.log not found."
}

try { Stop-Transcript | Out-Null } catch {}