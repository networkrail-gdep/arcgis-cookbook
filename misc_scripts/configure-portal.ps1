param(
  # Portal JSON template name. Pipeline passes environment-suffixed names (e.g., arcgis-portal-primary-dev.json for dev).
  # For manual execution, specify the desired environment variant or use the base name default.
  [string]$PortalJsonName = 'arcgis-portal-primary.json'
)

# --- Variables ---
$chefBase          = 'C:\chef'
$chefCache         = 'C:\chef\cache'
$chefDownloadRoot  = 'C:\Users'
$esriZipName       = 'arcgis-5.2.0-cookbooks.zip'
$portalCookbookDir = Join-Path $chefDownloadRoot 'arcgis-portal'
$customZipPattern  = 'arcgis-cookbook*.zip'
$templateJsonTarget = 'C:\chef\arcgis-portal.json'
$portalOkMarker    = 'C:\chef\portal_configured.ok'
$portalTranscript  = 'C:\chef\configure-portal.transcript.txt'

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

# Start a transcript so background runs write to a log file.
try {
  Start-Transcript -Path $portalTranscript -Append -ErrorAction SilentlyContinue | Out-Null
} catch {}

# If we've already successfully configured Portal, exit quickly.
if (Test-Path $portalOkMarker) {
  Write-Host ("Portal configuration marker found at {0}; skipping Cinc run." -f $portalOkMarker)
  try { Stop-Transcript | Out-Null } catch {}
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

Write-Host "=== Preparing required custom arcgis-portal.json from arcgis-cookbook zip ==="

$customZip = Get-ChildItem -Path $portalCookbookDir -Filter $customZipPattern -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($customZip) {
  if (Test-Path $customRoot) {
    Remove-Item -Path $customRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $customRoot -Force | Out-Null

  Expand-Archive -Path $customZip.FullName -DestinationPath $customRoot -Force

  $customJsonSource = Join-Path $customRoot ("templates\arcgis-portal\11.5\windows\{0}" -f $PortalJsonName)
  if (Test-Path $customJsonSource) {
    # Always use the custom JSON by copying it to the fixed Chef run-list path.
    Copy-Item -Path $customJsonSource -Destination $templateJsonTarget -Force
    Remove-BOM -FilePath $templateJsonTarget
    Write-Host "Copied required custom template from $customJsonSource to $templateJsonTarget"
  } else {
    Write-Error "Required custom template '$PortalJsonName' not found at $customJsonSource. Failing execution."
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
  }
} else {
  Write-Error "No custom arcgis-cookbook*.zip found under $portalCookbookDir. Failing execution."
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

Write-Host "=== Validating Portal run-as account settings in arcgis-portal.json ==="

try {
  $portalConfig = Get-Content -Path $templateJsonTarget -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  Write-Error ("Unable to parse {0}: {1}" -f $templateJsonTarget, $_.Exception.Message)
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

$runAsUser = [string]$portalConfig.arcgis.run_as_user
$runAsPassword = [string]$portalConfig.arcgis.run_as_password

if ([string]::IsNullOrWhiteSpace($runAsUser)) {
  Write-Error "arcgis.run_as_user is missing or empty in $templateJsonTarget. Failing execution."
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

if ([string]::IsNullOrWhiteSpace($runAsPassword)) {
  Write-Error "arcgis.run_as_password is missing or empty in $templateJsonTarget. Failing execution."
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

$resolvedRunAsUser = $runAsUser

# Disambiguate bare local usernames on domain-joined VMs.
# Use MACHINE\user to keep Windows account resolution local without using .\user
# (which previously caused owner SID mapping issues in some Chef resources).
if ($runAsUser -notmatch '@' -and -not $runAsUser.EndsWith('$') -and $runAsUser -notmatch '\\') {
  $resolvedRunAsUser = "$env:COMPUTERNAME\$runAsUser"

  $rawJson = Get-Content -Path $templateJsonTarget -Raw -Encoding UTF8
  $oldJsonValue = ($runAsUser | ConvertTo-Json -Compress).Trim()
  $newJsonValue = ($resolvedRunAsUser | ConvertTo-Json -Compress).Trim()
  $runAsUserPattern = '"run_as_user"\s*:\s*' + [regex]::Escape($oldJsonValue)

  if ([regex]::IsMatch($rawJson, $runAsUserPattern)) {
    $updatedJson = [regex]::Replace($rawJson, $runAsUserPattern, '"run_as_user": ' + $newJsonValue, 1)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($templateJsonTarget, $updatedJson, $utf8NoBom)
    $portalConfig.arcgis.run_as_user = $resolvedRunAsUser
    Write-Host ("Qualified run_as_user from '{0}' to '{1}' in {2}" -f $runAsUser, $resolvedRunAsUser, $templateJsonTarget)
  }
  else {
    Write-Error "Unable to safely update run_as_user in $templateJsonTarget. Failing execution."
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
  }
}

$isLocalAccount = ($resolvedRunAsUser -notmatch '@' -and -not $resolvedRunAsUser.EndsWith('$') -and ($resolvedRunAsUser -notmatch '\\' -or $resolvedRunAsUser.StartsWith('.\') -or $resolvedRunAsUser.StartsWith("$env:COMPUTERNAME\")))

if ($isLocalAccount) {
  if ($resolvedRunAsUser.StartsWith('.\')) {
    $localUserName = $resolvedRunAsUser.Substring(2)
  }
  elseif ($resolvedRunAsUser.StartsWith("$env:COMPUTERNAME\")) {
    $localUserName = $resolvedRunAsUser.Substring($env:COMPUTERNAME.Length + 1)
  }
  else {
    $localUserName = $resolvedRunAsUser
  }

  $localUser = Get-LocalUser -Name $localUserName -ErrorAction SilentlyContinue

  if (-not $localUser) {
    Write-Error ("Local run-as account '{0}' not found on VM. Failing execution." -f $localUserName)
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
  }

  try {
    $securePassword = ConvertTo-SecureString -String $runAsPassword -AsPlainText -Force
    Set-LocalUser -Name $localUserName -Password $securePassword -ErrorAction Stop
    Enable-LocalUser -Name $localUserName -ErrorAction SilentlyContinue
    Write-Host ("Synchronized password and enabled local run-as account '{0}'." -f $localUserName)
  } catch {
    Write-Error ("Failed to set password for local run-as account '{0}': {1}" -f $localUserName, $_.Exception.Message)
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
  }
  # Cinc's update_account action will apply the credentials to the service; no need to pre-apply here.
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

try { Stop-Transcript | Out-Null } catch {}