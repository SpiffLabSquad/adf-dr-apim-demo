@description('APIM service name (must be globally unique).')
param apimName string

@description('Azure region for the APIM instance.')
param location string

@description('Publisher email for the APIM service.')
param publisherEmail string

@description('Publisher (organization) name for the APIM service.')
param publisherName string = 'ADF DR Demo'

@description('Primary Data Factory name.')
param primaryFactoryName string

@description('Secondary Data Factory name.')
param secondaryFactoryName string

@description('Initial value for the active-region flag.')
@allowed([
  'primary'
  'secondary'
])
param defaultActiveRegion string = 'primary'

var subId = subscription().subscriptionId
var rgName = resourceGroup().name

// --- Single APIM (Consumption) with a system-assigned managed identity ---
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

// The "which region is active" flag. Flip it with scripts/switch-region (az apim nv update).
resource activeRegionNv 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'active-region'
  properties: {
    displayName: 'active-region'
    value: defaultActiveRegion
    secret: false
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'adf-trigger'
  properties: {
    displayName: 'ADF Trigger (active-region routing)'
    apiRevision: '1'
    path: 'adf'
    protocols: [
      'https'
    ]
    // Demo only: no subscription key so the caller/Autosys can call it directly.
    // In production, require a subscription key, client cert, or OAuth (see README > Security).
    subscriptionRequired: false
  }
}

// ---------------------------------------------------------------------------
// POST /adf/trigger/{pipelineName}
// Triggers ONLY the ADF region currently marked active ({{active-region}}) and
// relays that factory's real response. Failover is flag-driven — there is no
// automatic cross-region retry (createRun is not idempotent). The managed
// identity holds Data Factory Contributor on BOTH factories.
// ---------------------------------------------------------------------------
var policyTemplate = '''
<policies>
  <inbound>
    <base />
    <!-- Route to whichever ADF region is currently active. -->
    <set-variable name="preferred" value="{{active-region}}" />
    <choose>
      <when condition="@((string)context.Variables[&quot;preferred&quot;] == &quot;primary&quot;)">
        <set-variable name="factory" value="__PRIFACTORY__" />
        <set-variable name="servedRegion" value="primary" />
      </when>
      <when condition="@((string)context.Variables[&quot;preferred&quot;] == &quot;secondary&quot;)">
        <set-variable name="factory" value="__SECFACTORY__" />
        <set-variable name="servedRegion" value="secondary" />
      </when>
      <otherwise>
        <!-- Fail loudly on an unexpected flag rather than silently defaulting to a region. -->
        <return-response>
          <set-status code="503" reason="Service Unavailable" />
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <set-body>{ "error": "invalid active-region named value; expected 'primary' or 'secondary'" }</set-body>
        </return-response>
      </otherwise>
    </choose>
    <send-request mode="new" response-variable-name="adfResponse" timeout="30" ignore-error="false">
      <set-url>@("https://management.azure.com/subscriptions/__SUB__/resourceGroups/__RG__/providers/Microsoft.DataFactory/factories/" + (string)context.Variables["factory"] + "/pipelines/" + System.Uri.EscapeDataString((string)context.Request.MatchedParameters["pipelineName"]) + "/createRun?api-version=2018-06-01")</set-url>
      <set-method>POST</set-method>
      <set-header name="Content-Type" exists-action="override">
        <value>application/json</value>
      </set-header>
      <set-body>{}</set-body>
      <authentication-managed-identity resource="https://management.azure.com/" />
    </send-request>
    <return-response>
      <set-status code="@(((IResponse)context.Variables[&quot;adfResponse&quot;]).StatusCode)" reason="@(((IResponse)context.Variables[&quot;adfResponse&quot;]).StatusReason)" />
      <set-header name="Content-Type" exists-action="override">
        <value>application/json</value>
      </set-header>
      <set-header name="X-Served-Region" exists-action="override">
        <value>@((string)context.Variables["servedRegion"])</value>
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
var policyXml = replace(replace(replace(replace(policyTemplate, '__SUB__', subId), '__RG__', rgName), '__PRIFACTORY__', primaryFactoryName), '__SECFACTORY__', secondaryFactoryName)

resource triggerOp 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: api
  name: 'trigger-pipeline'
  properties: {
    displayName: 'Trigger Pipeline (active region)'
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
    value: policyXml
  }
  dependsOn: [
    activeRegionNv
  ]
}

output apimName string = apim.name
output principalId string = apim.identity.principalId
output gatewayUrl string = apim.properties.gatewayUrl
output gatewayHost string = replace(replace(apim.properties.gatewayUrl, 'https://', ''), '/', '')
output activeRegionNamedValue string = activeRegionNv.name
