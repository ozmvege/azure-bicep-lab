metadata description = '''
A maintenance jumpbox with no public IP and no password.

This is the Azure answer to the question the OCI build had to answer too: how does a human
reach a machine for maintenance without putting it on the internet. Bastion brokers the
session, the NSG only accepts connections from the Bastion subnet, and the VM authenticates
with a key that lives on the operator's laptop.
'''

param name string
param location string
param tags object

@description('Subnet in the hub. No public IP is attached to this NIC — by design.')
param subnetId string

@description('Small and burstable. This box exists to run nslookup and psql, not workloads.')
param vmSize string = 'Standard_B2s'

param adminUsername string = 'azureops'

@description('''
The public half of an SSH key pair — not a secret, which is exactly why password
authentication is disabled below. Generate one with: ssh-keygen -t ed25519 -C jumpbox
''')
param sshPublicKey string

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${name}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource jumpbox 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

output id string = jumpbox.id
output principalId string = jumpbox.identity.principalId
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
