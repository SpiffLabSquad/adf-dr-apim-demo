@description('Name of the Azure Data Factory (globally scoped within the subscription).')
param factoryName string

@description('Azure region for the factory.')
param location string

@description('Name of the demo pipeline to create.')
param pipelineName string = 'DemoPipeline'

@description('Number of seconds the demo Wait activity runs for.')
param waitSeconds int = 5

@description('Name of an additional, parameterized test pipeline.')
param testPipelineName string = 'TestPipeline'

resource adf 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: factoryName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

@description('A dependency-free pipeline (single Wait activity) so the demo needs no linked services or datasets.')
resource pipeline 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = {
  parent: adf
  name: pipelineName
  properties: {
    activities: [
      {
        name: 'WaitActivity'
        type: 'Wait'
        dependsOn: []
        userProperties: []
        typeProperties: {
          waitTimeInSeconds: waitSeconds
        }
      }
    ]
    annotations: [
      'adf-dr-apim-demo'
    ]
  }
}

@description('A parameterized test pipeline: sets a variable from the "message" parameter (default provided so it triggers with an empty body), then waits. Still dependency-free.')
resource testPipeline 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = {
  parent: adf
  name: testPipelineName
  properties: {
    parameters: {
      message: {
        type: 'String'
        defaultValue: 'hello from APIM'
      }
    }
    variables: {
      outMessage: {
        type: 'String'
      }
    }
    activities: [
      {
        name: 'SetMessage'
        type: 'SetVariable'
        dependsOn: []
        userProperties: []
        typeProperties: {
          variableName: 'outMessage'
          value: {
            value: '@pipeline().parameters.message'
            type: 'Expression'
          }
        }
      }
      {
        name: 'WaitActivity'
        type: 'Wait'
        dependsOn: [
          {
            activity: 'SetMessage'
            dependencyConditions: [
              'Succeeded'
            ]
          }
        ]
        userProperties: []
        typeProperties: {
          waitTimeInSeconds: 3
        }
      }
    ]
    annotations: [
      'adf-dr-apim-demo'
      'test-pipeline'
    ]
  }
}

output factoryName string = adf.name
output factoryId string = adf.id
output pipelineName string = pipeline.name
output testPipelineName string = testPipeline.name
