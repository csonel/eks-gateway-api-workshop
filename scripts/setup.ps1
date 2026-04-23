# ---------------------------------------------------------
# AWS Community Day Romania 2026 - Workshop Prerequisites
# Installs: Terraform, AWS CLI v2, kubectl, Helm, jq, git
# Supports: Windows 10/11 with winget
# ---------------------------------------------------------

param(
    [Alias("check")]
    [switch]$CheckOnly,
    [Alias("h")]
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"

# Minimum acceptable versions for readiness checks
$TerraformVersion = "1.12.0"
$KubectlMinimumVersion = "1.35.0"
$HelmMinimumVersion = "3.17.0"

$results = @{}

function Write-Info  { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-Command {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Refresh-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $combined = @($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $env:Path = ($combined -join ";")
}

function Wait-ForCommand {
    param(
        [string]$Name,
        [int]$Retries = 6,
        [int]$DelayMs = 300
    )

    for ($i = 0; $i -lt $Retries; $i++) {
        Refresh-SessionPath
        if (Test-Command $Name) {
            return $true
        }
        Start-Sleep -Milliseconds $DelayMs
    }

    return $false
}

function Show-Usage {
    Write-Host "Usage: .\setup.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Install workshop prerequisites: Terraform, AWS CLI v2, kubectl, Helm, jq, git."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -CheckOnly, --check   Verify all tools are installed without installing anything"
    Write-Host "  -Help, -h, --help     Show this help message"
}

function Parse-Arguments {
    foreach ($arg in $ExtraArgs) {
        switch ($arg.ToLowerInvariant()) {
            "--check" { $script:CheckOnly = $true }
            "--help" { $script:Help = $true }
            "-h" { $script:Help = $true }
            default {
                Write-Err "Unknown option: $arg"
                Show-Usage
                exit 1
            }
        }
    }
}

function Get-NormalizedVersion {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    $normalized = $Version.Trim()
    $normalized = $normalized -replace '^[vV]', ''
    $normalized = ($normalized -split '[-+]')[0]

    try {
        return [Version]$normalized
    } catch {
        return $null
    }
}

function Test-VersionGte {
    param(
        [string]$Have,
        [string]$Need
    )

    $haveVersion = Get-NormalizedVersion $Have
    $needVersion = Get-NormalizedVersion $Need
    if ($null -eq $haveVersion -or $null -eq $needVersion) {
        return $false
    }
    return $haveVersion -ge $needVersion
}

function Get-KubectlVersion {
    try {
        return (kubectl version --client -o json 2>$null | ConvertFrom-Json).clientVersion.gitVersion
    } catch {
        return ""
    }
}

function Get-HelmVersion {
    try {
        return (helm version --short 2>$null) -replace '\+.*$',''
    } catch {
        return ""
    }
}

function Verify-Tool {
    param(
        [string]$Tool,
        [string]$Command,
        [string[]]$Arguments = @()
    )

    if (-not (Test-Command $Command)) {
        Write-Err "Verification failed: $Tool command is not available"
        return $false
    }

    try {
        $output = & $Command @Arguments 2>$null
        if ($?) {
            $line = ($output | Select-Object -First 1)
            Write-Ok "Verified: $Tool -> $line"
            return $true
        }
    } catch {
        # Intentionally handled below with a clear error.
    }

    Write-Err "Verification failed: $Command $($Arguments -join ' ')"
    return $false
}

function Test-Winget {
    if (-not (Test-Command "winget")) {
        Write-Err "winget is not available. Please install App Installer from the Microsoft Store."
        Write-Err "https://aka.ms/getwinget"
        exit 1
    }
}

# ------- installers -------

function Install-Terraform {
    if (Test-Command "terraform") {
        try {
            $versionJson = terraform version -json 2>$null | ConvertFrom-Json
            $current = $versionJson.terraform_version
        } catch {
            $current = "unknown"
        }
        if (Test-VersionGte $current $TerraformVersion) {
            Write-Ok "terraform $current already installed (>= $TerraformVersion)"
            $script:results["terraform"] = "ok ($current)"
            return
        }
        Write-Warn "terraform $current found but >= $TerraformVersion required"
        if ($CheckOnly) {
            $script:results["terraform"] = "TOO OLD ($current)"
            return
        }
    } elseif ($CheckOnly) {
        $script:results["terraform"] = "MISSING"
        return
    }

    Write-Info "Installing terraform $TerraformVersion..."
    $arch = if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
    } else { "386" }

    $zipFilename = "terraform_${TerraformVersion}_windows_${arch}.zip"
    $url = "https://releases.hashicorp.com/terraform/${TerraformVersion}/${zipFilename}"
    $checksumUrl = "https://releases.hashicorp.com/terraform/${TerraformVersion}/terraform_${TerraformVersion}_SHA256SUMS"
    $installDir = Join-Path $env:LOCALAPPDATA "Terraform"
    $zipPath = Join-Path $env:TEMP "terraform.zip"

    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

    # Verify SHA256 checksum
    try {
        $checksumContent = (Invoke-WebRequest -Uri $checksumUrl -UseBasicParsing).Content
        $expectedHash = ($checksumContent -split "`n" |
            Where-Object { $_ -match [regex]::Escape($zipFilename) } |
            ForEach-Object { ($_ -split "\s+")[0] } |
            Select-Object -First 1)
        if ($expectedHash) {
            $actualHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
            if ($actualHash -ne $expectedHash) {
                Write-Err "Checksum mismatch for $zipFilename"
                Write-Err "  expected: $expectedHash"
                Write-Err "  actual:   $actualHash"
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                $script:results["terraform"] = "FAILED (checksum)"
                return
            }
            Write-Info "Checksum verified for $zipFilename"
        }
    } catch {
        Write-Warn "Could not verify checksum - continuing without verification"
    }

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $installDir -Force
    Remove-Item $zipPath -Force

    # Add to user PATH if not already present
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$installDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$installDir;$userPath", "User")
        $env:Path = "$installDir;$env:Path"
        Write-Warn "Added $installDir to user PATH."
    }

    $installedVersion = ""
    try {
        $installedVersion = (terraform version -json 2>$null | ConvertFrom-Json).terraform_version
    } catch {
        $installedVersion = "unknown"
    }

    if (-not (Test-VersionGte $installedVersion $TerraformVersion)) {
        Write-Err "terraform verification failed: expected >= $TerraformVersion, got $installedVersion"
        $script:results["terraform"] = "FAILED (verify)"
        return
    }

    Write-Ok "terraform $installedVersion installed to $installDir"
    $script:results["terraform"] = "installed ($installedVersion)"
}

function Install-AwsCli {
    if (Test-Command "aws") {
        $ver = (aws --version 2>&1) -split " " | Select-Object -First 1
        Write-Ok "aws CLI already installed ($ver)"
        $script:results["aws-cli"] = "ok"
        return
    } elseif ($CheckOnly) {
        $script:results["aws-cli"] = "MISSING"
        return
    }
    Write-Info "Installing AWS CLI v2 via winget..."
    winget install --id Amazon.AWSCLI --accept-source-agreements --accept-package-agreements --silent
    if (-not (Wait-ForCommand "aws")) {
        Write-Err "Verification failed: aws command is not available (restart shell and retry)"
        $script:results["aws-cli"] = "FAILED (verify)"
        return
    }

    if (-not (Verify-Tool "aws-cli" "aws" @("--version"))) {
        $script:results["aws-cli"] = "FAILED (verify)"
        return
    }

    Write-Ok "AWS CLI v2 installed (restart shell to use)"
    $script:results["aws-cli"] = "installed"
}

function Install-Kubectl {
    if (Test-Command "kubectl") {
        $kv = Get-KubectlVersion
        if (Test-VersionGte $kv $KubectlMinimumVersion) {
            Write-Ok "kubectl $kv already installed (>= $KubectlMinimumVersion)"
            $script:results["kubectl"] = "ok ($kv)"
            return
        }
        Write-Warn "kubectl $kv found but >= $KubectlMinimumVersion required"
        if ($CheckOnly) {
            $script:results["kubectl"] = "TOO OLD ($kv)"
            return
        }
    } elseif ($CheckOnly) {
        $script:results["kubectl"] = "MISSING"
        return
    }
    Write-Info "Installing kubectl via winget..."
    winget install --id Kubernetes.kubectl --accept-source-agreements --accept-package-agreements --silent
    if (-not (Wait-ForCommand "kubectl")) {
        Write-Err "kubectl verification failed: command is not available (restart shell and retry)"
        $script:results["kubectl"] = "FAILED (verify)"
        return
    }

    $installed = Get-KubectlVersion
    if (-not (Test-VersionGte $installed $KubectlMinimumVersion)) {
        Write-Err "kubectl verification failed: expected >= $KubectlMinimumVersion, got $installed"
        $script:results["kubectl"] = "FAILED (verify)"
        return
    }

    Write-Ok "kubectl installed (restart shell to use)"
    $script:results["kubectl"] = "installed ($installed)"
}

function Install-Helm {
    if (Test-Command "helm") {
        $hv = Get-HelmVersion
        if (Test-VersionGte $hv $HelmMinimumVersion) {
            Write-Ok "helm $hv already installed (>= $HelmMinimumVersion)"
            $script:results["helm"] = "ok ($hv)"
            return
        }
        Write-Warn "helm $hv found but >= $HelmMinimumVersion required"
        if ($CheckOnly) {
            $script:results["helm"] = "TOO OLD ($hv)"
            return
        }
    } elseif ($CheckOnly) {
        $script:results["helm"] = "MISSING"
        return
    }
    Write-Info "Installing Helm via winget..."
    winget install --id Helm.Helm --accept-source-agreements --accept-package-agreements --silent
    if (-not (Wait-ForCommand "helm")) {
        Write-Err "helm verification failed: command is not available (restart shell and retry)"
        $script:results["helm"] = "FAILED (verify)"
        return
    }

    $installed = Get-HelmVersion
    if (-not (Test-VersionGte $installed $HelmMinimumVersion)) {
        Write-Err "helm verification failed: expected >= $HelmMinimumVersion, got $installed"
        $script:results["helm"] = "FAILED (verify)"
        return
    }

    Write-Ok "helm installed (restart shell to use)"
    $script:results["helm"] = "installed ($installed)"
}

function Install-Jq {
    if (Test-Command "jq") {
        $jv = (jq --version 2>$null)
        Write-Ok "jq already installed ($jv)"
        $script:results["jq"] = "ok"
        return
    } elseif ($CheckOnly) {
        $script:results["jq"] = "MISSING"
        return
    }
    Write-Info "Installing jq via winget..."
    winget install --id jqlang.jq --accept-source-agreements --accept-package-agreements --silent
    if (-not (Wait-ForCommand "jq")) {
        Write-Err "Verification failed: jq command is not available (restart shell and retry)"
        $script:results["jq"] = "FAILED (verify)"
        return
    }

    if (-not (Verify-Tool "jq" "jq" @("--version"))) {
        $script:results["jq"] = "FAILED (verify)"
        return
    }

    Write-Ok "jq installed (restart shell to use)"
    $script:results["jq"] = "installed"
}

function Install-Git {
    if (Test-Command "git") {
        $gv = (git --version 2>$null)
        Write-Ok "git already installed ($gv)"
        $script:results["git"] = "ok"
        return
    } elseif ($CheckOnly) {
        $script:results["git"] = "MISSING"
        return
    }
    Write-Info "Installing git via winget..."
    winget install --id Git.Git --accept-source-agreements --accept-package-agreements --silent
    if (-not (Wait-ForCommand "git")) {
        Write-Err "Verification failed: git command is not available (restart shell and retry)"
        $script:results["git"] = "FAILED (verify)"
        return
    }

    if (-not (Verify-Tool "git" "git" @("--version"))) {
        $script:results["git"] = "FAILED (verify)"
        return
    }

    Write-Ok "git installed (restart shell to use)"
    $script:results["git"] = "installed"
}

# ------- summary -------

function Show-Summary {
    $tools = @("terraform", "aws-cli", "kubectl", "helm", "jq", "git")
    $hasFailed = $false
    $hasMissing = $false

    Write-Host ""
    Write-Host "============================================"
    if ($CheckOnly) {
        Write-Host "  Readiness Check"
    } else {
        Write-Host "  Installation Summary"
    }
    Write-Host "============================================"
    Write-Host ("  {0,-14} {1}" -f "Tool", "Status")
    Write-Host "  ------------  --------------------------"
    foreach ($tool in $tools) {
        $status = if ($script:results.ContainsKey($tool)) { $script:results[$tool] } else { "unknown" }
        Write-Host ("  {0,-14} {1}" -f $tool, $status)

        if ($status -like "FAILED*") {
            $hasFailed = $true
        }
        if ($status -eq "MISSING" -or $status -like "TOO OLD*") {
            $hasMissing = $true
        }
    }
    Write-Host "============================================"
    Write-Host ""

    if ($CheckOnly) {
        if ($hasMissing) {
            Write-Warn "Some tools are missing or wrong version. Run without --check to install."
            exit 1
        }

        Write-Ok "All tools ready. You're good to go!"
        return
    }

    if ($hasFailed) {
        Write-Warn "Some tools failed to install. Please check the errors above."
        exit 1
    }

    Write-Ok "All tools installed and verified."
}

# ------- main -------

Parse-Arguments

if ($Help) {
    Show-Usage
    exit 0
}

Write-Host ""
Write-Host "============================================"
Write-Host "  AWS Community Day Romania 2026"
Write-Host "  Workshop Prerequisites Setup"
if ($CheckOnly) {
    Write-Host "  Mode: CHECK ONLY (no changes)"
}
Write-Host "============================================"
Write-Host ""

if (-not $CheckOnly) {
    Test-Winget
}

Install-Terraform
Install-AwsCli
Install-Kubectl
Install-Helm
Install-Jq
Install-Git

Show-Summary
