<#
  .SYNOPSIS
  Automation Account Runbook for removing and recreating integration account and their API connections

  .DESCRIPTION
  Automation Account Runbook is used to remove and create integration accounts.
  For creating the integration account, it will use an ARM template located in the Template Specs in Azure
  After the recreation of an integration account it will try also recreate the connection API with the same name as prefix to reconnect with the logic apps using it 

  .PARAMETER Operation
  The runbook divided to two sections and each part will be called by one of the values of this paramter: 'Remove', 'Create'

  .INPUTS
  None. You cannot pipe objects to this script.

  .OUTPUTS
  If the Operation parameter is used with the value of 'Remove': The script will output if the integration account deleted or not
  If the Operation parameter is used with the value of 'Create': The script will output if the integration account created and if connection API were recreated also
#>

######################################################################################################################

#  Copyright 2022 CloudTeam & CloudHiro Inc. or its affiliates. All Rights Re`ed.                                 #

#  You may not use this file except in compliance with the License.                                                  #

#  https://www.cloudhiro.com/AWS/TermsOfUse.php                                                                      #

#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES                                                  #

#  OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions    #

#  and limitations under the License.                                                                                #

######################################################################################################################

Param (
    [Parameter()]
    [ValidateSet('ServicePrincipal', 'ManagedIdentity')]
    [String]$AccountType,

    [Parameter()]
    [String]$ConnectionAccountVariable = 'AzureRunAsConnection',

    [Parameter(Mandatory = $true)]
    [ValidateSet('Create', 'Remove')]
    [String]$Operation,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]$SubscriptionName,
    
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]$TemplateResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]$IntegrationAccountResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]$IntegrationAccountName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]$IntegrationAccountTemplate
)

#Requires -Modules Az.Accounts,Az.Resources,Az.LogicApp

# If running in a runbook environment authenticate with Azure using the Azure Automation RunAs service principal or and Managed Identity 
$ConnectionAccount = if ($ConnectionAccountVariable -eq "AzureRunAsConnection") { "AzureRunAsConnection" } 
elseif ((-not $ConnectionAccountVariable) -and ($AccountType -eq "ManagedIdentity")) { $null }
else { Get-AutomationVariable -Name $ConnectionAccountVariable -ErrorAction SilentlyContinue }
if ($env:AUTOMATION_ASSET_ACCOUNTID) {
    # Check if using an Azure Automation RunAs service principal and try to connect
    if ($AccountType -eq "ServicePrincipal") {
        $runAsConnection = Get-AutomationConnection -Name $ConnectionAccount -ErrorAction Stop
        Add-AzAccount -ServicePrincipal -Tenant $runAsConnection.TenantId -ApplicationId $runAsConnection.ApplicationId `
            -CertificateThumbprint $runAsConnection.CertificateThumbprint -ErrorAction Stop | Out-Null
    }
    # Check if using a Managed Identity  
    elseif ($AccountType -eq "ManagedIdentity") {
        Disable-AzContextAutosave -Scope Process | Out-Null
        # Check if using an User Assigned Managed Identity or System Assigned Managed Identity and try to connect
        $context = if ($ConnectionAccount) { (Connect-AzAccount -Identity -AccountId $ConnectionAccount).Context }
        else { (Connect-AzAccount -Identity).Context }
        if (-not $context) { Write-Output "No assigned identity was found for this automation account"; Exit }
    }
}

# Remove an integration account
if ($Operation -eq "Remove") {
    # Getting the current subscription and if the subscription is not the desired one chnage to it
    $subscriptionCheck = if ($(Get-AzContext).Subscription.Name -ne $SubscriptionName) { Get-AzContext }
    else { Set-AzContext -SubscriptionName $SubscriptionName -ErrorAction SilentlyContinue }

    if ($subscriptionCheck) {
        # Get the desired integration account resource
        $integrationAccountExist = Get-AzIntegrationAccount -ResourceGroupName $IntegrationAccountResourceGroupName -Name $IntegrationAccountName -ErrorAction SilentlyContinue
        if ($integrationAccountExist) { 
            # If the integration account found remove it
            Remove-AzIntegrationAccount -ResourceGroupName $IntegrationAccountResourceGroupName -Name $IntegrationAccountName -Force -ErrorAction SilentlyContinue | Out-Null

            # Check if the integration account removed and output it
            $integrationAccountExist = Get-AzIntegrationAccount -ResourceGroupName $IntegrationAccountResourceGroupName -Name $IntegrationAccountName -ErrorAction SilentlyContinue
            if ($integrationAccountExist) { Write-Output "Failed to create integration account $IntegrationAccountName" }
            else { Write-Output "Successfully removed integration account $($IntegrationAccountName)" }
        }
        else { Write-Output "Failed to find or get integration account: $IntegrationAccountName" }
    }
    else { Write-Output "Failed to connect to subscription $SubscriptionName" }
}

# Create an integration account
elseif ($Operation -eq "Create") {
    # Getting the current subscription and if the subscription is not the desired one chnage to it
    $subscriptionCheck = if ($(Get-AzContext).Subscription.Name -ne $SubscriptionName) { Get-AzContext }
    else { Set-AzContext -SubscriptionName $SubscriptionName -ErrorAction SilentlyContinue }

    if ($subscriptionCheck) {
        # Check if the desired integration account already exist if not deploy from arm to create
        $integrationAccountExist = Get-AzIntegrationAccount -ResourceGroupName $IntegrationAccountResourceGroupName -Name $IntegrationAccountName -ErrorAction SilentlyContinue
        if ($integrationAccountExist) { Write-Output "Integration account $IntegrationAccountName in resource group $IntegrationAccountResourceGroupName already exist" } 
        else {
            # Get the integration account template id bu getting the last updated id and deploy the template to the relevant resource group
            $id = Get-AzTemplateSpec -Name $IntegrationAccountTemplate -ResourceGroupName $TemplateResourceGroupName | Select-Object -ExpandProperty Versions | Sort-Object -Property LastModifiedTime -Descending | Select-Object -First 1 -ExpandProperty Id
            $integrationAccountCreation = New-AzResourceGroupDeployment -TemplateSpecId $id -ResourceGroupName $IntegrationAccountResourceGroupName -Verbose

            # If the template deployed without errors
            if ($integrationAccountCreation) {
                # Check if the integration account from the template created succesfully and output it
                $integrationAccountExist = Get-AzIntegrationAccount -ResourceGroupName $IntegrationAccountResourceGroupName -Name $IntegrationAccountName -ErrorAction SilentlyContinue
                if ($integrationAccountExist) { 
                    Write-Output "Successfully deployed integration account $IntegrationAccountName" 
                    
                    # Create a collection of relevant properties for a new API connection for connecting to an Integration Account
                    $properties = @{
                        displayName     = "$IntegrationAccountName-as2_connection"
                        parameterValues = @{
                            integrationAccountId  = "$($integrationAccountExist.Id)"
                            integrationAccountUrl = "$($(Get-AzIntegrationAccountCallbackUrl -ResourceGroupName $IntegrationAccountResourceGroupName -Name $IntegrationAccountName).Value)" 
                        }
                        api             = @{
                            id = "/subscriptions/$($(Get-AzContext).Subscription.Id)/providers/Microsoft.Web/locations/$($integrationAccountExist.Location)/managedApis/as2"
                        }
                    }
                    # Create a new resource of the API connection using the previous $properties collection variable
                    $apiConnection = New-AzResource -Location $($integrationAccountExist.Location) -ResourceType "Microsoft.Web/connections" -ResourceName "$IntegrationAccountName-as2_connection" -ResourceGroupName $IntegrationAccountResourceGroupName -Properties $properties -Force
                    
                    # # Check if the API connection succefully created
                    if ($apiConnection) {
                        Write-Host "New API connection created successfully for connecting Logic Apps to created Integration Account $IntegrationAccountName"
                        
                        # Get all the API connections resource ids in the current subscription using their resource type
                        $apiConnectionsIds = Get-AzResource -ResourceType 'Microsoft.Web/connections' | Select-Object -ExpandProperty ResourceId
                        # Get all the API connections resource object by using the their resource ids and filtering if they belong to the current integration account by its resource id
                        $apiConnectionsResources = $apiConnectionsIds | ForEach-Object { Get-AzResource -ResourceId $_ | 
                            Where-Object { $_.Properties.parameterValues.integrationAccountId -eq $integrationAccountExist.Id } }

                        # Get all the logic app resource ids in the current subscription using the Get-AzLogicApp command by filtering if they are enabled and have the relevant integration account in the workflow settings
                        $logicAppsIds = Get-AzLogicApp | Where-Object { $_.IntegrationAccount.Name -eq $IntegrationAccountName } | Select-Object -ExpandProperty Id
                        # Get the resource object of the logic apps in the current subscription using thier resource ids and filter by checking if the have relevant API connections connected to them
                        #$logicAppResources = $logicAppsIds | ForEach-Object { Get-AzResource -ResourceId $_ | Where-Object { $_.Properties.parameters.'$connections'.value.psobject.Properties.value.connectionName -like "$IntegrationAccountName-*" } }
                        $logicAppResources = $logicAppsIds | ForEach-Object { Get-AzResource -ResourceId $_ | 
                            Where-Object { $_.Properties.parameters.'$connections'.value.psobject.Properties.value.connectionId -in $apiConnectionsResources.ResourceId } }
                        
                        # Save a list of unused and old API connections for removal
                        $apiConnectionToRemove = $apiConnectionsResources | Where-Object { $_.ResourceId -ne $apiConnection.ResourceId }
                        # Loop over all found logic app resources objects
                        $logicAppResources | ForEach-Object {
                            $backupAPIConnectinId = $($_.Properties.parameters.'$connections'.value.psobject.Properties.value | Where-Object { $_.ConnectionId -in $apiConnectionsResources.ResourceId }).connectionId
                            # Get the relevat connection id and connection name for the API connection in the logic app resource and save the API connection resource id and name
                            $($_.Properties.parameters.'$connections'.value.psobject.Properties.value | Where-Object { $_.ConnectionId -in $apiConnectionsResources.ResourceId }).connectionName = $apiConnection.Name
                            $($_.Properties.parameters.'$connections'.value.psobject.Properties.value | Where-Object { $_.ConnectionId -in $apiConnectionsResources.ResourceId }).connectionId = $apiConnection.ResourceId
                            # Update the resource of the current logic app reosurce wiht the new API connection id and connection name
                            $logicAppConnected = $_ | Set-AzResource -Force
                            # Check if the logic app resource updated
                            if ($logicAppConnected) { Write-Host "Logic App $($_.Name) connected using API connection $($apiConnection.Name) to Integration Account $IntegrationAccountName" }
                            else {
                                # If the update of one of the logic app API connection failed remove it from the list of API connection to remove
                                $apiConnectionToRemove = $apiConnectionToRemove | Where-Object { $_.ResourceId -ne $backupAPIConnectinId }
                                Write-Host "Failed to connect Logic App $($_.Name) using API connection $($apiConnection.Name) to Integration Account $IntegrationAccountName" 
                            }
                        }
                        # If the list of API connections to remove is not empty
                        if ($apiConnectionToRemove) {
                            $numberOfRemovedAPI = 0
                            # Loop and remove each of the unused and old API connections
                            $apiConnectionToRemove | ForEach-Object {
                                $checkRemoved = $_ | Remove-AzResource -Force
                                if ($checkRemoved) { $numberOfRemovedAPI++ }
                            }
                            # If API connections were removed
                            if ($numberOfRemovedAPI) {
                                Write-Host "Removed $numberOfRemovedAPI unused and old API connection of $IntegrationAccountName"
                            }
                        }
                    }
                    else { Write-Host "Failed to create new API connection for connecting Logic Apps to created Integration Account $IntegrationAccountName" }
                } 
                else { Write-Output "Template deployment succeeded but failed to find integration account $IntegrationAccountName" }
            }
            else { Write-Output "Failed to deploy integration account template $IntegrationAccountTemplate`n$($Error[0].Exception.Message)" }
        }
    }
    else { Write-Output "Failed to connect to subscription $SubscriptionName" }
}
else { Write-Output "No option was specified or both were used simultaneously" }