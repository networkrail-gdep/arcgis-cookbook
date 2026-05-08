param(
  # Server Web Adaptor JSON template name. Pipeline passes environment-suffixed names (e.g., arcgis-server-webadaptor-dev.json for dev).
  # For manual execution, specify the desired environment variant or use the base name default.
  [string]$WebAdaptorJsonName = 'arcgis-server-webadaptor.json'
)

# --- Variables ---
$chefBase           = 'C:\chef'
$chefCache          = 'C:\chef\cache'
$chefDownloadRoot   = 'C:\Users'
$esriZipName        = 'arcgis-5.2.0-cookbooks.zip'
$serverCookbookDir  = Join-Path $chefDownloadRoot 'arcgis-server'
$customZipPattern   = 'arcgis-cookbook*.zip'
$waBaseName         = [System.IO.Path]::GetFileNameWithoutExtension($WebAdaptorJsonName)
$templateJsonTarget = ("C:\chef\{0}" -f $WebAdaptorJsonName)

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
$waOkMarker         = ("C:\chef\{0}_configured.ok" -f $waBaseName)
$waTranscript       = ("C:\chef\configure-{0}.transcript.txt" -f $waBaseName)

# Start a transcript so background runs write to a log file.
try {
  Start-Transcript -Path $waTranscript -Append -ErrorAction SilentlyContinue | Out-Null
} catch {}

# If we've already successfully configured this Web Adaptor profile, exit quickly.
if (Test-Path $waOkMarker) {
  Write-Host (("Web Adaptor marker found at {0}; skipping Cinc run.") -f $waOkMarker)
  try { Stop-Transcript | Out-Null } catch {}
  return
}

Write-Host "=== Preparing C:\chef workspace ==="

# Create base and cache dirs.
New-Item -ItemType Directory -Path $chefBase,$chefCache -Force | Out-Null

# Archive any existing client.log.
$clientLogPath = Join-Path $chefBase 'client.log'
if (Test-Path $clientLogPath) {
  $logsDir = Join-Path $chefBase 'logs'
  New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
  $ts      = Get-Date -Format 'yyyyMMddHHmmss'
  $archive = Join-Path $logsDir (("client-{0}.log") -f $ts)
  Move-Item -Path $clientLogPath -Destination $archive -Force
}

# Clean previous cookbooks/templates/custom content.
$cookbooksDir = Join-Path $chefBase 'cookbooks'
$templatesDir = Join-Path $chefBase 'templates'
$customRoot   = Join-Path $chefBase 'custom-cookbook'

foreach ($p in @($cookbooksDir,$templatesDir,$customRoot)) {
  if (Test-Path $p) {
    Remove-Item -Path $p -Recurse -Force
  }
}

# Minimal client.rb for local-mode runs.
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
  Write-Host (("Esri cookbooks zip ({0}) not found under {1}. Aborting.") -f $esriZipName, $chefDownloadRoot)
  return
}

Expand-Archive -Path $esriZip.FullName -DestinationPath $chefBase -Force

# Normalize cookbooks/templates to be directly under C:\chef.
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

Write-Host (("=== Preparing required custom {0} from arcgis-cookbook zip ===") -f $WebAdaptorJsonName)

$customZip = Get-ChildItem -Path $serverCookbookDir -Filter $customZipPattern -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($customZip) {
  if (Test-Path $customRoot) {
    Remove-Item -Path $customRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $customRoot -Force | Out-Null

  Expand-Archive -Path $customZip.FullName -DestinationPath $customRoot -Force

  $customJsonSource = Join-Path $customRoot (("templates\arcgis-webadaptor\11.5\windows\{0}") -f $WebAdaptorJsonName)
  if (Test-Path $customJsonSource) {
    # Always use the custom JSON by copying it to the fixed Chef run-list path.
    Copy-Item -Path $customJsonSource -Destination $templateJsonTarget -Force
    Remove-BOM -FilePath $templateJsonTarget
    Write-Host (("Copied required custom template from {0} to {1}") -f $customJsonSource, $templateJsonTarget)
  } else {
    Write-Error (("Required custom template '{0}' not found at {1}. Failing execution.") -f $WebAdaptorJsonName, $customJsonSource)
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
  }
} else {
  Write-Error (("No custom arcgis-cookbook*.zip found under {0}. Failing execution.") -f $serverCookbookDir)
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

Write-Host "=== Running Cinc to configure Server Web Adaptor ==="

$cincClientCandidates = @(
  'C:\cinc-project\cinc\bin\cinc-client.bat',
  'C:\opscode\cinc\bin\cinc-client.bat',
  'C:\opscode\cinc\bin\cinc-client.exe',
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

Write-Host (("cinc-client exited with code {0}") -f $exitCode)

if ($exitCode -eq 0) {
  New-Item -ItemType File -Path $waOkMarker -Force | Out-Null
  Write-Host (("Wrote Web Adaptor configuration marker to {0}") -f $waOkMarker)
}

if (Test-Path $clientLogPath) {
  Write-Host "----- BEGIN C:\chef\client.log (last 200 lines) -----"
  Get-Content -Path $clientLogPath -Tail 200 | ForEach-Object { Write-Host $_ }
  Write-Host "----- END C:\chef\client.log (last 200 lines) -----"
} else {
  Write-Host "C:\chef\client.log not found."
}

try { Stop-Transcript | Out-Null } catch {}
