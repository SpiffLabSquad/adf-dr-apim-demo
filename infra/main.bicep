targetScope = 'resourceGroup'

// ===========================================================================
// ADF cross-region DR — APIM active-region routing.
//
//   Autosys -> APIM  POST /adf/trigger/{pipeline}
//                      routes to the ADF factory in the region that is
//                      currently active, with automatic fallback.
//
// One APIM, two Data Factories, all in a single resource group.
// ===========================================================================

@description('Primary Azure region (default active).')
param primaryRegion string = 'eastus2'

@description('Secondary Azure region (standby).')
param secondaryRegion string = 'westus2'

@description('Region that hosts the single APIM gateway.')
param apimRegion string = primaryRegion

@description('Base token used to derive resource names.')
param baseName string = 'adfdr'

@description('Suffix appended to globally-unique names (APIM).')
param nameSuffix string = uniqueString(resourceGroup().id)

@description('Publisher email for the APIM instance.')
param publisherEmail string

@description('Publisher (organization) name for the APIM instance.')
param publisherName string = 'ADF DR Demo'

@description('Demo pipeline name created in each factory.')
param pipelineName string = 'DemoPipeline'

// Built-in role: Data Factory Contributor (lets the APIM identity call createRun).
var dataFactoryContributorRoleId = '673868aa-7521-48a0-acc6-0f60742d39f5'

var primaryFactoryName = 'adf-${baseName}-pri-${nameSuffix}'
var secondaryFactoryName = 'adf-${baseName}-sec-${nameSuffix}'
var apimName = 'apim-${baseName}-pri-${nameSuffix}'

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

// --- Single APIM gateway that routes to the active region ---
module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    apimName: apimName
    location: apimRegion
    publisherEmail: publisherEmail
    publisherName: publisherName
    primaryFactoryName: primaryFactoryName
    secondaryFactoryName: secondaryFactoryName
    defaultActiveRegion: 'primary'
  }
  dependsOn: [
    adfPrimary
    adfSecondary
  ]
}

// --- Grant the APIM managed identity rights to trigger BOTH factories ---
resource adfPri 'Microsoft.DataFactory/factories@2018-06-01' existing = {
  name: primaryFactoryName
}

resource adfSec 'Microsoft.DataFactory/factories@2018-06-01' existing = {
  name: secondaryFactoryName
}

resource raApimPrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(adfPri.id, apimName, dataFactoryContributorRoleId)
  scope: adfPri
  properties: {
    principalId: apim.outputs.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataFactoryContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource raApimSecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(adfSec.id, apimName, dataFactoryContributorRoleId)
  scope: adfSec
  properties: {
    principalId: apim.outputs.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataFactoryContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

output resourceGroupName string = resourceGroup().name
output apimName string = apimName
output apimHost string = apim.outputs.gatewayHost
output primaryFactoryName string = primaryFactoryName
output secondaryFactoryName string = secondaryFactoryName
output pipelineName string = pipelineName
output activeRegionNamedValue string = 'active-region'
output triggerUrl string = 'https://${apim.outputs.gatewayHost}/adf/trigger/${pipelineName}'
