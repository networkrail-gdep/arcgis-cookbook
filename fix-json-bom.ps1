#!/usr/bin/env pwsh
<#
.SYNOPSIS
Remove UTF-8 BOM from all JSON template files in the arcgis-cookbook templates directory.
This fixes Chef JSON parsing errors caused by BOM markers.

.DESCRIPTION
Scans all .json files under templates/arcgis-*/*/windows and templates/arcgis-*/*/linux
and removes UTF-8 BOM (Byte Order Mark) if present. This is necessary because Chef's
JSON parser fails when it encounters BOM characters at the start of JSON files.
#>

param(
  [string]$TemplatesRoot = 'templates'
)

if (-not (Test-Path $TemplatesRoot)) {
  Write-Error "Templates directory not found at: $TemplatesRoot"
  exit 1
}

$count = 0
$fixed = 0

# Find all JSON files under templates
$jsonFiles = Get-ChildItem -Path $TemplatesRoot -Filter '*.json' -Recurse -ErrorAction SilentlyContinue

if ($jsonFiles.Count -eq 0) {
  Write-Host "No JSON files found under $TemplatesRoot"
  exit 0
}

Write-Host "Found $($jsonFiles.Count) JSON files. Checking for UTF-8 BOM..."

foreach ($file in $jsonFiles) {
  $count++
  try {
    # Read file as bytes to detect BOM
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    
    # Check for UTF-8 BOM (EF BB BF)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
      # Read content without BOM
      $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
      
      # Remove BOM character if present
      if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
        $content = $content.Substring(1)
      }
      
      # Write back without BOM
      [System.IO.File]::WriteAllText($file.FullName, $content, [System.Text.UTF8Encoding]$false)
      Write-Host "Fixed BOM in: $($file.FullName)"
      $fixed++
    }
  }
  catch {
    Write-Warning "Error processing $($file.FullName): $_"
  }
}

Write-Host ""
Write-Host "==========================================="
Write-Host "Processed: $count files"
Write-Host "Fixed:     $fixed files"
Write-Host "==========================================="

if ($fixed -gt 0) {
  Write-Host "BOM removal complete! All JSON files have been fixed."
  Write-Host "Commit and push the changes:"
  Write-Host "  git add -A"
  Write-Host "  git commit -m 'Fix: Remove UTF-8 BOM from all JSON template files'"
  Write-Host "  git push"
}
else {
  Write-Host "No BOM markers found. All JSON files are clean."
}
