// Case Study 3 - Step 3: Core Application Infrastructure (VMs, LB, Storage)
// ARM-equivalent Bicep template for rapid DR deployment

@description('Azure region')
param location string = resourceGroup().location

@description('Environment name')
param environment string = 'prod'

@description('Subnet ID for web tier VMs')
param subnetWebId string

@description('Subnet ID for app tier VMs')
param subnetAppId string

@description('Admin username for VMs')
param adminUsername string = 'azureadmin'

@description('Admin password for VMs (use Key Vault in production)')
@secure()
param adminPassword string

@description('VM size for web and app tier')
@allowed(['Standard_B2ms', 'Standard_B1ms', 'Standard_B4ms', 'Standard_D2_v3', 'Standard_DS1_v2', 'Standard_B2s'])
param vmSize string = 'Standard_B2s'

@description('Storage account SKU')
@allowed(['Standard_LRS', 'Premium_LRS'])
param storageSkuName string = 'Standard_LRS'

// ─── Variables ────────────────────────────────────────────────────────────────

var prefix = 'cloudinn-${environment}'
var webVmName = 'vm-web-${environment}'
var appVmName = 'vm-app-${environment}'
var storageAccountName = 'stcloudinn${uniqueString(resourceGroup().id)}'
var lbName = 'lb-web-${environment}'
var lbPipName = 'pip-lb-${environment}'

// ─── Storage Account ──────────────────────────────────────────────────────────

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: storageSkuName
  }
  tags: {
    environment: environment
    purpose: 'disaster-recovery'
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    encryption: {
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource appDataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'app-data'
  properties: {
    publicAccess: 'None'
  }
}

// ─── Load Balancer ────────────────────────────────────────────────────────────

resource lbPip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: lbPipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${prefix}-lb'
    }
  }
}

resource lb 'Microsoft.Network/loadBalancers@2023-04-01' = {
  name: lbName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'frontend'
        properties: {
          publicIPAddress: {
            id: lbPip.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'web-backend-pool'
      }
    ]
    probes: [
      {
        name: 'http-probe'
        properties: {
          protocol: 'Http'
          port: 80
          requestPath: '/health'
          intervalInSeconds: 15
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'http-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'web-backend-pool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'http-probe')
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
        }
      }
    ]
  }
}

// ─── Web Tier VM ──────────────────────────────────────────────────────────────

resource webVmNic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: 'nic-${webVmName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig-web'
        properties: {
          subnet: {
            id: subnetWebId
          }
          privateIPAllocationMethod: 'Dynamic'
          loadBalancerBackendAddressPools: [
            {
              id: '${lb.id}/backendAddressPools/web-backend-pool'
            }
          ]
        }
      }
    ]
  }
}

resource webVm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: webVmName
  location: location
  tags: {
    tier: 'web'
    environment: environment
    role: 'disaster-recovery'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: webVmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: webVmNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// Nginx install via custom script extension
resource webVmExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  parent: webVm
  name: 'install-nginx'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      script: base64(format('''#!/bin/bash
set -e

REGION="{0}"
HOSTNAME=$(hostname)

# Wait for any existing apt/dpkg locks (unattended-upgrades on first boot)
for i in $(seq 1 30); do
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
     fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    echo "Waiting for apt lock to release... attempt $i/30"
    sleep 10
  else
    break
  fi
done

apt-get update -y
apt-get install -y -o DPkg::Lock::Timeout=120 nginx

cat > /etc/nginx/sites-available/default << NGINX
server {{
    listen 80;
    server_name _;
    location /health {{
        return 200 "healthy | region=$REGION | host=$HOSTNAME\\n";
        add_header Content-Type text/plain;
    }}
    location / {{
        default_type text/html;
        return 200 '<!DOCTYPE html>
<html><head><title>CloudInnovate - $REGION</title>
<style>
  body {{ font-family: sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: linear-gradient(135deg, #0078d4, #005a9e); color: #fff; }}
  .card {{ background: rgba(255,255,255,0.1); backdrop-filter: blur(10px); padding: 3rem; border-radius: 1rem; text-align: center; max-width: 500px; }}
  h1 {{ margin: 0 0 1rem; font-size: 2rem; }}
  .region {{ font-size: 1.5rem; background: #ffb900; color: #1a1a1a; padding: 0.5rem 1.5rem; border-radius: 2rem; display: inline-block; margin: 1rem 0; font-weight: bold; }}
  .meta {{ opacity: 0.85; margin-top: 1rem; line-height: 1.8; }}
</style></head>
<body><div class="card">
  <h1>CloudInnovate</h1>
  <div class="region">$REGION</div>
  <div class="meta">
    <div>Host: $HOSTNAME</div>
    <div>Served at: $$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)</div>
  </div>
</div></body></html>';
    }}
}}
NGINX
systemctl enable nginx
systemctl restart nginx
''', location))
    }
  }
}

// ─── App Tier VM ──────────────────────────────────────────────────────────────

resource appVmNic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: 'nic-${appVmName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig-app'
        properties: {
          subnet: {
            id: subnetAppId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.2.4'
        }
      }
    ]
  }
}

resource appVm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: appVmName
  location: location
  tags: {
    tier: 'app'
    environment: environment
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: appVmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: appVmNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output lbPublicIpId string = lbPip.id
output lbPublicIp string = lbPip.properties.ipAddress
output lbPublicFqdn string = lbPip.properties.dnsSettings.fqdn
output webVmName string = webVm.name
output appVmName string = appVm.name
