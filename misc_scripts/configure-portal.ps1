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

# Resolve an account name to SID, accounting for local shorthand variants.
function Resolve-AccountSid {
  param(
    [Parameter(Mandatory = $true)]
    [string]$AccountName
  )

  $candidates = [System.Collections.Generic.List[string]]::new()
  $candidates.Add($AccountName)

  if ($AccountName.StartsWith('.\')) {
    $candidates.Add("$env:COMPUTERNAME\" + $AccountName.Substring(2))
  }

  if ($AccountName -notmatch '@' -and -not $AccountName.EndsWith('$') -and $AccountName -notmatch '\\') {
    $candidates.Add("$env:COMPUTERNAME\\$AccountName")
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    try {
      $sid = ([System.Security.Principal.NTAccount]$candidate).Translate([System.Security.Principal.SecurityIdentifier]).Value
      return [PSCustomObject]@{
        Success = $true
        Account = $candidate
        Sid = $sid
      }
    } catch {}
  }

  return [PSCustomObject]@{
    Success = $false
    Account = $AccountName
    Sid = $null
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
  if (-not (Test-Path $customJsonSource)) {
    Write-Host "Expected path '$customJsonSource' not found; searching recursively for '$PortalJsonName' within $customRoot..."
    $found = Get-ChildItem -Path $customRoot -Filter $PortalJsonName -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
      $customJsonSource = $found.FullName
    }
  }

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

# Validate and normalize root certificate path before Cinc run.
$rootCertPath = [string]$portalConfig.arcgis.portal.root_cert
$rootCertAlias = [string]$portalConfig.arcgis.portal.root_cert_alias
$certRepoDir = [string]$portalConfig.arcgis.repository.certificates

if (-not [string]::IsNullOrWhiteSpace($rootCertPath) -and -not [string]::IsNullOrWhiteSpace($rootCertAlias)) {
  if (-not (Test-Path $rootCertPath)) {
    if ([string]::IsNullOrWhiteSpace($certRepoDir)) {
      $certRepoDir = Split-Path -Path $rootCertPath -Parent
    }

    $resolvedRootCert = $null
    if (-not [string]::IsNullOrWhiteSpace($certRepoDir) -and (Test-Path $certRepoDir)) {
      $configuredBase = [System.IO.Path]::GetFileNameWithoutExtension($rootCertPath)

      $candidates = @()
      if (-not [string]::IsNullOrWhiteSpace($configuredBase)) {
        $candidates += Get-ChildItem -Path $certRepoDir -Filter ($configuredBase + '_export*.pfx') -File -ErrorAction SilentlyContinue
        $candidates += Get-ChildItem -Path $certRepoDir -Filter ($configuredBase + '*.pfx') -File -ErrorAction SilentlyContinue
      }
      $candidates += Get-ChildItem -Path $certRepoDir -Filter ('*' + $rootCertAlias + '*.pfx') -File -ErrorAction SilentlyContinue

      $resolvedRootCert = $candidates |
        Sort-Object -Property LastWriteTimeUtc -Descending |
        Select-Object -First 1
    }

    if ($resolvedRootCert) {
      $portalConfig.arcgis.portal.root_cert = $resolvedRootCert.FullName
      $jsonOut = $portalConfig | ConvertTo-Json -Depth 64
      $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
      [System.IO.File]::WriteAllText($templateJsonTarget, $jsonOut, $utf8NoBom)
      Write-Host ("Resolved missing root_cert to '{0}' based on alias '{1}'." -f $resolvedRootCert.FullName, $rootCertAlias)
    }
    else {
      $availablePfx = @()
      if (-not [string]::IsNullOrWhiteSpace($certRepoDir) -and (Test-Path $certRepoDir)) {
        $availablePfx = Get-ChildItem -Path $certRepoDir -Filter '*.pfx' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
      }

      $availableText = if ($availablePfx.Count -gt 0) { ($availablePfx -join ', ') } else { 'none' }
      Write-Error ("Configured root_cert '{0}' not found. No matching .pfx was found in '{1}'. Available .pfx files: {2}" -f $rootCertPath, $certRepoDir, $availableText)
      try { Stop-Transcript | Out-Null } catch {}
      exit 1
    }
  }
}

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

# If the Portal install footprint is missing but stale product registration exists,
# ArcGIS cookbook may incorrectly execute update_account before install and fail.
$portalInstallDir = [string]$portalConfig.arcgis.portal.install_dir
$configureSvcAccountBat = if ($portalInstallDir) { Join-Path $portalInstallDir 'tools\ConfigUtility\configureserviceaccount.bat' } else { $null }

function Test-ConfigServiceAccountUtility {
  param(
    [string]$UtilityPath
  )

  if ([string]::IsNullOrWhiteSpace($UtilityPath) -or -not (Test-Path $UtilityPath)) {
    return $false
  }

  # Probe the utility in the same process model Cinc/Chef uses.
  # A partial/corrupt install can leave the bat file present but still un-runnable.
  $probeOutput = & cmd.exe /C "\"$UtilityPath\" --help" 2>&1
  $probeText = ($probeOutput | Out-String)

  if ($LASTEXITCODE -eq 9009) {
    return $false
  }

  if ($probeText -match 'The system cannot find the file specified\.') {
    return $false
  }

  return $true
}

function Test-ConfigServiceAccountUpdate {
  param(
    [string]$UtilityPath,
    [string]$Username,
    [string]$Password
  )

  if ([string]::IsNullOrWhiteSpace($UtilityPath) -or -not (Test-Path $UtilityPath)) {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
    return $false
  }

  # Run the same command shape Chef uses. If this fails, update_account will fail too.
  $probeOutput = & cmd.exe /C "\"$UtilityPath\" --username \"$Username\" --password \"$Password\"" 2>&1
  $probeText = ($probeOutput | Out-String).Trim()

  if ($LASTEXITCODE -eq 0) {
    return $true
  }

  if (-not [string]::IsNullOrWhiteSpace($probeText)) {
    Write-Host ("ConfigUtility update preflight failed with exit code {0}: {1}" -f $LASTEXITCODE, ($probeText -replace "`r?`n", ' '))
  }
  else {
    Write-Host ("ConfigUtility update preflight failed with exit code {0}." -f $LASTEXITCODE)
  }

  return $false
}

# Check if configureserviceaccount.bat is callable (not just present).
$configUtilityHealthy = $false
if ($configureSvcAccountBat -and (Test-ConfigServiceAccountUtility -UtilityPath $configureSvcAccountBat)) {
  $configUtilityHealthy = Test-ConfigServiceAccountUpdate -UtilityPath $configureSvcAccountBat -Username $runAsUser -Password $runAsPassword
}

if ($configUtilityHealthy) {
    Write-Host "ConfigUtility preflight succeeded at $configureSvcAccountBat. Proceeding with update_account logic."
} else {
    Write-Host "ConfigUtility is missing or not callable at $configureSvcAccountBat. Cleaning stale Portal registry/product code entries and install directory."

    # Remove Portal uninstall keys (32/64-bit)
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $entry = Get-ItemProperty $_.PSPath -ErrorAction Stop
                if ($entry.DisplayName -like 'Portal for ArcGIS*') {
                    Write-Host ("Removing stale uninstall key: {0}" -f $_.PSPath)
                    Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
    }

          # Remove Windows Installer product entries by ProductName/DisplayName metadata.
          # Installer product key names are packed GUIDs, so matching by GUID text is unreliable.
    $productRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
    )

          foreach ($root in $productRoots) {
            Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
              try {
                $installPropsPath = Join-Path $_.PSPath 'InstallProperties'
                $nameSource = ''

                if (Test-Path $installPropsPath) {
                  $props = Get-ItemProperty -Path $installPropsPath -ErrorAction SilentlyContinue
                  if ($props) {
                    if ($props.DisplayName) { $nameSource = [string]$props.DisplayName }
                    elseif ($props.ProductName) { $nameSource = [string]$props.ProductName }
                  }
                }

                if ($nameSource -like 'Portal for ArcGIS*') {
                  Write-Host ("Removing stale installer product key: {0}" -f $_.PSPath)
                  Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                }
              } catch {}
            }
    }

    # Remove Portal ESRI registry keys (32/64-bit)
    $esriRoots = @(
        'HKLM:\SOFTWARE\ESRI',
        'HKLM:\SOFTWARE\WOW6432Node\ESRI'
    )
    foreach ($root in $esriRoots) {
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSChildName -like '*Portal*') {
                Write-Host ("Removing stale ESRI Portal registry key: {0}" -f $_.PSPath)
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Remove stale Portal Windows services if present.
    foreach ($serviceName in @('Portal for ArcGIS', 'ArcGIS Portal')) {
      $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
      if ($svc) {
        Write-Host ("Deleting stale service: {0}" -f $serviceName)
        try {
          if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
          }
        } catch {}
        & sc.exe delete "$serviceName" | Out-Null
      }
    }

    # Remove Portal install directory if present
    if ($portalInstallDir -and (Test-Path $portalInstallDir)) {
        Write-Host ("Removing stale Portal install directory: {0}" -f $portalInstallDir)
        Remove-Item -Path $portalInstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Ensure Cinc does not attempt update_account on a stale footprint and forces install flow.
    # update_account is guarded by run_as_msa and product_installed?(portal.product_code).
    $sentinelProductCode = '{00000000-0000-0000-0000-000000000000}'

    if (-not ($portalConfig.arcgis.PSObject.Properties.Name -contains 'run_as_msa')) {
      $portalConfig.arcgis | Add-Member -MemberType NoteProperty -Name 'run_as_msa' -Value $false
    }

    if (-not ($portalConfig.arcgis.portal.PSObject.Properties.Name -contains 'product_code')) {
      $portalConfig.arcgis.portal | Add-Member -MemberType NoteProperty -Name 'product_code' -Value ''
    }

    $portalConfig.arcgis.run_as_msa = $true
    $portalConfig.arcgis.portal.product_code = $sentinelProductCode

    $jsonOut = $portalConfig | ConvertTo-Json -Depth 64
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($templateJsonTarget, $jsonOut, $utf8NoBom)

    Write-Host 'Set arcgis.run_as_msa=true in run JSON to skip update_account on stale install state.'
    Write-Host ("Set arcgis.portal.product_code to sentinel {0} to prevent stale product_installed? matches." -f $sentinelProductCode)
}

$resolvedRunAsUser = $runAsUser

# Disambiguate bare local usernames on domain-joined VMs.
# Use MACHINE\user to keep Windows account resolution local without using .\user
# (which previously caused owner SID mapping issues in some Chef resources).
if ($runAsUser.StartsWith('.\')) {
  $resolvedRunAsUser = "$env:COMPUTERNAME\" + $runAsUser.Substring(2)

  $rawJson = Get-Content -Path $templateJsonTarget -Raw -Encoding UTF8
  $oldJsonValue = ($runAsUser | ConvertTo-Json -Compress).Trim()
  $newJsonValue = ($resolvedRunAsUser | ConvertTo-Json -Compress).Trim()
  $runAsUserPattern = '"run_as_user"\s*:\s*' + [regex]::Escape($oldJsonValue)

  if ([regex]::IsMatch($rawJson, $runAsUserPattern)) {
    $updatedJson = [regex]::Replace($rawJson, $runAsUserPattern, '"run_as_user": ' + $newJsonValue, 1)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($templateJsonTarget, $updatedJson, $utf8NoBom)
    $portalConfig.arcgis.run_as_user = $resolvedRunAsUser
    Write-Host ("Normalized local run_as_user from '{0}' to '{1}' in {2}" -f $runAsUser, $resolvedRunAsUser, $templateJsonTarget)
  }
  else {
    Write-Error "Unable to safely update run_as_user in $templateJsonTarget. Failing execution."
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
  }
}
elseif ($runAsUser -notmatch '@' -and -not $runAsUser.EndsWith('$') -and $runAsUser -notmatch '\\') {
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

$sidResolution = Resolve-AccountSid -AccountName $resolvedRunAsUser
if (-not $sidResolution.Success) {
  Write-Error ("run_as_user '{0}' cannot be translated to a Windows SID. This causes Chef owner/ACL operations to fail with error 1332. Verify account context (local vs domain) and account integrity, then retry." -f $resolvedRunAsUser)
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

if ($sidResolution.Account -ne $resolvedRunAsUser) {
  $rawJson = Get-Content -Path $templateJsonTarget -Raw -Encoding UTF8
  $oldJsonValue = ($resolvedRunAsUser | ConvertTo-Json -Compress).Trim()
  $newJsonValue = ($sidResolution.Account | ConvertTo-Json -Compress).Trim()
  $runAsUserPattern = '"run_as_user"\s*:\s*' + [regex]::Escape($oldJsonValue)

  if ([regex]::IsMatch($rawJson, $runAsUserPattern)) {
    $updatedJson = [regex]::Replace($rawJson, $runAsUserPattern, '"run_as_user": ' + $newJsonValue, 1)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($templateJsonTarget, $updatedJson, $utf8NoBom)
    $resolvedRunAsUser = $sidResolution.Account
    $portalConfig.arcgis.run_as_user = $resolvedRunAsUser
    Write-Host ("Updated run_as_user to SID-resolvable identity '{0}' in {1}" -f $resolvedRunAsUser, $templateJsonTarget)
  }
}

Write-Host ("Validated run_as_user SID mapping: {0} -> {1}" -f $resolvedRunAsUser, $sidResolution.Sid)

try {
  $effectiveConfig = Get-Content -Path $templateJsonTarget -Raw -Encoding UTF8 | ConvertFrom-Json
  Write-Host ("Effective JSON before Cinc: run_as_msa={0}; portal.product_code={1}; portal.install_dir={2}" -f $effectiveConfig.arcgis.run_as_msa, $effectiveConfig.arcgis.portal.product_code, $effectiveConfig.arcgis.portal.install_dir)
} catch {
  Write-Host ("Unable to read effective JSON before Cinc: {0}" -f $_.Exception.Message)
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