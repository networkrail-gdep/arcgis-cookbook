param(
  # Name of the portal patch JSON file under templates\arcgis-portal\11.5\windows
  [string]$PortalPatchJsonName = 'arcgis-portal-patches-apply.json'
)

$chefBase         = 'C:\chef'
$chefCache        = 'C:\chef\cache'
$chefDownloadRoot = 'C:\Users'
$esriZipName      = 'arcgis-5.2.0-cookbooks.zip'
$customZipPattern = 'arcgis-cookbook*.zip'

if ($PortalPatchJsonName.ToLower().EndsWith('.json')) {
  $patchBaseName = [System.IO.Path]::GetFileNameWithoutExtension($PortalPatchJsonName)
} else {
  $patchBaseName = $PortalPatchJsonName
  $PortalPatchJsonName = "$PortalPatchJsonName.json"
}

$templateJsonSourceRel = "templates\arcgis-portal\11.5\windows\$PortalPatchJsonName"
$templateJsonTarget    = "C:\\chef\\$PortalPatchJsonName"
$patchTranscript       = "C:\\chef\\configure-${patchBaseName}.transcript.txt"

try {
  Start-Transcript -Path $patchTranscript -Append -ErrorAction SilentlyContinue | Out-Null
} catch {}

Write-Host "=== Preparing C:\chef workspace for Portal patching ==="

New-Item -ItemType Directory -Path $chefBase,$chefCache -Force | Out-Null

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

$patchesDir = 'C:\Software\Archives\Patches'
if (-not (Test-Path $patchesDir -PathType Container)) {
  Write-Host "Patch directory $patchesDir was not found; aborting."
  try { Stop-Transcript | Out-Null } catch {}
  return
}

$portalPatches = Get-ChildItem -Path $patchesDir -Filter '*.msp' -ErrorAction SilentlyContinue
if (-not $portalPatches) {
  Write-Host "No .msp files found in $patchesDir; aborting."
  try { Stop-Transcript | Out-Null } catch {}
  return
}

$cookbooksDir = Join-Path $chefBase 'cookbooks'
$templatesDir = Join-Path $chefBase 'templates'
$customRoot   = Join-Path $chefBase 'custom-cookbook'

if ((-not (Test-Path $cookbooksDir -PathType Container)) -or (-not (Test-Path $templatesDir -PathType Container))) {
  Write-Host "=== Extracting Esri arcgis-5.2.0-cookbooks.zip for Portal patching ==="

  $esriZip = Get-ChildItem -Path $chefDownloadRoot -Filter $esriZipName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $esriZip) {
    Write-Host "Esri cookbooks zip ($esriZipName) not found under $chefDownloadRoot. Aborting patch run."
    try { Stop-Transcript | Out-Null } catch {}
    return
  }

  Expand-Archive -Path $esriZip.FullName -DestinationPath $chefBase -Force

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
  Write-Host "C:\chef\templates not found after extraction. Aborting patch run."
  try { Stop-Transcript | Out-Null } catch {}
  return
}

Write-Host "=== Overlaying custom $PortalPatchJsonName from arcgis-cookbook zip (if present) ==="

$customZip = Get-ChildItem -Path $chefDownloadRoot -Filter $customZipPattern -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($customZip) {
  if (Test-Path $customRoot) {
    Remove-Item -Path $customRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $customRoot -Force | Out-Null

  Expand-Archive -Path $customZip.FullName -DestinationPath $customRoot -Force
  Write-Host ("Expanded custom cookbook zip from {0} to {1}" -f $customZip.FullName, $customRoot)
} else {
  Write-Host "No custom arcgis-cookbook*.zip found under $chefDownloadRoot; using Esri patch template."
}

Write-Host "=== Preparing $PortalPatchJsonName ==="

$templateJsonSource = Join-Path $chefBase $templateJsonSourceRel
if (Test-Path $templateJsonSource) {
  Copy-Item -Path $templateJsonSource -Destination $templateJsonTarget -Force
  Write-Host "Copied Esri Portal patch template to $templateJsonTarget"
} else {
  Write-Host "Portal patch template not found at $templateJsonSource; aborting."
  try { Stop-Transcript | Out-Null } catch {}
  return
}

$customJsonSource = Join-Path $customRoot ("templates\arcgis-portal\11.5\windows\$PortalPatchJsonName")
if (Test-Path $customJsonSource) {
  Copy-Item -Path $customJsonSource -Destination $templateJsonTarget -Force
  Write-Host "Overrode $templateJsonTarget with custom patch template from $customJsonSource"
}

Write-Host "=== Running Cinc to apply Portal patch(es) ==="

$cincClientCandidates = @(
  'C:\cinc-project\cinc\bin\cinc-client.bat',
  'C:\opscode\cinc\bin\cinc-client.bat',
  'C:\opscode\cinc\bin\cinc-client.exe',
  "$env:ProgramFiles\cinc-project\cinc\bin\cinc-client.bat",
  "$env:ProgramFiles\cinc-project\cinc\bin\cinc-client.exe"
)

$clientExePath = $cincClientCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $clientExePath) {
  Write-Host 'cinc-client not found in common install locations; ensure Cinc is installed and retry.'
  try { Stop-Transcript | Out-Null } catch {}
  return
}

Push-Location $chefBase
& $clientExePath -z -c 'C:\chef\client.rb' -j $templateJsonTarget -L 'C:\chef\client.log'
$exitCode = $LASTEXITCODE
Pop-Location

Write-Host ("cinc-client exited with code {0}" -f $exitCode)

if (Test-Path 'C:\chef\client.log') {
  Write-Host '----- BEGIN C:\chef\client.log (last 200 lines) -----'
  Get-Content -Path 'C:\chef\client.log' -Tail 200 | ForEach-Object { Write-Host $_ }
  Write-Host '----- END C:\chef\client.log (last 200 lines) -----'
}

try { Stop-Transcript | Out-Null } catch {}
