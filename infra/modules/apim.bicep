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
// Routes to whichever ADF region is currently active ({{active-region}}), and
// automatically falls back to the other region if that call fails. The managed
// identity holds Data Factory Contributor on BOTH factories.
// ---------------------------------------------------------------------------
var policyTemplate = '''
<policies>
  <inbound>
    <base />
    <!-- The active region is a flag operators (or a health runbook) flip during failover. -->
    <set-variable name="preferred" value="{{active-region}}" />
    <choose>
      <when condition="@((string)context.Variables[&quot;preferred&quot;] == &quot;secondary&quot;)">
        <set-variable name="factory1" value="__SECFACTORY__" />
        <set-variable name="region1" value="secondary" />
        <set-variable name="factory2" value="__PRIFACTORY__" />
        <set-variable name="region2" value="primary" />
      </when>
      <otherwise>
        <set-variable name="factory1" value="__PRIFACTORY__" />
        <set-variable name="region1" value="primary" />
        <set-variable name="factory2" value="__SECFACTORY__" />
        <set-variable name="region2" value="secondary" />
      </otherwise>
    </choose>
    <!-- Attempt the ACTIVE region first. -->
    <send-request mode="new" response-variable-name="resp1" timeout="30" ignore-error="true">
      <set-url>@("https://management.azure.com/subscriptions/__SUB__/resourceGroups/__RG__/providers/Microsoft.DataFactory/factories/" + (string)context.Variables["factory1"] + "/pipelines/" + context.Request.MatchedParameters["pipelineName"] + "/createRun?api-version=2018-06-01")</set-url>
      <set-method>POST</set-method>
      <set-header name="Content-Type" exists-action="override">
        <value>application/json</value>
      </set-header>
      <set-body>{}</set-body>
      <authentication-managed-identity resource="https://management.azure.com/" />
    </send-request>
    <choose>
      <when condition="@(context.Variables.ContainsKey(&quot;resp1&quot;) &amp;&amp; context.Variables[&quot;resp1&quot;] != null &amp;&amp; ((IResponse)context.Variables[&quot;resp1&quot;]).StatusCode &lt; 300)">
        <return-response>
          <set-status code="200" reason="OK" />
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <set-header name="X-Served-Region" exists-action="override">
            <value>@((string)context.Variables["region1"])</value>
          </set-header>
          <set-header name="X-Failover" exists-action="override">
            <value>false</value>
          </set-header>
          <set-body>@(((IResponse)context.Variables["resp1"]).Body.As&lt;string&gt;())</set-body>
        </return-response>
      </when>
      <otherwise>
        <!-- Active region failed: automatically fall back to the standby region. -->
        <send-request mode="new" response-variable-name="resp2" timeout="30" ignore-error="true">
          <set-url>@("https://management.azure.com/subscriptions/__SUB__/resourceGroups/__RG__/providers/Microsoft.DataFactory/factories/" + (string)context.Variables["factory2"] + "/pipelines/" + context.Request.MatchedParameters["pipelineName"] + "/createRun?api-version=2018-06-01")</set-url>
          <set-method>POST</set-method>
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <set-body>{}</set-body>
          <authentication-managed-identity resource="https://management.azure.com/" />
        </send-request>
        <return-response>
          <set-status code="200" reason="OK" />
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <set-header name="X-Served-Region" exists-action="override">
            <value>@((string)context.Variables["region2"])</value>
          </set-header>
          <set-header name="X-Failover" exists-action="override">
            <value>true</value>
          </set-header>
          <set-body>@(context.Variables.ContainsKey("resp2") &amp;&amp; context.Variables["resp2"] != null ? ((IResponse)context.Variables["resp2"]).Body.As&lt;string&gt;() : "{ \"error\": \"both regions unavailable\" }")</set-body>
        </return-response>
      </otherwise>
    </choose>
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
