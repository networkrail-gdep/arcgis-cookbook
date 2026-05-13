param(
  # Server JSON template name. Pipeline passes environment-suffixed names (e.g., arcgis-server-dev.json for dev).
  # For manual execution, specify the desired environment variant or use the base name default.
  # Examples: arcgis-server.json, arcgis-server-federation-vm.json, arcgis-server-imagehosting-vm.json
  [string]$ServerJsonName = 'arcgis-server.json'
)

# --- Variables ---
$chefBase         = 'C:\chef'
$chefCache        = 'C:\chef\cache'
$chefDownloadRoot = 'C:\Users'
$esriZipName      = 'arcgis-5.2.0-cookbooks.zip'
$customZipPattern = 'arcgis-cookbook*.zip'

# Function to remove UTF-8 BOM from a file (Chef JSON parser fails with BOM)
function Remove-BOM {
  param([string]$FilePath)
  if (Test-Path $FilePath) {
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    # Remove UTF-8 BOM if present (first 3 bytes: EF BB BF)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
      if ($bytes.Length -gt 3) {
        [System.IO.File]::WriteAllBytes($FilePath, $bytes[3..($bytes.Length - 1)])
      }
      else {
        [System.IO.File]::WriteAllBytes($FilePath, [byte[]]@())
      }
    }
  }
}

if ($ServerJsonName.ToLower().EndsWith('.json')) {
  $serverBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ServerJsonName)
} else {
  $serverBaseName = $ServerJsonName
  $ServerJsonName = "$ServerJsonName.json"
}

$templateJsonSourceRel = "templates\arcgis-server\11.5\windows\$ServerJsonName"
$templateJsonTarget = "C:\\chef\\$ServerJsonName"
$serverOkMarker   = "C:\\chef\\${serverBaseName}_configured.ok"
$legacyServerOkMarker = 'C:\chef\server_configured.ok'
$serverTranscript = "C:\\chef\\configure-${serverBaseName}.transcript.txt"

# Start a transcript so background runs write to a log file.
try {
  Start-Transcript -Path $serverTranscript -Append -ErrorAction SilentlyContinue | Out-Null
} catch {}

# If we've already successfully configured ArcGIS Server, exit quickly.
if ((Test-Path $serverOkMarker) -or (Test-Path $legacyServerOkMarker)) {
  if (Test-Path $serverOkMarker) {
    Write-Host ("Server configuration marker found at {0}; skipping Cinc run." -f $serverOkMarker)
  } else {
    Write-Host ("Legacy server configuration marker found at {0}; skipping Cinc run." -f $legacyServerOkMarker)
  }
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

Write-Host "=== Preparing required custom $ServerJsonName from arcgis-cookbook zip ==="

# Look anywhere under $chefDownloadRoot for the custom arcgis-cookbook zip
$customZip = Get-ChildItem -Path $chefDownloadRoot -Filter $customZipPattern -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($customZip) {
  if (Test-Path $customRoot) {
    Remove-Item -Path $customRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $customRoot -Force | Out-Null

  Expand-Archive -Path $customZip.FullName -DestinationPath $customRoot -Force

  # Log the extracted structure to aid debugging.
  Write-Host "=== Extracted custom-cookbook top-level contents ==="
  Get-ChildItem -Path $customRoot -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  {0}" -f $_.Name) }

  $customJsonSource = Join-Path $customRoot ("templates\arcgis-server\11.5\windows\$ServerJsonName")
  if (-not (Test-Path $customJsonSource)) {
    # Fallback: search recursively in case zip has an extra root folder level.
    Write-Host "Expected path '$customJsonSource' not found; searching recursively for '$ServerJsonName' within $customRoot..."
    $found = Get-ChildItem -Path $customRoot -Filter $ServerJsonName -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
      Write-Host "Found '$ServerJsonName' at '$($found.FullName)' via recursive search."
      $customJsonSource = $found.FullName
    }
  }

  if (Test-Path $customJsonSource) {
    # Always use the custom JSON by copying it to the fixed Chef run-list path.
    Copy-Item -Path $customJsonSource -Destination $templateJsonTarget -Force
    Remove-BOM -FilePath $templateJsonTarget
    Write-Host "Copied required custom template from $customJsonSource to $templateJsonTarget"
  } else {
    Write-Host "=== All JSON files found under custom-cookbook ==="
    Get-ChildItem -Path $customRoot -Filter '*.json' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  {0}" -f $_.FullName) }
    Write-Error "Required custom template '$ServerJsonName' not found at $customJsonSource. Failing execution."
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
  }
} else {
  Write-Error "No custom arcgis-cookbook*.zip found under $chefDownloadRoot. Failing execution."
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
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
& $clientExePath -z -c 'C:\chef\client.rb' -j $templateJsonTarget -L 'C:\chef\client.log'
$exitCode = $LASTEXITCODE
Pop-Location

Write-Host ("cinc-client exited with code {0}" -f $exitCode)

if ($exitCode -eq 0) {
  # Mark Server as successfully configured so future runs can be skipped.
  New-Item -ItemType File -Path $serverOkMarker -Force | Out-Null
  Write-Host ("Wrote Server configuration marker to {0}" -f $serverOkMarker)

  # Keep legacy marker for compatibility with existing pipeline checks.
  New-Item -ItemType File -Path $legacyServerOkMarker -Force | Out-Null
  Write-Host ("Wrote legacy Server configuration marker to {0}" -f $legacyServerOkMarker)
}

if (Test-Path $clientLogPath) {
  Write-Host "----- BEGIN C:\chef\client.log (last 200 lines) -----"
  Get-Content -Path $clientLogPath -Tail 200 | ForEach-Object { Write-Host $_ }
  Write-Host "----- END C:\chef\client.log (last 200 lines) -----"
} else {
  Write-Host "C:\chef\client.log not found."
}

try { Stop-Transcript | Out-Null } catch {}