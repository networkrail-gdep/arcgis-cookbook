# --- Variables ---
$chefBase          = 'C:\chef'
$chefCache         = 'C:\chef\cache'
$chefDownloadRoot  = 'C:\Users\gdepadmin'
$esriZipName       = 'arcgis-5.2.0-cookbooks.zip'
$portalCookbookDir = Join-Path $chefDownloadRoot 'arcgis-portal'
$customZipPattern  = 'arcgis-cookbook*.zip'
$templateJsonTarget = 'C:\chef\arcgis-portal.json'
$portalOkMarker    = 'C:\chef\portal_configured.ok'

# If we've already successfully configured Portal, exit quickly.
if (Test-Path $portalOkMarker) {
  Write-Host ("Portal configuration marker found at {0}; skipping Cinc run." -f $portalOkMarker)
  return
}

Write-Host "=== Preparing C:\chef workspace ==="

# Create base and cache dirs
New-Item -ItemType Directory -Path $chefBase,$chefCache -Force | Out-Null

# Archive any existing client.log
$clientLogPath = Join-Path $chefBase 'client.log'
if (Test-Path $clientLogPath) {
  $logsDir   = Join-Path $chefBase 'logs'
  New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
  $ts        = Get-Date -Format 'yyyyMMddHHmmss'
  $archive   = Join-Path $logsDir ("client-{0}.log" -f $ts)
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

Write-Host "=== Extracting Esri arcgis-5.2.0-cookbooks.zip ==="

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

Write-Host "=== Creating base arcgis-portal.json from Esri template ==="

$templateJsonSource = Join-Path $chefBase 'templates\arcgis-portal\11.5\windows\arcgis-portal-primary.json'
if (Test-Path $templateJsonSource) {
  Copy-Item -Path $templateJsonSource -Destination $templateJsonTarget -Force
  Write-Host "Copied Esri template to $templateJsonTarget"
} else {
  Write-Host "Esri portal template not found at $templateJsonSource; continuing without it."
}

Write-Host "=== Overlaying custom arcgis-portal.json from arcgis-cookbook zip (if present) ==="

$customZip = Get-ChildItem -Path $portalCookbookDir -Filter $customZipPattern -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($customZip) {
  if (Test-Path $customRoot) {
    Remove-Item -Path $customRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $customRoot -Force | Out-Null

  Expand-Archive -Path $customZip.FullName -DestinationPath $customRoot -Force

  $customJsonSource = Join-Path $customRoot 'templates\arcgis-portal\11.5\windows\arcgis-portal-primary.json'
  if (Test-Path $customJsonSource) {
    Copy-Item -Path $customJsonSource -Destination $templateJsonTarget -Force
    Write-Host "Overrode $templateJsonTarget with custom template from $customJsonSource"
  } else {
    Write-Host "Custom arcgis-portal-primary.json not found in $customRoot; keeping Esri template."
  }
} else {
  Write-Host "No custom arcgis-cookbook*.zip found under $portalCookbookDir; using Esri template only."
}

Write-Host "=== Running Cinc to configure Portal ==="

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
& $clientExePath -z -c 'C:\chef\client.rb' -j 'C:\chef\arcgis-portal.json' -L 'C:\chef\client.log'
$exitCode = $LASTEXITCODE
Pop-Location

Write-Host ("cinc-client exited with code {0}" -f $exitCode)

if ($exitCode -eq 0) {
  # Mark Portal as successfully configured so future runs can be skipped.
  New-Item -ItemType File -Path $portalOkMarker -Force | Out-Null
  Write-Host ("Wrote Portal configuration marker to {0}" -f $portalOkMarker)
}

if (Test-Path $clientLogPath) {
  Write-Host "----- BEGIN C:\chef\client.log (last 200 lines) -----"
  Get-Content -Path $clientLogPath -Tail 200 | ForEach-Object { Write-Host $_ }
  Write-Host "----- END C:\chef\client.log (last 200 lines) -----"
} else {
  Write-Host "C:\chef\client.log not found."
}