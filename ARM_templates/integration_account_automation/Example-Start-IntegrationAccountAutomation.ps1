<#
  .SYNOPSIS
  Example script for executing an automation account runbook for removing and recreating integration accounts

  .DESCRIPTION
  This example script can be used to start the execution of the automation account runbook for removing and recreating integration accounts and restoring their API connection.
  This script needs to coontain the relevant integration accounts properties and automation account properties as shown bellow 

  .PARAMETER Remove
  Paramter to use to start the automation account runbook for removing an integration account

  .PARAMETER Create
  Paramter to use to start the automation account runbook for creating an integration account and trying to recreate the API connections of it

  .PARAMETER IntegrationAccountName
  The names of the integration accounts
  This paramter needs to be updated with the names of every integration account it needs in the script itself.

  .INPUTS
  None. You cannot pipe objects to this script.

  .OUTPUTS
  If the Operation parameter is used with the value of 'Remove': The script will output if the integration account deleted or not
  If the Operation parameter is used with the value of 'Create': The script will output if the integration account created and if connection API were recreated also

  .EXAMPLE
  PS> ./Start-IntegrationAccountAutomation.ps1 -Create -IntegrationAccountName "FirstIntegrationAccount"

  .EXAMPLE
  PS> ./Start-IntegrationAccountAutomation.ps1 -Remove -IntegrationAccountName "SecondIntegrationAccount"
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
    [Parameter(ParameterSetName = 'Remove')]
    [Switch]$Remove,
    
    [Parameter(ParameterSetName = 'Create')]
    [Switch]$Create,

    [Parameter(Mandatory = $true)]
    [ValidateSet('FirstIntegrationAccount', "SecondIntegrationAccount")]
    [String]$IntegrationAccountName
)

#Requires -Modules Az.Accounts,Az.Automation

# System Managed Identity for authenticating with Azure using
$AccountType = "ManagedIdentity"
$ConnectionAccountVariable = ""

# Integration accounts resources location for deployment
$FirstIntegraionAccountLocation = @{
    SubscriptionName                    = ""
    IntegrationAccountResourceGroupName = ""
    TemplateResourceGroupName           = ""
}
$SecondIntegraionAccountLocation = @{
    SubscriptionName                    = ""
    IntegrationAccountResourceGroupName = ""
    TemplateResourceGroupName           = ""
}

# Hashtable for pointing the integration account name to the relevant resource location
$integrationAccountsLocations = @{
    ContosoIntegrationAccount  = $FirstIntegraionAccountLocation
    FabrikamIntegrationAccount = $SecondIntegraionAccountLocation
}
# Checking what parameter was used for creating or removing the integration account
$operation = if ($Create.IsPresent) { "Create" } elseif ($Remove.IsPresent) { "Remove" }

# Coniguring the values for the runbook script parameters
$parameters = @{
    AccountType                         = $AccountType
    ConnectionAccountVariable           = $ConnectionAccountVariable
    Operation                           = $operation
    IntegrationAccountName              = $IntegrationAccountName
    IntegrationAccountTemplate          = "$IntegrationAccountName-Template"
    SubscriptionName                    = $integrationAccountsLocations[$IntegrationAccountName]["SubscriptionName"]
    IntegrationAccountResourceGroupName = $integrationAccountsLocations[$IntegrationAccountName]["IntegrationAccountResourceGroupName"]
    TemplateResourceGroupName           = $integrationAccountsLocations[$IntegrationAccountName]["TemplateResourceGroupName"]
}

# Connect to Azure if not connected already
if (-not $(Get-AzContext -ErrorAction SilentlyContinue)) { Connect-AzAccount -ErrorAction Stop | Out-Null }
# Automation Account data
$subscriptionName = ""
# Check if the current subscription is session is the one as the automation account, if not change to it
if ($(Get-AzContext).Subscription.Name -ne $subscriptionName) { Set-AzContext -SubscriptionName $subscriptionName -ErrorAction Stop | Out-Null }
$resourceGroupName = ""
$automationAccountName = ""
$runbookName = "RemoveCreate-IntegrationAccountForLogicApps"
# Find if the automation account exist
$automationAccount = Get-AzAutomationAccount -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName
if ($automationAccount) {
    # Check that the parameter are passed to the runbook 
    if ($parameters) {
        # Start the runbook using the passed parameters
        Start-AzAutomationRunbook -AutomationAccountName $automationAccountName -Name $runbookName -ResourceGroupName $resourceGroupName -Parameters $parameters -Wait -Verbose
    }
    else { Write-Host "Parameters variable is empty and don't have values" -ForegroundColor Red }
}
else { Write-Host "Automation Account with name $automationAccountName in resource group $resourceGroupName not found" -ForegroundColor Red }
