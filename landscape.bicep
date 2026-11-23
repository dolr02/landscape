targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Base64 contents of the public P2S root certificate, without PEM delimiters.')
param p2sRootCertData string

@secure()
param f5AdminPassword string

@secure()
param backendAdminPassword string

var gatewaySubnetName = 'GatewaySubnet'
var hubName = 'vnet-hub-eus-01'
var spokeName = 'vnet-f5-lab'

resource hub 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: hubName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
        }
      }
      {
        name: 'snet-shared-services'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
      {
        name: gatewaySubnetName
        properties: {
          addressPrefix: '10.0.254.0/27'
        }
      }
    ]
  }
}

resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: hub
  name: gatewaySubnetName
}

resource vpnPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-vpn-gateway'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = {
  name: 'vpngw-landscape-eus-01'
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    activeActive: false
    enableBgp: false
    sku: {
      name: 'VpnGw2AZ'
      tier: 'VpnGw2AZ'
    }
    ipConfigurations: [
      {
        name: 'gw-ipconfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: vpnPublicIp.id
          }
          subnet: {
            id: gatewaySubnet.id
          }
        }
      }
    ]
    vpnClientConfiguration: {
      vpnClientAddressPool: {
        addressPrefixes: ['172.16.201.0/24']
      }
      vpnClientProtocols: ['IkeV2', 'OpenVPN']
      vpnAuthenticationTypes: ['Certificate']
      vpnClientRootCertificates: [
        {
          name: 'P2SRootCert'
          properties: {
            publicCertData: p2sRootCertData
          }
        }
      ]
    }
  }
}

module f5Network 'f5/vnet-subnets.bicep' = {
  name: 'landscape-f5-network'
  params: {
    location: location
  }
}

resource f5Vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: spokeName
}

resource hubToF5 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: hub
  name: 'peer-hub-to-f5'
  properties: {
    remoteVirtualNetwork: {
      id: f5Vnet.id
    }
    allowVirtualNetworkAccess: true
    allowGatewayTransit: true
  }
  dependsOn: [f5Network, vpnGateway]
}

resource f5ToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: f5Vnet
  name: 'peer-f5-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hub.id
    }
    allowVirtualNetworkAccess: true
    useRemoteGateways: true
  }
  dependsOn: [hubToF5]
}

module f5Nics 'f5/NIC.bicep' = {
  name: 'landscape-f5-nics'
  params: {
    location: location
  }
  dependsOn: [f5Network]
}

module bigIp 'f5/VM-F5-BIGIP.bicep' = {
  name: 'landscape-f5-bigip'
  params: {
    location: location
    adminPassword: f5AdminPassword
  }
  dependsOn: [f5Nics]
}

module backend 'f5/VM-F5-Backend.bicep' = {
  name: 'landscape-f5-backend'
  params: {
    location: location
    adminPassword: backendAdminPassword
  }
  dependsOn: [f5Nics]
}
