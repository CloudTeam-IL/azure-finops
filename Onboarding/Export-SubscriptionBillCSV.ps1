Param (
    [Parameter(Mandatory = $false)]
    [ValidateSet('ServicePrincipal', 'ManagedIdentity')]
    [String]$AccountType,

    [Parameter(Mandatory = $false)]
    [String]$ConnectionAccountVariable = 'AzureRunAsConnection',

    [Parameter(Mandatory = $true)]
    [String]$StorageAccountResourceId
)

#Requires -Modules Az.Accounts,Az.Resources,Az.CostManagement

$costExportsNamePrefix = "Chi"
$blobContainerName = 'usage-report'
$actualCostExportName = 'ChiActualCost'
$amortizedCostExportName = 'ChiAmortizedCost'

# Function to connect to azure using service principal or managed identity in automation account
function ConnectToAzure {
    # If running in a runbook environment authenticate with Azure using the Azure Automation RunAs service principal or and Managed Identity 
    if ($env:AUTOMATION_ASSET_ACCOUNTID) {
        $ConnectionAccount = if ($ConnectionAccountVariable -eq "AzureRunAsConnection") { "AzureRunAsConnection" } 
        elseif ((-not $ConnectionAccountVariable) -and ($AccountType -eq "ManagedIdentity")) { $null }
        else { Get-AutomationVariable -Name $ConnectionAccountVariable -ErrorAction SilentlyContinue }
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
            if (-not $context) { Write-Output "No managed identity was found for this automation account"; Exit }
        }
    }
}

# Function to check if the resource provider for cost management exports is registered, if not register it
function CheckRegisterProviders {
    param ([Array]$Providers)

    # Check if the Microsoft.CostManagement and Microsoft.CostManagementExports resource providers are not registered in the subscription of the relevant storage account for BillCSV export
    $notRegisteredresourceProviders = Get-AzResourceProvider -ListAvailable | Where-Object { $_.ProviderNamespace -in $Providers -and $_.RegistrationState -ne 'Registered' } 
    # If the resource providers not registered
    if ($notRegisteredresourceProviders) {
        # Register each of the not registered resource providers
        $notRegisteredresourceProviders | ForEach-Object { 
            Write-Output "Registering not registered $($_.ProviderNamespace) resource provider"
            Register-AzResourceProvider -ProviderNamespace $_.ProviderNamespace -ErrorAction Stop | Out-Null 
        } 
        # Loop and wait till the resource providers registration in the subscription finished
        while ($(Get-AzResourceProvider -ListAvailable | Where-Object { $_.ProviderNamespace -in $Providers -and $_.RegistrationState -ne 'Registered' })) { Start-Sleep -Seconds 5 }
    }
}

# Function for creating the BillCSV exports
function CreateCostExport {
    param ([String]$ExportName, [String]$DefinitionType, [String]$ResourceId, [String]$ContainerName, [String]$CostFolderName, [String]$SubscriptionId, [Int]$NumberOfMonths, [String]$OutputMessage)
    
    # Checking if the BillCSV export already have been created
    if (-not $(Get-AzCostManagementExport -Name $ExportName -Scope $SubscriptionId -ErrorAction SilentlyContinue)) {
        # Check what cost export function to use, execute the relevant one to create the export and save the output to a variable
        
        $costExport = New-AzCostManagementExport -Name $ExportName -ScheduleStatus Active -ScheduleRecurrence Daily -DefinitionTimeframe MonthToDate -DefinitionType $DefinitionType `
            -DataSetGranularity Daily -DestinationResourceId $ResourceId -DestinationContainer $ContainerName -DestinationRootFolderPath $CostFolderName `
            -Format Csv -RecurrencePeriodFrom $(Get-Date -AsUTC) -RecurrencePeriodTo $($(Get-Date -AsUTC).AddYears(20)) -Scope $SubscriptionId

        # If th ecost export creation succeeded
        if ($costExport) { 
            Write-Output "New $OutputMessage cost export with name $($costExport.Name) created successfully" 
            # Start the cost export
            $costExport | Invoke-AzCostManagementExecuteExport -Verbose
        }
        else { Write-Error "Failed $OutputMessage cost export $ExportName" -ErrorAction Stop }
    }
    else { Write-Output "The $OutputMessage export with name $ExportName already exist in subscription" }
}

ConnectToAzure
# Get the storage account by its resource id from the parameter
$storageAccountResource = Get-AzResource -ResourceId $StorageAccountResourceId -ErrorAction SilentlyContinue
if (-not $($storageAccountResource.ResourceType -eq "Microsoft.Storage/storageAccounts")) { Write-Error "No storage account found for given resource id $StorageAccountResourceId" -ErrorAction Stop }

# Get all enabled subscriptions
$subscriptions = Get-AzSubscription | Where-Object State -eq Enabled
foreach ($subscription in $subscriptions) {
    # Get all cost exports at the current subscription in the loop and by the following options
    $costExports = Get-AzCostManagementExport -Scope "/subscriptions/$($subscription.Id)" | Where-Object { $_.Name -Like "$costExportsNamePrefix*" -and $_.DataSetGranularity -eq 'Daily' -and $_.DefinitionTimeframe -eq 'MonthToDate' -and $_.DefinitionType -in 'ActualCost', 'AmortizedCost' }

    # Check if the number of cost exports is greater that or equal to the number in the condition
    if ($costExports.Length -ge 2) {
        Write-Output "Daily export of both ActualCost and AmortizedCost already configured in subscription $($subscription.Name)"
    }
    # Else create new cost exports
    else {
        # Change to the relevant subscription in the session
        $subscriptionCheck = Set-AzContext -SubscriptionObject $subscription
        if ($subscriptionCheck) {
            Write-Output "Changed to subscription $($subscription.Name)"
            # Check if the resource provider for cost management exports is registered, if not register it
            CheckRegisterProviders -Providers "Microsoft.CostManagementExports"

            $blobContainerCostFolderName = "$($subscription.Name)_$($subscription.Id)"
            # Initialize an array of the values for BillCSV scheduled cost export
            $scheduleExportParameters = @( @("$actualCostExportName`_$($subscription.Id)", "ActualCost", "actual"), @("$amortizedCostExportName`_$($subscription.Id)", "AmortizedCost", "amortized") )
            
            # Loop over each of the array values and execute the cost export function using the correct ones
            $scheduleExportParameters | ForEach-Object {
                CreateCostExport -ExportName $_[0] -DefinitionType $_[1] -ResourceId $storageAccountResource.ResourceId -ContainerName $blobContainerName `
                    -CostFolderName $blobContainerCostFolderName -SubscriptionId "/subscriptions/$($subscription.Id)" -OutputMessage $_[2]
            }
        }
        else { Write-Error "Failed to change to subscription $($subscription.Name)" -ErrorAction Stop }
    }
}
