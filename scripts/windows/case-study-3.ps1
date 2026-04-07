#Requires -Version 5.1
# ============================================================
# Case Study 3: Azure Dual-Region Disaster Recovery
# Primary: East US  |  DR Standby: East US 2
# Windows PowerShell Version
# ============================================================

Set-StrictMode = Version Latest


# ── Helpers ──────────────────────────────────────────────────
function Write-Header {param($msg)}
    Write-Host ""
    Write-Host "═══════════════════════════════════════" -ForegroundColor Blue
    Write-Host "  $msg" -ForegroundColor Blue
    Write-Host "═══════════════════════════════════════" -ForegroundColor Blue
}
function Write-Step { param($msg) Write-Host "[STEP] $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "[  OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Pause-ForContinue { Write-Host "Press ENTER to continue..." -ForegroundColor Yellow; Read-Host | Out-Null }

# ── Configuration ─────────────────────────────────────────────
$LocationPrimary    = "eastus"
$LocationDr         = "eastus2"
$Environment        = "prod"
$CompanyPrefix      = "cloudinn"
$RgPrimary          = "rg-$CompanyPrefix-primary-$Environment"
$RgDr               = "rg-$CompanyPrefix-dr-$Environment"
$VnetName           = "$CompanyPrefix-vnet-$Environment"
$LbPipName          = "pip-lb-$Environment"
$TmProfileName      = "tm-$CompanyPrefix-dr"
$LabDir             = Join-Path (Split-Path $PSScriptRoot -Parent) "labs\case-study-3-dr"

# ── Pre-flight checks ─────────────────────────────────────────
function Invoke-Preflight {
    Write-Header "Pre-flight Checks"
    try {
        $ctx = Get-AzContext
        if ($null -eq $ctx) { throw "Not logged in" }
        Write-Ok "Subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
    }
    catch {
        Write-Step "Logging in..."
        Connect-AzAccount
    }
    Write-Step "Verifying Azure CLI login..."
    az account show --output table 2>$null
    if ($LASTEXITCODE -ne 0) { az login }
    Write-Step "Verifying Bicep..."
    az bicep version | Out-Null
    if ($LASTEXITCODE -ne 0) { az bicep install }
    Write-Ok "Pre-flight checks passed"
}

# ── Step 1: Create Resource Groups ───────────────────────────
function New-LabResourceGroups {
    Write-Header "Step 1: Create Resource Groups"

    Write-Step "Creating PRIMARY: $RgPrimary ($LocationPrimary)..."
    New-AzResourceGroup -Name $RgPrimary -Location $LocationPrimary `
        -Tag @{ environment = $Environment; role = "primary"; purpose = "disaster-recovery" } `
        -Force | Out-Null
    Write-Ok "$RgPrimary created"

    Write-Step "Creating DR: $RgDr ($LocationDr)..."
    New-AzResourceGroup -Name $RgDr -Location $LocationDr `
        -Tag @{ environment = $Environment; role = "dr-standby"; purpose = "disaster-recovery" } `
        -Force | Out-Null
    Write-Ok "$RgDr created"
}

# ── Step 2a: Deploy PRIMARY VNet (East US) ────────────────────
function Deploy-PrimaryVNet {
    Write-Header "Step 2a: Deploy PRIMARY VNet & NSGs (East US)"
    Write-Host "  Region: $LocationPrimary  |  Address Space: 10.0.0.0/16" -ForegroundColor Gray

    $deployName = "deploy-vnet-primary-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-AzResourceGroupDeployment `
        -ResourceGroupName $RgPrimary `
        -Name $deployName `
        -TemplateFile "$LabDir\01-vnet\main.bicep" `
        -location $LocationPrimary `
        -environment $Environment `
        -companyPrefix $CompanyPrefix

    $vnet = Get-AzVirtualNetwork -ResourceGroupName $RgPrimary -Name $VnetName
    Write-Ok "Primary VNet deployed: $($vnet.Id)"
    return $vnet
}

# ── Step 2b: Deploy DR VNet (East US 2) ──────────────────────
function Deploy-DrVNet {
    Write-Header "Step 2b: Deploy DR VNet & NSGs (East US 2)"
    Write-Host "  Region: $LocationDr  |  Same subnet layout as primary" -ForegroundColor Gray

    $deployName = "deploy-vnet-dr-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-AzResourceGroupDeployment `
        -ResourceGroupName $RgDr `
        -Name $deployName `
        -TemplateFile "$LabDir\01-vnet\main.bicep" `
        -location $LocationDr `
        -environment $Environment `
        -companyPrefix $CompanyPrefix

    $vnet = Get-AzVirtualNetwork -ResourceGroupName $RgDr -Name $VnetName
    Write-Ok "DR VNet deployed: $($vnet.Id)"
    return $vnet
}

# ── Step 3: Deploy DNS Zones ──────────────────────────────────
function Deploy-DnsZones {
    param([string]$PrimaryVNetId)

    Write-Header "Step 3: Configure Azure DNS Zones"
    Write-Step "Public zone: $CompanyPrefix-app.example.com"
    Write-Step "Private zone: internal.$CompanyPrefix.azure (linked to primary VNet)"
    Write-Warn "After deployment, update NS records at your domain registrar."

    $deployName = "deploy-dns-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-AzResourceGroupDeployment `
        -ResourceGroupName $RgPrimary `
        -Name $deployName `
        -TemplateFile "$LabDir\02-dns\main.bicep" `
        -TemplateParameterFile "$LabDir\02-dns\parameters.json" `
        -vnetId $PrimaryVNetId `
        -publicDnsZoneName "$CompanyPrefix-app.example.com" `
        -privateDnsZoneName "internal.$CompanyPrefix.azure"

    Write-Step "Azure DNS Name Servers (add to registrar):"
    $zone = Get-AzDnsZone -ResourceGroupName $RgPrimary -Name "$CompanyPrefix-app.example.com"
    $zone.NameServers | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Ok "DNS zones deployed"
}

# ── Internal helper: get subnet IDs from a VNet ──────────────
function Get-SubnetIds {
    param([Microsoft.Azure.Commands.Network.Models.PSVirtualNetwork]$VNet)
    return @{
        Web = ($VNet.Subnets | Where-Object { $_.Name -eq "subnet-web" })[0].Id
        App = ($VNet.Subnets | Where-Object { $_.Name -eq "subnet-app" })[0].Id
        Db  = ($VNet.Subnets | Where-Object { $_.Name -eq "subnet-db"  })[0].Id
    }
}

# ── Internal helper: deploy infra into a resource group ──────
function Deploy-InfraStack {
    param(
        [string]$ResourceGroup,
        [string]$Location,
        [hashtable]$SubnetIds,
        [string]$Role
    )

    $vmPassword = ConvertTo-SecureString "AzureDR@Training2024!" -AsPlainText -Force
    Write-Warn "Using demo password. Use Azure Key Vault in production."

    $deployName = "deploy-infra-$Role-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-AzResourceGroupDeployment `
        -ResourceGroupName $ResourceGroup `
        -Name $deployName `
        -TemplateFile "$LabDir\03-arm-templates\main.bicep" `
        -location $Location `
        -subnetWebId $SubnetIds.Web `
        -subnetAppId $SubnetIds.App `
        -adminPassword $vmPassword

    return Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $LbPipName
}

# ── Step 4a: Deploy PRIMARY Infrastructure ────────────────────
function Deploy-PrimaryInfra {
    param([Microsoft.Azure.Commands.Network.Models.PSVirtualNetwork]$VNet)

    Write-Header "Step 4a: Deploy PRIMARY App Infrastructure (East US)"
    Write-Host "  Load Balancer + Web VM (Nginx) + App VM + Storage" -ForegroundColor Gray

    $subnets = Get-SubnetIds -VNet $VNet
    $pip = Deploy-InfraStack -ResourceGroup $RgPrimary -Location $LocationPrimary -SubnetIds $subnets -Role "primary"
    Write-Ok "Primary infrastructure deployed. LB IP: $($pip.IpAddress)"
    return $pip
}

# ── Step 4b: Deploy DR Infrastructure ────────────────────────
function Deploy-DrInfra {
    param([Microsoft.Azure.Commands.Network.Models.PSVirtualNetwork]$VNet)

    Write-Header "Step 4b: Deploy DR App Infrastructure (East US 2)"
    Write-Host "  Identical stack — kept on standby in East US 2" -ForegroundColor Gray

    $subnets = Get-SubnetIds -VNet $VNet
    $pip = Deploy-InfraStack -ResourceGroup $RgDr -Location $LocationDr -SubnetIds $subnets -Role "dr"
    Write-Ok "DR infrastructure deployed. LB IP: $($pip.IpAddress)"
    return $pip
}

# ── Step 5: Deploy Traffic Manager ───────────────────────────
function Deploy-TrafficManager {
    param(
        [Microsoft.Azure.Commands.Network.Models.PSPublicIpAddress]$PrimaryPip,
        [Microsoft.Azure.Commands.Network.Models.PSPublicIpAddress]$DrPip
    )

    Write-Header "Step 5: Deploy Azure Traffic Manager"
    Write-Host ""
    Write-Host "  Priority 1: East US  (primary) — $($PrimaryPip.IpAddress)" -ForegroundColor Gray
    Write-Host "  Priority 2: East US 2 (DR)     — $($DrPip.IpAddress)"     -ForegroundColor Gray
    Write-Host "  TTL: 30s  |  Probe: HTTPS /health every 10s"               -ForegroundColor Gray
    Write-Host ""

    $deployName = "deploy-tm-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-AzResourceGroupDeployment `
        -ResourceGroupName $RgPrimary `
        -Name $deployName `
        -TemplateFile "$LabDir\04-traffic-manager\main.bicep" `
        -companyPrefix $CompanyPrefix `
        -primaryPublicIpId $PrimaryPip.Id `
        -drPublicIpId $DrPip.Id `
        -dnsTtl 30

    $tm = Get-AzTrafficManagerProfile -ResourceGroupName $RgPrimary -Name $TmProfileName
    Write-Ok "Traffic Manager deployed: $($tm.RelativeDnsName).trafficmanager.net"
    return $tm
}

# ── Step 6: Failover Test ─────────────────────────────────────
function Invoke-FailoverTest {
    param([Microsoft.Azure.Commands.TrafficManager.Models.PSTrafficManagerProfile]$TmProfile)

    Write-Header "Step 6: Failover Test — East US → East US 2"
    Write-Host ""
    Write-Host "  Simulates East US (primary) going offline." -ForegroundColor Gray
    Write-Host "  Traffic Manager auto-routes to East US 2 DR." -ForegroundColor Gray
    Write-Host ""
    Pause-ForContinue

    $tmFqdn = "$($TmProfile.RelativeDnsName).trafficmanager.net"

    Write-Step "BEFORE FAILOVER — expect East US (primary) IP:"
    Resolve-DnsName -Name $tmFqdn -ErrorAction SilentlyContinue | Select-Object Name, IPAddress

    Write-Step "Disabling East US primary endpoint (simulating outage)..."
    $ep = Get-AzTrafficManagerEndpoint `
        -Name "endpoint-eastus-primary" `
        -ProfileName $TmProfileName `
        -ResourceGroupName $RgPrimary `
        -Type AzureEndpoints
    $ep.EndpointStatus = "Disabled"
    Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep | Out-Null
    Write-Ok "East US endpoint disabled"

    Write-Step "Waiting 60 seconds for failover detection + DNS TTL..."
    for ($i = 60; $i -gt 0; $i--) {
        Write-Progress -Activity "Waiting for failover" `
            -Status "$i seconds remaining" `
            -PercentComplete ((60 - $i) / 60 * 100)
        Start-Sleep -Seconds 1
    }
    Write-Progress -Completed -Activity "Done"

    Write-Step "AFTER FAILOVER — expect East US 2 (DR) IP:"
    Resolve-DnsName -Name $tmFqdn -ErrorAction SilentlyContinue | Select-Object Name, IPAddress

    Write-Step "East US 2 DR endpoint health:"
    Get-AzTrafficManagerEndpoint `
        -Name "endpoint-eastus2-dr" `
        -ProfileName $TmProfileName `
        -ResourceGroupName $RgPrimary `
        -Type AzureEndpoints | Select-Object Name, EndpointMonitorStatus

    Pause-ForContinue

    Write-Step "Re-enabling East US primary (failback)..."
    $ep.EndpointStatus = "Enabled"
    Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep | Out-Null
    Write-Ok "East US re-enabled. Traffic fails back within ~60 seconds."

    Start-Sleep -Seconds 30
    Write-Step "DNS after failback (expect East US IP again):"
    Resolve-DnsName -Name $tmFqdn -ErrorAction SilentlyContinue | Select-Object Name, IPAddress

    Write-Ok "Failover test complete!"
}

# ── Verify Deployment ─────────────────────────────────────────
function Invoke-Verification {
    Write-Header "Deployment Verification"

    Write-Step "Resources in PRIMARY ($RgPrimary):"
    Get-AzResource -ResourceGroupName $RgPrimary |
        Select-Object Name, ResourceType, Location | Format-Table -AutoSize

    Write-Step "Resources in DR ($RgDr):"
    Get-AzResource -ResourceGroupName $RgDr |
        Select-Object Name, ResourceType, Location | Format-Table -AutoSize

    Write-Step "Traffic Manager endpoints:"
    $endpoints = @()
    foreach ($type in @("AzureEndpoints")) {
        $endpoints += Get-AzTrafficManagerEndpoint `
            -ProfileName $TmProfileName -ResourceGroupName $RgPrimary -Type $type `
            -ErrorAction SilentlyContinue
    }
    $endpoints | Select-Object Name, EndpointStatus, EndpointMonitorStatus | Format-Table -AutoSize

    Write-Step "Primary VNet subnets:"
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $RgPrimary -Name $VnetName
    $vnet.Subnets | Select-Object Name, AddressPrefix | Format-Table -AutoSize

    Write-Ok "Verification complete"
}

# ── Cleanup ───────────────────────────────────────────────────
function Remove-LabResources {
    Write-Header "Cleanup"
    Write-Warn "This will delete BOTH resource groups ($RgPrimary and $RgDr)!"
    $confirm = Read-Host "Type 'yes' to confirm"
    if ($confirm -eq "yes") {
        foreach ($rg in @($RgPrimary, $RgDr)) {
            if (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue) {
                Remove-AzResourceGroup -Name $rg -Force -AsJob
                Write-Ok "Deletion initiated: $rg"
            } else {
                Write-Warn "Skipping $rg (does not exist)"
            }
        }
    }
    else {
        Write-Ok "Cleanup cancelled"
    }
}

# ── Main Menu ─────────────────────────────────────────────────
function Show-Menu {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Blue
    Write-Host "║  Case Study 3: Azure Dual-Region DR Lab             ║" -ForegroundColor Blue
    Write-Host "║  Primary: East US  |  DR Standby: East US 2        ║" -ForegroundColor Blue
    Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Blue
    Write-Host "║  1) Run full deployment (all steps)                 ║" -ForegroundColor Blue
    Write-Host "║  2) Step 1:  Create Resource Groups                 ║" -ForegroundColor Blue
    Write-Host "║  3) Step 2a: Deploy PRIMARY VNet (East US)          ║" -ForegroundColor Blue
    Write-Host "║  4) Step 2b: Deploy DR VNet (East US 2)             ║" -ForegroundColor Blue
    Write-Host "║  5) Step 3:  Deploy DNS Zones                       ║" -ForegroundColor Blue
    Write-Host "║  6) Step 4a: Deploy PRIMARY Infrastructure          ║" -ForegroundColor Blue
    Write-Host "║  7) Step 4b: Deploy DR Infrastructure               ║" -ForegroundColor Blue
    Write-Host "║  8) Step 5:  Deploy Traffic Manager                 ║" -ForegroundColor Blue
    Write-Host "║  9) Step 6:  Run Failover Test                      ║" -ForegroundColor Blue
    Write-Host "║  V) Verify Deployment                               ║" -ForegroundColor Blue
    Write-Host "║  C) Cleanup (delete all resources)                  ║" -ForegroundColor Blue
    Write-Host "║  0) Exit                                            ║" -ForegroundColor Blue
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Blue
    return (Read-Host "Select option")
}

# ── Entry point ───────────────────────────────────────────────
Invoke-Preflight

$primaryVnet = $null
$drVnet      = $null
$primaryPip  = $null
$drPip       = $null
$tmProfile   = $null

while ($true) {
    $choice = Show-Menu
    switch ($choice) {
        "1" {
            New-LabResourceGroups
            $primaryVnet = Deploy-PrimaryVNet
            $drVnet      = Deploy-DrVNet
            Deploy-DnsZones -PrimaryVNetId $primaryVnet.Id
            $primaryPip  = Deploy-PrimaryInfra -VNet $primaryVnet
            $drPip       = Deploy-DrInfra      -VNet $drVnet
            $tmProfile   = Deploy-TrafficManager -PrimaryPip $primaryPip -DrPip $drPip
            Invoke-Verification
            Invoke-FailoverTest -TmProfile $tmProfile
        }
        "2" { New-LabResourceGroups }
        "3" { $primaryVnet = Deploy-PrimaryVNet }
        "4" { $drVnet = Deploy-DrVNet }
        "5" {
            if (-not $primaryVnet) {
                $primaryVnet = Get-AzVirtualNetwork -ResourceGroupName $RgPrimary -Name $VnetName -ErrorAction SilentlyContinue
            }
            if ($primaryVnet) { Deploy-DnsZones -PrimaryVNetId $primaryVnet.Id }
            else { Write-Warn "Deploy primary VNet first (option 3)" }
        }
        "6" {
            if (-not $primaryVnet) {
                $primaryVnet = Get-AzVirtualNetwork -ResourceGroupName $RgPrimary -Name $VnetName -ErrorAction SilentlyContinue
            }
            if ($primaryVnet) { $primaryPip = Deploy-PrimaryInfra -VNet $primaryVnet }
            else { Write-Warn "Deploy primary VNet first (option 3)" }
        }
        "7" {
            if (-not $drVnet) {
                $drVnet = Get-AzVirtualNetwork -ResourceGroupName $RgDr -Name $VnetName -ErrorAction SilentlyContinue
            }
            if ($drVnet) { $drPip = Deploy-DrInfra -VNet $drVnet }
            else { Write-Warn "Deploy DR VNet first (option 4)" }
        }
        "8" {
            if (-not $primaryPip) { $primaryPip = Get-AzPublicIpAddress -ResourceGroupName $RgPrimary -Name $LbPipName -ErrorAction SilentlyContinue }
            if (-not $drPip)      { $drPip      = Get-AzPublicIpAddress -ResourceGroupName $RgDr      -Name $LbPipName -ErrorAction SilentlyContinue }
            if ($primaryPip -and $drPip) { $tmProfile = Deploy-TrafficManager -PrimaryPip $primaryPip -DrPip $drPip }
            else { Write-Warn "Deploy both infrastructure stacks first (options 6 and 7)" }
        }
        "9" {
            if (-not $tmProfile) {
                $tmProfile = Get-AzTrafficManagerProfile -ResourceGroupName $RgPrimary -Name $TmProfileName -ErrorAction SilentlyContinue
            }
            if ($tmProfile) { Invoke-FailoverTest -TmProfile $tmProfile }
            else { Write-Warn "Deploy Traffic Manager first (option 8)" }
        }
        { $_ -in "V","v" } { Invoke-Verification }
        { $_ -in "C","c" } { Remove-LabResources }
        "0" { Write-Host "Exiting."; exit 0 }
        default { Write-Warn "Invalid option" }
    }
}
