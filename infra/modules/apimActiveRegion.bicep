// ===========================================================================
// APIM-only active/passive routing (no Traffic Manager).
//
// Adds to an EXISTING primary APIM instance:
//   - a named value 'active-region' (primary|secondary) = the operator/health flag
//   - an 'adf-ha' API with POST /adf-ha/trigger/{pipelineName}
//   - a policy that calls the ADF createRun for the *active* region, and
//     automatically falls back to the other region if that call fails.
//
// The calling application always uses the SAME URL; failover happens entirely
// inside APIM. NOTE: a single APIM instance is a single-region ingress point —
// see README/architecture for the multi-region ingress options.
// ===========================================================================

@description('Existing (primary) APIM service name that hosts the HA API.')
param apimName string

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

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimName
}

// The "which region is active" flag. Flip it with `az apim nv update` (see scripts/switch-region).
resource activeRegionNv 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'active-region'
  properties: {
    displayName: 'active-region'
    value: defaultActiveRegion
    secret: false
  }
}

resource haApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'adf-ha'
  properties: {
    displayName: 'ADF HA Trigger (active-region routing)'
    apiRevision: '1'
    path: 'adf-ha'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
  }
}

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

resource haOp 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: haApi
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

resource haOpPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  parent: haOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: policyXml
  }
  dependsOn: [
    activeRegionNv
  ]
}

output haApiPath string = haApi.properties.path
output activeRegionNamedValue string = activeRegionNv.name
