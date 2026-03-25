# --- Variables ---
$chefBase              = 'C:\chef'
$chefCache             = 'C:\chef\cache'
$chefDownloadRoot      = 'C:\Users'
$esriZipName           = 'arcgis-5.2.0-cookbooks.zip'
$templateJsonSourceRel = 'templates\arcgis-server\11.5\windows\gis-server-federation.json'
$templateJsonTarget    = 'C:\chef\gis-server-federation.json'
$federationOkMarker    = 'C:\chef\gis_federation_configured.ok'
$federationTranscript  = 'C:\chef\configure-gis-federation.transcript.txt'

# Start a transcript so background runs write to a log file.
try {
  Start-Transcript -Path $federationTranscript -Append -ErrorAction SilentlyContinue | Out-Null
} catch {}

# If we've already successfully federated GIS Server, exit quickly.
if (Test-Path $federationOkMarker) {
  Write-Host ("GIS Server federation marker found at {0}; skipping federation run." -f $federationOkMarker)
  try { Stop-Transcript | Out-Null } catch {}
  return
}

Write-Host "=== Preparing C:\chef workspace for GIS Server federation ==="

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

# Minimal client.rb for local-mode runs
$clientRbPath = Join-Path $chefBase 'client.rb'
if (-not (Test-Path $clientRbPath)) {
  $clientRbLines = @(
    'local_mode true',
    'cache_path "C:/chef/cache"',
    'file_cache_path "C:/chef/cache"',
    'log_location "C:/chef/client.log"'
  )
  $clientRbLines -join "`r`n" | Out-File -FilePath $clientRbPath -Encoding ASCII -Force
  Write-Host "Wrote C:\chef\client.rb"
}

# Ensure Esri cookbooks are available under C:\chef (re-extract if needed)
$cookbooksDir = Join-Path $chefBase 'cookbooks'
$templatesDir = Join-Path $chefBase 'templates'
 $customRoot   = Join-Path $chefBase 'custom-cookbook'

if (-not (Test-Path $cookbooksDir -PathType Container)) {
  Write-Host "=== Extracting Esri arcgis-5.2.0-cookbooks.zip for federation ==="

  $esriZip = Get-ChildItem -Path $chefDownloadRoot -Filter $esriZipName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $esriZip) {
    Write-Host "Esri cookbooks zip ($esriZipName) not found under $chefDownloadRoot. Aborting federation."
    try { Stop-Transcript | Out-Null } catch {}
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
}

if (-not (Test-Path $templatesDir)) {
  Write-Host "C:\chef\templates not found after extraction. Aborting federation."
  try { Stop-Transcript | Out-Null } catch {}
  return
}

Write-Host "=== Preparing gis-server-federation.json ==="

$templateJsonSource = Join-Path $chefBase $templateJsonSourceRel
if (Test-Path $templateJsonSource) {
  Copy-Item -Path $templateJsonSource -Destination $templateJsonTarget -Force
  Write-Host "Copied Esri federation template to $templateJsonTarget"
} else {
  Write-Host "Federation template not found at $templateJsonSource; aborting."
  try { Stop-Transcript | Out-Null } catch {}
  return
}

# If a custom cookbook has been extracted (from the packaged arcgis-cookbook zip),
# prefer its gis-server-federation.json to override the Esri default.
$customJsonSource = Join-Path $customRoot 'templates\arcgis-server\11.5\windows\gis-server-federation.json'
if (Test-Path $customJsonSource) {
  Copy-Item -Path $customJsonSource -Destination $templateJsonTarget -Force
  Write-Host "Overrode $templateJsonTarget with custom federation template from $customJsonSource"
} else {
  Write-Host "Custom gis-server-federation.json not found under $customRoot; using Esri template."
}

Write-Host "=== Running Cinc to federate GIS Server with Portal ==="

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
  try { Stop-Transcript | Out-Null } catch {}
  return
}

Push-Location $chefBase
& $clientExePath -z -c 'C:\chef\client.rb' -j $templateJsonTarget -L 'C:\chef\client.log'
$exitCode = $LASTEXITCODE
Pop-Location

Write-Host ("cinc-client exited with code {0}" -f $exitCode)

if ($exitCode -eq 0) {
  # Mark federation as successfully configured so future runs can be skipped.
  New-Item -ItemType File -Path $federationOkMarker -Force | Out-Null
  Write-Host ("Wrote GIS Server federation marker to {0}" -f $federationOkMarker)
}

if (Test-Path $clientLogPath) {
  Write-Host "----- BEGIN C:\chef\client.log (last 200 lines) -----"
  Get-Content -Path $clientLogPath -Tail 200 | ForEach-Object { Write-Host $_ }
  Write-Host "----- END C:\chef\client.log (last 200 lines) -----"
} else {
  Write-Host "C:\chef\client.log not found."
}

try { Stop-Transcript | Out-Null } catch {}
