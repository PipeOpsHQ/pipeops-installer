#!/usr/bin/env pwsh
# PipeOps CLI Windows installer stub
# Usage:
#   irm https://get.pipeops.dev/cli.ps1 | iex
# Optional: $env:VERSION = 'v1.2.3'

$ErrorActionPreference = 'Stop'

$Version = $env:VERSION
if ([string]::IsNullOrWhiteSpace($Version) -or $Version -eq 'latest') {
  $Url = 'https://raw.githubusercontent.com/PipeOpsHQ/pipeops-cli/main/install.ps1'
} else {
  $Url = "https://raw.githubusercontent.com/PipeOpsHQ/pipeops-cli/$Version/install.ps1"
}

Write-Host "==> Downloading installer from $Url"

$script = Invoke-RestMethod -UseBasicParsing -Uri $Url
Invoke-Expression $script

