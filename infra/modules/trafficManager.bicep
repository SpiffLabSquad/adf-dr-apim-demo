@description('Traffic Manager profile name.')
param tmProfileName string

@description('Relative DNS name -> {tmDnsName}.trafficmanager.net (must be globally unique).')
param tmDnsName string

@description('Primary APIM gateway host, e.g. apim-pri.azure-api.net.')
param primaryApimHost string

@description('Secondary APIM gateway host, e.g. apim-sec.azure-api.net.')
param secondaryApimHost string

@description('Primary region label (used for endpoint geo metadata).')
param primaryRegion string

@description('Secondary region label (used for endpoint geo metadata).')
param secondaryRegion string

@description('HTTPS path Traffic Manager probes for endpoint health.')
param healthPath string = '/adf/health'

resource tm 'Microsoft.Network/trafficmanagerprofiles@2022-04-01-preview' = {
  name: tmProfileName
  location: 'global'
  properties: {
    profileStatus: 'Enabled'
    // Priority = active/passive failover: always prefer primary, fail over to secondary.
    trafficRoutingMethod: 'Priority'
    dnsConfig: {
      relativeName: tmDnsName
      ttl: 30
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: healthPath
      intervalInSeconds: 30
      timeoutInSeconds: 10
      toleratedNumberOfFailures: 3
    }
    endpoints: [
      {
        name: 'primary'
        type: 'Microsoft.Network/trafficmanagerprofiles/externalEndpoints'
        properties: {
          target: primaryApimHost
          endpointStatus: 'Enabled'
          priority: 1
          endpointLocation: primaryRegion
        }
      }
      {
        name: 'secondary'
        type: 'Microsoft.Network/trafficmanagerprofiles/externalEndpoints'
        properties: {
          target: secondaryApimHost
          endpointStatus: 'Enabled'
          priority: 2
          endpointLocation: secondaryRegion
        }
      }
    ]
  }
}

output profileName string = tm.name
output profileFqdn string = tm.properties.dnsConfig.fqdn
