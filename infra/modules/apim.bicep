@description('APIM service name (must be globally unique).')
param apimName string

@description('Azure region for this APIM instance.')
param location string

@description('Publisher email for the APIM service.')
param publisherEmail string

@description('Publisher (organization) name for the APIM service.')
param publisherName string = 'ADF DR Demo'

@description('Human-readable region label surfaced back to callers in the X-Served-Region header, e.g. eastus2.')
param regionLabel string

@description('Name of the Data Factory (in this same resource group) that this gateway triggers.')
param factoryName string

var subId = subscription().subscriptionId
var rgName = resourceGroup().name

// --- APIM (Consumption tier) with a system-assigned managed identity ---
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: 'Consumption'
    capacity: 0
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// --- API: a thin, stable façade in front of the ADF control-plane REST API ---
resource api 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'adf-trigger'
  properties: {
    displayName: 'ADF Trigger'
    apiRevision: '1'
    path: 'adf'
    protocols: [
      'https'
    ]
    // Demo only: no subscription key so Autosys/curl/Traffic-Manager probes can call it directly.
    // In production, require a subscription key, client cert, or OAuth (see README > Security).
    subscriptionRequired: false
  }
}

// ---------------------------------------------------------------------------
// Trigger operation: POST /adf/trigger/{pipelineName}
// The policy uses APIM's managed identity to call the ADF createRun REST API,
// so the caller never handles Azure control-plane credentials.
// ---------------------------------------------------------------------------
var triggerPolicyTemplate = '''
<policies>
  <inbound>
    <base />
    <send-request mode="new" response-variable-name="adfResponse" timeout="30" ignore-error="false">
      <set-url>@("https://management.azure.com/subscriptions/__SUB__/resourceGroups/__RG__/providers/Microsoft.DataFactory/factories/__FACTORY__/pipelines/" + context.Request.MatchedParameters["pipelineName"] + "/createRun?api-version=2018-06-01")</set-url>
      <set-method>POST</set-method>
      <authentication-managed-identity resource="https://management.azure.com/" />
      <set-header name="Content-Type" exists-action="override">
        <value>application/json</value>
      </set-header>
      <set-body>{}</set-body>
    </send-request>
    <return-response>
      <set-status code="@(((IResponse)context.Variables[&quot;adfResponse&quot;]).StatusCode)" reason="@(((IResponse)context.Variables[&quot;adfResponse&quot;]).StatusReason)" />
      <set-header name="Content-Type" exists-action="override">
        <value>application/json</value>
      </set-header>
      <set-header name="X-Served-Region" exists-action="override">
        <value>__REGION__</value>
      </set-header>
      <set-header name="X-Served-Factory" exists-action="override">
        <value>__FACTORY__</value>
      </set-header>
      <set-body>@(((IResponse)context.Variables["adfResponse"]).Body.As&lt;string&gt;())</set-body>
    </return-response>
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''
var triggerPolicy = replace(replace(replace(replace(triggerPolicyTemplate, '__SUB__', subId), '__RG__', rgName), '__FACTORY__', factoryName), '__REGION__', regionLabel)

resource triggerOp 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: api
  name: 'trigger-pipeline'
  properties: {
    displayName: 'Trigger Pipeline'
    method: 'POST'
    urlTemplate: '/trigger/{pipelineName}'
    templateParameters: [
      {
        name: 'pipelineName'
        type: 'string'
        required: true
        description: 'Name of the ADF pipeline to run.'
      }
    ]
    responses: []
  }
}

resource triggerOpPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  parent: triggerOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: triggerPolicy
  }
}

// ---------------------------------------------------------------------------
// Health operation: GET /adf/health -> 200. Used as the Traffic Manager probe.
// ---------------------------------------------------------------------------
var healthPolicyTemplate = '''
<policies>
  <inbound>
    <base />
    <return-response>
      <set-status code="200" reason="OK" />
      <set-header name="Content-Type" exists-action="override">
        <value>text/plain</value>
      </set-header>
      <set-header name="X-Served-Region" exists-action="override">
        <value>__REGION__</value>
      </set-header>
      <set-body>OK from __REGION__</set-body>
    </return-response>
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''
var healthPolicy = replace(healthPolicyTemplate, '__REGION__', regionLabel)

resource healthOp 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: api
  name: 'health'
  properties: {
    displayName: 'Health'
    method: 'GET'
    urlTemplate: '/health'
    templateParameters: []
    responses: []
  }
}

resource healthOpPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  parent: healthOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: healthPolicy
  }
}

output apimName string = apim.name
output principalId string = apim.identity.principalId
output gatewayUrl string = apim.properties.gatewayUrl
output gatewayHost string = replace(replace(apim.properties.gatewayUrl, 'https://', ''), '/', '')
