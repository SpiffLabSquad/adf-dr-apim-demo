targetScope = 'resourceGroup'

// ===========================================================================
// ADF cross-region DR demo:
//   Autosys -> Traffic Manager -> APIM (region A/B) -> Data Factory (region A/B)
// Everything lands in a single resource group for trivial teardown.
// ===========================================================================

@description('Primary Azure region (active).')
param primaryRegion string = 'eastus2'

@description('Secondary Azure region (passive / failover).')
param secondaryRegion string = 'westus2'

@description('Base token used to derive resource names.')
param baseName string = 'adfdr'

@description('Suffix appended to globally-unique names (APIM, Traffic Manager DNS).')
param nameSuffix string = uniqueString(resourceGroup().id)

@description('Publisher email for the APIM instances.')
param publisherEmail string

@description('Publisher (organization) name for the APIM instances.')
param publisherName string = 'ADF DR Demo'

@description('Demo pipeline name created in each factory.')
param pipelineName string = 'DemoPipeline'

// Built-in role: Data Factory Contributor (lets the APIM identity call createRun).
var dataFactoryContributorRoleId = '673868aa-7521-48a0-acc6-0f60742d39f5'

var primaryFactoryName = 'adf-${baseName}-pri-${nameSuffix}'
var secondaryFactoryName = 'adf-${baseName}-sec-${nameSuffix}'
var primaryApimName = 'apim-${baseName}-pri-${nameSuffix}'
var secondaryApimName = 'apim-${baseName}-sec-${nameSuffix}'
var tmProfileName = 'tm-${baseName}-${nameSuffix}'
var tmDnsName = '${baseName}-${nameSuffix}'

// --- Data Factories (one per region) ---
module adfPrimary 'modules/dataFactory.bicep' = {
  name: 'adfPrimary'
  params: {
    factoryName: primaryFactoryName
    location: primaryRegion
    pipelineName: pipelineName
  }
}

module adfSecondary 'modules/dataFactory.bicep' = {
  name: 'adfSecondary'
  params: {
    factoryName: secondaryFactoryName
    location: secondaryRegion
    pipelineName: pipelineName
  }
}

// --- APIM gateways (one per region), each fronting its regional factory ---
module apimPrimary 'modules/apim.bicep' = {
  name: 'apimPrimary'
  params: {
    apimName: primaryApimName
    location: primaryRegion
    publisherEmail: publisherEmail
    publisherName: publisherName
    regionLabel: primaryRegion
    factoryName: primaryFactoryName
  }
  dependsOn: [
    adfPrimary
  ]
}

module apimSecondary 'modules/apim.bicep' = {
  name: 'apimSecondary'
  params: {
    apimName: secondaryApimName
    location: secondaryRegion
    publisherEmail: publisherEmail
    publisherName: publisherName
    regionLabel: secondaryRegion
    factoryName: secondaryFactoryName
  }
  dependsOn: [
    adfSecondary
  ]
}

// --- Grant each APIM managed identity rights to trigger its regional factory ---
resource adfPri 'Microsoft.DataFactory/factories@2018-06-01' existing = {
  name: primaryFactoryName
}

resource adfSec 'Microsoft.DataFactory/factories@2018-06-01' existing = {
  name: secondaryFactoryName
}

resource raPrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(adfPri.id, primaryApimName, dataFactoryContributorRoleId)
  scope: adfPri
  properties: {
    principalId: apimPrimary.outputs.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataFactoryContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource raSecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(adfSec.id, secondaryApimName, dataFactoryContributorRoleId)
  scope: adfSec
  properties: {
    principalId: apimSecondary.outputs.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataFactoryContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

// --- Traffic Manager: one stable hostname, priority failover across the two gateways ---
module trafficManager 'modules/trafficManager.bicep' = {
  name: 'trafficManager'
  params: {
    tmProfileName: tmProfileName
    tmDnsName: tmDnsName
    primaryApimHost: apimPrimary.outputs.gatewayHost
    secondaryApimHost: apimSecondary.outputs.gatewayHost
    primaryRegion: primaryRegion
    secondaryRegion: secondaryRegion
    healthPath: '/adf/health'
  }
}

output resourceGroupName string = resourceGroup().name
output trafficManagerProfile string = tmProfileName
output trafficManagerFqdn string = trafficManager.outputs.profileFqdn
output primaryApimName string = primaryApimName
output secondaryApimName string = secondaryApimName
output primaryApimHost string = apimPrimary.outputs.gatewayHost
output secondaryApimHost string = apimSecondary.outputs.gatewayHost
output primaryFactoryName string = primaryFactoryName
output secondaryFactoryName string = secondaryFactoryName
output pipelineName string = pipelineName
output triggerUrlViaTrafficManager string = 'https://${trafficManager.outputs.profileFqdn}/adf/trigger/${pipelineName}'
output healthUrlViaTrafficManager string = 'https://${trafficManager.outputs.profileFqdn}/adf/health'
