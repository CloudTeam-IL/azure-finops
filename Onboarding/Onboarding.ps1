<#
  .SYNOPSIS
  CloudTeam & CloudHiro onboarding script for clients

  .DESCRIPTION
  The Onboarding.ps1 script using a CSV file and different parameters to do the following:
  - Create a service principal
  - Create an Azure AD group
  - Invite external users
  - Add users to Azure AD group
  - Create a storage account for BillCSV exports
  - Create different BillCSV exports
  - Assign roles to the service principal and Azure AD group
  For undoing and removing all those operation another paramters exist also

  .PARAMETER FilePath
  Specifies the path to the CSV file.

  .PARAMETER AssignmentScope
  Choosing on which scope to apply the role assingnment: Subscriptions, Management Groups, Tenant.

  .PARAMETER ExportUndoAndRemovalCommands
  Undoing and removing all other script operations.

  .INPUTS
  None. You cannot pipe objects to Onboarding.ps1.

  .OUTPUTS
  Different for each of the Switch based parameters

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -CreateOrGetServicePrincipal

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -CreateOrGetAzureADGroup

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -InviteOrGetGuestUsers

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -AddUsersToGroup

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -CreateOrGetStorageAccount

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -CreateOrGetBillCSVExports

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -AssignRolesToStorageAccount
  
  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -AssignRolesToScope -AssignmentScope Subscritpions 

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -ExecuteAllOnboardingCommands -AssignmentScope Tenant

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -ExportUndoAndRemovalCommands
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
    [Parameter(Mandatory = $true)]
    [ValidateScript({
            if (Test-Path -Path $_ -PathType Leaf) { $true } else { throw "Could not find $_" }
        })]
    [String]$FilePath,

    [Parameter (Mandatory = $false)]
    [String] $CloudteamIncluded = $true,

    [Parameter (Mandatory = $true)]
    [String] $CompanyName,

    [Parameter (Mandatory = $false)]
    [string] $subId,

    [Parameter(ParameterSetName = 'CreateOrGetServicePrincipal')]
    [Switch]$CreateOrGetServicePrincipal,

    [Parameter(ParameterSetName = 'CreateOrGetAzureADGroup')]
    [Switch]$CreateOrGetAzureADGroup,

    [Parameter(ParameterSetName = 'InviteOrGetGuestUsers')]
    [Switch]$InviteOrGetGuestUsers,

    [Parameter(ParameterSetName = 'AddUsersToGroup')]
    [Switch]$AddUsersToGroup,

    [Parameter(ParameterSetName = 'InviteGuestUsers_AddUsersToGroup')]
    [Switch]$InviteGuestUsers_AddUsersToGroup,

    [Parameter(ParameterSetName = 'CreateOrGetStorageAccount')]
    [Switch]$CreateOrGetStorageAccount,

    [Parameter(ParameterSetName = 'CreateOrGetBillCSVExports')]
    [Switch]$CreateOrGetBillCSVExports,

    [Parameter(ParameterSetName = 'CreateStorageAccount_CreateOrGetBillCSVExports')]
    [Switch]$CreateStorageAccount_CreateOrGetBillCSVExports,

    [Parameter(ParameterSetName = 'AssignRolesToStorageAccount')]
    [Switch]$AssignRolesToStorageAccount,

    [Parameter(ParameterSetName = 'AssignRolesToScope')]
    [Switch]$AssignRolesToScope,

    [Parameter(ParameterSetName = 'ExecuteAllOnboardingCommands')]
    [Switch]$ExecuteAllOnboardingCommands,

    [Parameter(ParameterSetName = 'AssignRolesToScope', Mandatory = $true)]
    [Parameter(ParameterSetName = 'ExecuteAllOnboardingCommands')]
    [ValidateSet('Subscriptions', "ManagementGroups", "Tenant")]
    [String]$AssignmentScope,

    [Parameter(ParameterSetName = 'ExportUndoAndRemovalCommands')]
    [Switch]$ExportUndoAndRemovalCommands
)

#Requires -Modules AzureAD.Standard.Preview,Az.Accounts,Az.Resources,Az.Storage,Az.Billing,Az.CostManagement

# Check if connected to AzureAD and ARM if not connect 
if (-not $(Get-AzContext -ErrorAction SilentlyContinue)) { Connect-AzAccount | Out-Null }
try { Get-AzureADDomain | Out-Null } catch { AzureAD.Standard.Preview\Connect-AzureAD -Identity -TenantID $env:ACC_TID | Out-Null }


function SendRestRequest {
    param(
        $uri,
        $Header,
        $body,
        $method
    )
    $respons = Invoke-RestMethod -Method $method -Uri $uri -Headers $Header -Body $body
    if ($respons.Status -lt 200 -or $respons.Status -gt 300) {
        Write-Host "ERROR: $($respons.error)" -ForegroundColor Red
    }
}



# Create Service Principal
function CreateOrGetServicePrincipal {
    param ([String]$FilePath, [Switch]$GetOnly)

    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $servicePrincipalName = $($CSVFile.ServicePrincipal | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()

    if ($servicePrincipalName) {
        # Create the service principal and configure its access to Azure using a self-signed certificate to use for the credential
        $servicePrincipalExist = Get-AzADServicePrincipal -DisplayName $servicePrincipalName -ErrorAction SilentlyContinue
        if (-not $servicePrincipalExist) {
            # If GetOnly paramter used in here, exit function and return null
            if ($GetOnly.IsPresent) { Write-Host "Service Principal $servicePrincipalName not found or created yet"; return $null }
            # Create service princiapl with RBAC authontication and a certificate
            $servicePrincipal = $(az ad sp create-for-rbac --name $servicePrincipalName --create-cert --only-show-errors)
            Start-Sleep -Seconds 5
            # Get the newly create service principal 
            $servicePrincipalExist = Get-AzADServicePrincipal -DisplayName $servicePrincipalName
            if ($servicePrincipalExist) {
                # Export to file and print the service principal info
                Write-Host "Exporting Service Principal Info to $($servicePrincipalName)SP.json" 
                $servicePrincipal | Out-File -FilePath .\$($servicePrincipalName)SP.json -Verbose
                $servicePrincipalInfo = "$servicePrincipal".Split("{").Split("}").Split("  ") | Where-Object { $_ -ne '' }
                Write-Host "Service Principal $($servicePrincipalName):" -ForegroundColor Green 
                Write-Host "$($($servicePrincipalInfo | ForEach-Object {"$_"}) -join "`n")" 
                return $servicePrincipalExist.Id
            }
            else { Write-Host "Failed to create and get the Service Principal" -ForegroundColor Red }
        }
        else { 
            Write-Host "Service Principal with name $servicePrincipalName already exists" 
            return $servicePrincipalExist.Id
        }
    }
    else { Write-Host "No Service Principal was found in CSV file" -ForegroundColor Red }
}

# Create Azure AD Group
function CreateOrGetAzureADGroup {
    param ([String]$FilePath, [Switch]$GetOnly)
    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $AzureADGroupName = $($CSVFile.AzureADGroup | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()

    if ($AzureADGroupName) {
        # Check if the Azure AD group already exist
        $AzureADGroupExist = Get-AzADGroup -DisplayName $AzureADGroupName -ErrorAction SilentlyContinue
        if (-not $AzureADGroupExist) {
            # If GetOnly paramter used in here, exit function and return null
            if ($GetOnly.IsPresent) { Write-Host "Azure AD group $AzureADGroupName not found or created yet"; return $null }
            # Create the Azure AD group as a Security group
            $AzureADGroup = New-AzADGroup -DisplayName $AzureADGroupName -MailNickname $AzureADGroupName -SecurityEnabled
            Start-Sleep -Seconds 5
            # Check and print if the Azure AD group created or not
            if ($AzureADGroup) { 
                Write-Host "Azure AD group $($AzureADGroup.DisplayName) created" -ForegroundColor Green 
                return $AzureADGroup.Id
            }
            else { Write-Host "Failed to create and get Azure AD group" -ForegroundColor Red }
        }
        else { 
            Write-Host "Azure AD Group with name $AzureADGroupName already exists in Azure AD" 
            return $AzureADGroupExist.Id
        }
    }
    else { Write-Host "No Azure AD group was found in CSV file" -ForegroundColor Red }
}

# Send and invitation for external users
function InviteOrGetGuestUsers {
    param ([String]$FilePath, [Switch]$GetOnly)

    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $usersList = $($CSVFile.Users | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $usersCheck = @()

    if ($usersList -and $CloudteamIncluded) {
        # Loop over the list of users from the CSV file varaible
        foreach ($user in $usersList) {
            # Check if a user with the same Mail address or UserPrincipalName already exist in Azure AD
            $AzureADUser = Get-AzADUser -Filter "Mail eq '$user' or UserPrincipalName eq '$user'" -ErrorAction SilentlyContinue | Where-Object { $_.UserPrincipalName -eq $user -or $_.UserPrincipalName -like "$($([String]$user).Replace("@", "_"))*" } 
            if (-not $AzureADUser) {
                # If GetOnly paramter used in here, continure to the next iteratio  of the loop without trying to invite the user
                if ($GetOnly.IsPresent) { Write-Host "User $user not found or created yet"; Continue }
                # Send and invitaiton to the external user using his Mail address
                $invitation = New-AzureADMSInvitation -InvitedUserEmailAddress $user -InviteRedirectUrl 'https://myapps.microsoft.com' -SendInvitationMessage $true -Verbose 
                # Check if invitation sent to the correct user and is in pending state
                if ($invitation.InvitedUserEmailAddress -eq $user -and $invitation.Status -eq "PendingAcceptance") { 
                    Write-Host "Invitation sent to $user and pending acceptance" -ForegroundColor Green
                    # Find the newly created guest and loop on it if not found
                    $userCheck = Get-AzADUser -Mail $user -ErrorAction SilentlyContinue
                    $count = 0
                    while (-not $userCheck) {
                        if ($count -ne 10) { Start-Sleep -Seconds 2; $count++ } else { Break }
                        $userCheck = Get-AzADUser -Mail $user -ErrorAction SilentlyContinue
                    }
                    # If user found in Azure AD add to the array of users checked and found 
                    if ($userCheck) { $usersCheck += $userCheck.Id } 
                    else { Write-Host "No new user $user found not found after invitation sent" }
                }
                else { Write-Host "Failed to send invitation to $user" -ForegroundColor Red }
            }
            else {
                # If the user already have been invited or created in Azure AD add to the array of users checked and found
                Write-Host "Azure AD User with Mail or UserPrincipalName $user exists in Azure AD"
                $usersCheck += $AzureADUser.Id
            }
        }
    }
    else { Write-Host "No users were found in CSV file" -ForegroundColor Red }

    # Return the users that have been found
    return $usersCheck
}

# Add users (external and internal) to Azure AD group
function AddUsersToGroup {
    param ([String]$AzureADGroupId, [Array]$AzureADUsersIds)

    # If AzureADGroupId paramter is not empty and AzureADUsersIds paramter array not equal 0
    if ($AzureADGroupId -and $AzureADUsersIds.Count -ne 0) {
        # Get the current members inside AzureAD group
        $AzureADGroupMembersIds = Get-AzureADGroupMember -ObjectId $AzureADGroupId -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ObjectId
        $AzureADUsersToAdd, $AzureADUsersInGroup = @(), @()
        # Loop over the array of users ids
        foreach ($userId in $AzureADUsersIds) {
            # Get each user by its object id
            $userFound = Get-AzADUser -ObjectId $userId -ErrorAction SilentlyContinue
            if ($userFound) { 
                # If the user found check if it already added to the AzureAD group or not and add to the relevant array variable
                if ($userFound.Id -notin $AzureADGroupMembersIds) { $AzureADUsersToAdd += $userFound } else { $AzureADUsersInGroup += $userFound }
            }
        }

        # If users were found and not already in the AzureAD group
        if ($AzureADUsersToAdd.Count -ne 0) {
            # Get AzureAD Group by id
            $AzureADGroup = Get-AzADGroup -ObjectId $AzureADGroupId
            # If AzureAD group have been found
            if ($AzureADGroup) {
                # Add the users to the Azure AD group
                Add-AzADGroupMember -TargetGroupObjectId $AzureADGroup.Id -MemberObjectId $AzureADUsersToAdd.Id -ErrorAction SilentlyContinue -Verbose
                Start-Sleep -Seconds 5
                # Get all the Azure AD Group members
                $groupMembers = Get-AzureADGroupMember -ObjectId $AzureADGroupId -ErrorAction SilentlyContinue
                # If users were found in group print them
                if ($groupMembers) { 
                    Write-Host "The following users are members of $($AzureADGroup.DisplayName):" -ForegroundColor Green 
                    $groupMembers | ForEach-Object { "$($_.DisplayName) $($_.UserPrincipalName)" } 
                }
                else { Write-Host "No users were found in $($AzureADGroup.DisplayName)" -ForegroundColor Red }
            }
            else { Write-Host "No Azure AD group with name $($AzureADGroup.DisplayName) was found" -ForegroundColor Red }
        }
        else {
            # if no new users were found to add the group and users ids were found and passed
            if ($AzureADUsersInGroup.Length -ne $AzureADUsersIds.Length) { Write-Host "No new users were found to add to Azure AD group" -ForegroundColor Red }
        }
        # If no new users were found but there are already users in the group print them
        if ($AzureADUsersInGroup.Count -ne 0 -and $AzureADUsersToAdd.Count -eq 0) {
            Write-Host "The following users are already members of $($AzureADGroup.DisplayName):"
            $groupMembers = Get-AzureADGroupMember -ObjectId $AzureADGroupId
            $groupMembers | ForEach-Object { "$($_.DisplayName) $($_.UserPrincipalName)" } 
        }
    }
}

# Create or find a storage account
# If no resource group exist as written create before the storage account
# If storage account created or found create a blob container if not exist and create lifecycle management policy if not exist
# If all steps succeed return the storage account resource id 
function CreateOrGetStorageAccount {
    param ([String]$FilePath, [Switch]$GetOnly)
    
    # Default variables
    $storageAccountSku = "Standard_LRS"
    $storageAccountKind = "StorageV2"
    $blobContainerName = 'usage-report'
    $daysToRemove = 30
    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $storageAccountSubscription = $subId ? $subId : (Get-AzContext).Subscription.Id
    $storageAccountResourceGroup = $($CSVFile.StorageAccountResourceGroup | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $storageAccountName = $($CSVFile.StorageAccountName | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $storageAccountName = $storageAccountName.Replace("@@", $CompanyName.Replace(' ', '').Replace('[^a-zA-Z0-9]', '').Substring(0, 4).ToLower()) + [string](Get-Random -Minimum 100 -Maximum 999)
    $location = $($CSVFile.Location | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()

    # If the one of the following varaibles with the values from the CSV file equal to 'Not Relevant' return a null value from the function
    if ($storageAccountSubscription -eq 'Not Relevant' -or $storageAccountName -eq 'Not Relevant') { return $null }

    # Find if the subscription exist
    $subscription = Get-AzSubscription -SubscriptionId $storageAccountSubscription -ErrorAction SilentlyContinue
    if (-not $subscription) {
        Write-Error "Subscription with name $storageAccountSubscription was not found" -ErrorAction Stop
    }
    # If the subscription found check if it is the current subscription in the session
    else { 
        if ($(Get-AzContext).Subscription.Name -ne $subscription.Name) { 
            # Change to the relevant subscription for the storage account
            if ($subId) {
                $subscriptionCheck = Set-AzContext -Subscription $subId
            }
            if ($subscriptionCheck) { Write-Host "Changed to subscription $($subscription.Name)" -ForegroundColor Green }
            else { Write-Error "Failed to change to subscription $($subscription.Name)" -ErrorAction Stop }
        }
    }

    # If GetOnly paramter used in here, get the storage account and the relevant blob container inside it
    if ($GetOnly.IsPresent) {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $storageAccountResourceGroup -Name $storageAccountName -ErrorAction SilentlyContinue
        $blobContainer = Get-AzStorageContainer -Name $blobContainerName -Context $storageAccount.Context -ErrorAction SilentlyContinue
        # If the both storage account and the relevant blob container are found return only the storage account id
        if ($storageAccount -and $blobContainer) { return $storageAccount.Id }
        else { Write-Host "No blob container $blobContainerName or storage account $storageAccountName were found or created yet in subscription $storageAccountSubscription"; return $null }
    }

    # Check if the given location exist in Azure
    $locationFound = Get-AzLocation | Where-Object { $_.Location -eq $location -or $_.DisplayName -eq $location }
    if (-not $locationFound) { Write-Error "No location with name $location was found" -ErrorAction Stop } 

    # Find if the resource group exist in the current subscription
    $resourceGroup = Get-AzResourceGroup -Name $storageAccountResourceGroup -ErrorAction SilentlyContinue
    if (-not $resourceGroup) { 
        # If the resource group not found create a new one
        Write-Host "Creating new resource group with name $storageAccountResourceGroup in subscritpion $($subscription.Name)"
        $resourceGroup = New-AzResourceGroup -Name $storageAccountResourceGroup -Location $location
        if ($resourceGroup) { Write-Host "New resource group $($resourceGroup.ResourceGroupName) created successfully" -ForegroundColor Green } 
        else { Write-Error "Failed to create resource group $storageAccountResourceGroup" -ErrorAction Stop }
    }
    
    # Find if the storage account already exist
    $alreadyCreated = $false
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroup.ResourceGroupName -Name $storageAccountName -ErrorAction SilentlyContinue
    if (-not $storageAccount) {
        try {
            # If the storage account not found try to create a new one
            Write-Host "Creating new storage account with name $storageAccountName in resource group $($resourceGroup.ResourceGroupName)"
            $storageAccount = New-AzStorageAccount -Name $storageAccountName -ResourceGroupName $resourceGroup.ResourceGroupName -Location $Location -SkuName $storageAccountSku -Kind $storageAccountKind -PublicNetworkAccess Enabled -ErrorAction Stop
            if ($storageAccount) { Write-Host "New storage account $($storageAccount.StorageAccountName) created successfully" -ForegroundColor Green } 
            else { Write-Error "Failed to create storage account $storageAccountName"  -ErrorAction Stop }
        }
        catch { Write-Error "Failed to create storage account $storageAccountName`n$($Error[0].Exception.Message)" -ErrorAction Stop }
    }
    else { $alreadyCreated = $true }

    # Find if the specified blob container exist in the storage account
    $blobContainer = Get-AzStorageContainer -Name $blobContainerName -Context $storageAccount.Context -ErrorAction SilentlyContinue
    if (-not $blobContainer) {
        try {
            # If the blob container not found in the storage account try to create a new one
            Write-Host "Creating new blob container with name $blobContainerName in resource group $($storageAccount.StorageAccountName)"
            $blobContainer = New-AzStorageContainer -Name $blobContainerName -Context $storageAccount.Context -Permission Off -ErrorAction Stop
            if ($blobContainer) { Write-Host "New blob container $($blobContainer.Name) created successfully" -ForegroundColor Green } 
            else { Write-Error "Failed to create blob container $($blobContainerName)" -ErrorAction Stop }
        }
        catch { Write-Error "Failed to created blob container $storageAccountName`n$($($Error[0].Exception.Message).Split("`n`n")[0])" -ErrorAction Stop }
    }

    # Find if a lifecycle management policy already exist in the storage account for the blob container
    $policy = Get-AzStorageAccountManagementPolicy -StorageAccount $storageAccount -ErrorAction SilentlyContinue
    if (-not $policy) {
        # If the lifecycle management policy not found in the storage account create a new one
        Write-Host "Creating new lifecycle management policy in storage account $($storageAccount.StorageAccountName) for blob container $($blobContainer.Name)"
        # Define the policy action for deleting blobs that haven't been modified after the number of days specified 
        $action = Add-AzStorageAccountManagementPolicyAction -BaseBlobAction Delete -DaysAfterModificationGreaterThan $daysToRemove
        # Define the policy filter to look only for blockBlobs that contains the specified blob container name
        $filter = New-AzStorageAccountManagementPolicyFilter -PrefixMatch $blobContainerName -BlobType blockBlob
        # Define the policy rule for the removal of blobs based on the action and filter varaibles values
        $rule = New-AzStorageAccountManagementPolicyRule -Name "remove-$daysToRemove-days" -Action $action -Filter $filter
        # Create the lifecycle management policy
        $policy = Set-AzStorageAccountManagementPolicy -ResourceGroupName $storageAccount.ResourceGroupName -AccountName $storageAccount.StorageAccountName -Rule $rule
        if ($policy) { Write-Host "New lifecycle management policy created successfully" -ForegroundColor Green }
        else { Write-Error "Failed to create lifecycle management policy" -ErrorAction Stop }
    }

    # If storage account already created print it
    if ($alreadyCreated) { Write-Host "Storage Account $($storageAccount.StorageAccountName) already created in subscription $($subscription.Name)" }
    return $storageAccount.Id
}

# Create different BillCSV exports to a storage account using a specified billing account id
function CreateOrGetBillCSVExports {
    param ([String]$FilePath, [String]$StorageAccountResourceId)
    
    # Default variables
    $costExportsNamePrefix = "Chi"
    $blobContainerName = 'usage-report'
    $blobContainerCostFolderName = 'costexport'
    $actualCostExportName = 'ChiActualCost'
    $amortizedCostExportName = 'ChiAmortizedCost'
    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $billingAccount = $($CSVFile.BillingAccount | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    
    # If the following varaible with the value from the CSV file equal to 'Not Relevant' return a null value from the function
    if ($billingAccount -eq 'Not Relevant') { return $null }
    
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

    # Function for executing the command for creating the BillCSV daily scheduled export with the relevant parameters and values
    function ExportCost {
        param ([String]$ExportName, [String]$DefinitionType, [String]$ResourceId, [String]$ContainerName, [String]$CostFolderName, [String]$BillAccountlId)

        New-AzCostManagementExport -Name $ExportName -ScheduleStatus Active -ScheduleRecurrence Daily -DefinitionTimeframe MonthToDate -DefinitionType $DefinitionType `
            -DataSetGranularity Daily -DestinationResourceId $ResourceId -DestinationContainer $ContainerName -DestinationRootFolderPath $CostFolderName `
            -Format Csv -RecurrencePeriodFrom $(Get-Date -AsUTC) -RecurrencePeriodTo $($(Get-Date -AsUTC).AddYears(20)) -Scope $BillAccountlId
    }


    # Function for executing the command for creating the BillCSV for one time monthly export with the relevant parameters and values
    function ExportCostOneTime {
        param ([String]$ExportName, [String]$DefinitionType, [String]$ResourceId, [String]$ContainerName, [String]$CostFolderName, [String]$BillAccountlId, [Int]$NumberOfMonths)
        # date varaible for getting start of the first day of the month
        $startOfMonth = $($(Get-Date -Date $(Get-Date -AsUTC) -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0)).AddMonths(-$NumberOfMonths)
        # date for getting the end of the last day of the month
        $endOfMonth = $startOfMonth.AddMonths(1).AddTicks(-1)

        New-AzCostManagementExport -Name $ExportName -DefinitionTimeframe Custom -DefinitionType $DefinitionType -DestinationResourceId $ResourceId `
            -DestinationContainer $ContainerName -DestinationRootFolderPath $CostFolderName -Format Csv -Scope $BillAccountlId `
            -TimePeriodFrom $startOfMonth -TimePeriodTo $endOfMonth
    }

    # Function for creating the BillCSV exports
    function CreateCostExport {
        param ([String]$ExportName, [String]$DefinitionType, [String]$ResourceId, [String]$ContainerName, [String]$CostFolderName, [String]$BillAccountlId, [Int]$NumberOfMonths, [String]$OutputMessage)
        
        # Checking if the BillCSV export already have been created
        if (-not $(Get-AzCostManagementExport -Name $ExportName -Scope $BillAccountlId -ErrorAction SilentlyContinue)) {
            # Check what cost export function to use, execute the relevant one to create the export and save the output to a variable
            $costExport = if ($NumberOfMonths) {
                ExportCostOneTime -ExportName $ExportName -DefinitionType $DefinitionType -ResourceId $ResourceId -ContainerName $ContainerName `
                    -CostFolderName $CostFolderName -BillAccountlId $BillAccountlId -NumberOfMonths $NumberOfMonths
            }
            else {
                ExportCost -ExportName $ExportName -DefinitionType $DefinitionType -ResourceId $ResourceId -ContainerName $ContainerName `
                    -CostFolderName $CostFolderName -BillAccountlId $BillAccountlId
            }

            # If th ecost export creation succeeded
            if ($costExport) { 
                Write-Host "New $OutputMessage cost export with name $($costExport.Name) created successfully" -ForegroundColor Green
                # Start the cost export
                $costExport | Invoke-AzCostManagementExecuteExport -Verbose
            }
            else { Write-Error "Failed $OutputMessage actual cost export $ExportName" -ErrorAction Stop }
        }
        else { Write-Host "The $OutputMessage cost export with name $ExportName already exist" }
    }

    # Check and get if the storage account resource id pointing to an existing storage account resource 
    $storageAccountResource = Get-AzResource -ResourceId $StorageAccountResourceId -ErrorAction SilentlyContinue
    if (-not $($storageAccountResource.ResourceType -eq "Microsoft.Storage/storageAccounts")) { Write-Error "No storage account found for given resource id $StorageAccountResourceId" -ErrorAction Stop }
    else {
        $subscription = Get-AzSubscription -SubscriptionId $storageAccountResource.SubscriptionId 
        if ($(Get-AzContext).Subscription.Name -ne $subscription.Name) { 
            # Change to the relevant subscription for the storage account
            $subscriptionCheck = Set-AzContext -SubscriptionName $subscription.Name
            if ($subscriptionCheck) { Write-Host "Changed to subscription $($subscriptionCheck.Name)" -ForegroundColor Green }
            else { Write-Error "Failed to change to subscription $($subscription.Name)" -ErrorAction Stop }
        }
    }

    # If BillCSV should be created by susbcriptions
    if ($billingAccount -eq 'Subscriptions') {
        # Get all enabled subscriptions
        $subscriptions = Get-AzSubscription | Where-Object State -eq Enabled
        # Loop over each subscription found
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

                    # Conigure the virtual folder name in the blob container for the subscription
                    $blobContainerCostFolderName = "$($subscription.Name)_$($subscription.Id)"
                    # Initialize an array of the values for BillCSV scheduled cost export
                    $scheduleExportParameters = @( @("$actualCostExportName`_$($subscription.Id)", "ActualCost", "actual"), @("$amortizedCostExportName`_$($subscription.Id)", "AmortizedCost", "amortized") )

                    # Loop over each of the array values and execute the cost export function using the correct ones
                    $scheduleExportParameters | ForEach-Object {
                        CreateCostExport -ExportName $_[0] -DefinitionType $_[1] -ResourceId $storageAccountResource.ResourceId -ContainerName $blobContainerName `
                            -CostFolderName $blobContainerCostFolderName -BillAccountlId "/subscriptions/$($subscription.Id)" -OutputMessage $_[2]
                    }

                    # Initialize an array of the values for BillCSV one time cost export
                    $oneTimeExportParameters = @( @("$actualCostExportName`_$($subscription.Id)_2_Months", "ActualCost", 2, "one time actual"),
                        @("$amortizedCostExportName`_$($subscription.Id)_2_Months", "AmortizedCost", 2, "one time amortized"),
                        @("$actualCostExportName`_$($subscription.Id)_1_Month", "ActualCost", 1, "one time actual"),
                        @("$amortizedCostExportName`_$($subscription.Id)_1_Month", "AmortizedCost", 1, "one time amortized")
                    )
                    # Loop over each of the array values and execute the cost export function using the correct ones
                    $oneTimeExportParameters | ForEach-Object {
                        CreateCostExport -ExportName $_[0] -DefinitionType $_[1] -ResourceId $storageAccountResource.ResourceId -ContainerName $blobContainerName `
                            -CostFolderName $blobContainerCostFolderName -BillAccountlId "/subscriptions/$($subscription.Id)" -NumberOfMonths $_[2] -OutputMessage $_[3]
                    }
                }
                else { Write-Error "Failed to change to subscription $($subscription.Name)" -ErrorAction Stop }
            }
        }
    }
    else {
        # Check and get if the given billing account id pointing to an existing billing account
        $billingAccountId = Get-AzBillingAccount -ErrorAction SilentlyContinue | Where-Object Id -eq $billingAccount | Select-Object -ExpandProperty Id
        if (-not $billingAccountId) { Write-Error "No billing account with id $billingAccount was found" -ErrorAction Stop }
        CheckRegisterProviders -Providers "Microsoft.CostManagementExports"

        # Initialize an array of the values for BillCSV scheduled cost export
        $scheduleExportParameters = @( @("$actualCostExportName`_$($subscription.Id)", "ActualCost", "actual"), @("$amortizedCostExportName`_$($subscription.Id)", "AmortizedCost", "amortized") )
        # Loop over each of the array values and execute the cost export function using the correct ones
        $scheduleExportParameters | ForEach-Object {
            CreateCostExport -ExportName $_[0] -DefinitionType $_[1] -ResourceId $storageAccountResource.ResourceId -ContainerName $blobContainerName `
                -CostFolderName $blobContainerCostFolderName -BillAccountlId $billingAccountId -OutputMessage $_[2]
        }

        # Initialize an array of the values for BillCSV one time cost export
        $oneTimeExportParameters = @( @("$actualCostExportName`_$($subscription.Id)_2_Months", "ActualCost", 2, "one time actual"),
            @("$amortizedCostExportName`_$($subscription.Id)_2_Months", "AmortizedCost", 2, "one time amortized"),
            @("$actualCostExportName`_$($subscription.Id)_1_Month", "ActualCost", 1, "one time actual"),
            @("$amortizedCostExportName`_$($subscription.Id)_1_Month", "AmortizedCost", 1, "one time amortized")
        )
        # Loop over each of the array values and execute the cost export function using the correct ones
        $oneTimeExportParameters | ForEach-Object {
            CreateCostExport -ExportName $_[0] -DefinitionType $_[1] -ResourceId $storageAccountResource.ResourceId -ContainerName $blobContainerName `
                -CostFolderName $blobContainerCostFolderName -BillAccountlId $billingAccountId -NumberOfMonths $_[2] -OutputMessage $_[3]
        }
    }
}

# Function to assign permissions to Service Principal and Azure AD group by given paramters
function AssignRolesToScope {
    param ([Hashtable]$ObjectIdsRolesTable, [string]$AssignmentScope, [String]$StorageAccountId)

    # Check if one of the passed Azure roles not found or exist in Azure and add it to the array
    $rolesNotFound = @()
    foreach ($objectId in $ObjectIdsRolesTable.Keys) {
        $ObjectIdsRolesTable[$objectId] | ForEach-Object {
            if (-not $(Get-AzRoleDefinition -Name $_ -ErrorAction SilentlyContinue)) { $rolesNotFound += $_ }
        }
    }
    
    # Check if all the roles were found by checking that the array of the not found roles is empty
    if ($rolesNotFound.Length -eq 0) {
        # Check if the desired assignment scope is for subscriptions or management groups
        # After check get all the subscriptions id and format the string as needed or all management groups ids that the user has access to
        # If storage account id was passed to the function find its resource by the id
        $storageAccount = if ($StorageAccountId) { Get-AzResource -ResourceId $StorageAccountId -ErrorAction SilentlyContinue }
        # Check firstly if a storage account was found and save its id to the scopesList varaible
        $scopesList = if ($storageAccount) { $StorageAccountId }
        # Else check if the AssignmentScope parameter was passed and get the relevant ids by the passed paramter value and save them inside the scopesList varaible
        elseif ($AssignmentScope -eq 'Subscriptions') { Get-AzSubscription | Select-Object -ExpandProperty SubscriptionId | ForEach-Object { "/subscriptions/$_" } }
        elseif ($AssignmentScope -eq 'ManagementGroups') { Get-AzManagementGroup | Select-Object -ExpandProperty Id }
        elseif ($AssignmentScope -eq 'Tenant') { "/providers/Microsoft.Management/managementGroups/$($(Get-AzContext).Tenant.Id)" }
        else { Write-Host "No assignment scope was choosed or found" -ForegroundColor Red }

        # If storage account id or one of the other scopes ids were found
        if ($scopesList) {
            # Loop over each scope id in the scopes list variable
            foreach ($scope in $scopesList) {
                # Loop over each of the roles names to assign
                foreach ($objectId in $ObjectIdsRolesTable.Keys) {
                    $ObjectIdsRolesTable[$objectId] | ForEach-Object {
                        # Find if role already been assigned to the object in the current scope iteration
                        if (-not $(Get-AzRoleAssignment -ObjectId $objectId -Scope $scope -RoleDefinitionName $_ -WarningAction SilentlyContinue)) {
                            try {
                                # Assing the role to the object in the current scope iteration
                                $assignment = New-AzRoleAssignment -ObjectId $objectId -Scope $scope -RoleDefinitionName $_ -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                                # Check if the role assigned succeeded or not and print it
                                if ($assignment) { Write-Host "Succefully assigned role $_ to $objectId on scope $scope" -ForegroundColor Green }
                                else { Write-Host "Failed to assign role $_ to $objectId on scope $scope" -ForegroundColor Red }
                            }
                            # If the assigning threw an error that ends with the string 'Conflict' ignore if not print it
                            catch [Microsoft.Azure.Management.Authorization.Models.ErrorResponseException] {
                                if ($Error[0].Exception.Message -notlike "*'Conflict'") { Write-Error $Error[0].Exception.Message }
                            }
                        }
                        else { Write-Host "Role $_ was already assigned to $objectId on scope $scope" }
                    }
                }
            }
        }
        else { Write-Host "No scope ids for assignment were found" -ForegroundColor Red }
    }
    else { Write-Host "Failed to find roles with names: $rolesNotFound" -ForegroundColor Red }
}

# Function to call the AssignRolesToScope function and pass it the relevant parameters
function AssignRolesToScopeAndIdIfExist {
    param ([String]$FilePath, [Hashtable]$ObjectIds, [String]$AssignmentScope, [String]$StorageAccountId)

    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $servicePrincipalStorageAccountRoles = $($CSVFile.ServicePrincipalStorageAccountRoles | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $AzureADGroupStorageAccountRoles = $($CSVFile.AzureADGroupStorageAccountRoles | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $servicePrincipalRoles = $($CSVFile.ServicePrincipalRoles | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $AzureADGroupRoles = $($CSVFile.AzureADGroupRoles | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()

    $objectIdsRolesTable = @{}
    # If object ids for role assignment were passed to the function and a storage account id also was passed
    if ($ObjectIds.Count -ne 0 -and $storageAccountId) {
        # Add to a hashtable an object ids as keys with the relevant role permissions as the values
        if ($ObjectIds['ServicePrincipal'] -and $servicePrincipalStorageAccountRoles) { $objectIdsRolesTable[$ObjectIds['ServicePrincipal']] = $servicePrincipalStorageAccountRoles }
        if ($ObjectIds['AzureADGroup'] -and $AzureADGroupStorageAccountRoles) { $objectIdsRolesTable[$ObjectIds['AzureADGroup']] = $AzureADGroupStorageAccountRoles }
        # Call the AssignRolesToScope for assigning roles to a storage account
        AssignRolesToScope -ObjectIdsRolesTable $objectIdsRolesTable -StorageAccountId $storageAccountId
    }
    # If object ids for role assignment were passed to the function and a assignment scope also was passed
    elseif ($ObjectIds.Count -ne 0 -and $AssignmentScope) {
        # Add to a hashtable an object ids as keys with the relevant role permissions as the values
        if ($ObjectIds['ServicePrincipal'] -and $servicePrincipalRoles) { $objectIdsRolesTable[$ObjectIds['ServicePrincipal']] = $servicePrincipalRoles }
        if ($ObjectIds['AzureADGroup'] -and $AzureADGroupRoles) { $objectIdsRolesTable[$ObjectIds['AzureADGroup']] = $AzureADGroupRoles }
        # Call the AssignRolesToScope for assigning roles to the passed assignment scope
        AssignRolesToScope -ObjectIdsRolesTable $objectIdsRolesTable -AssignmentScope $AssignmentScope
    }
}

if (-not (Get-Command openssl)) {
    if ($IsWindows) {
        Invoke-WebRequest -Method "GET" -Uri "https://mirror.firedaemon.com/OpenSSL/openssl-3.0.5.zip" -OutFile "$($env:TEMP)\openssl-3.zip"
        Expand-Archive -LiteralPath '.\openssl-3.zip' -DestinationPath $env:TEMP
        $RunPath = "$($env:TEMP)\x64\bin\openssl.exe"
    }
}

# This will print and export the removal commands to undo the script operations
if ($ExportUndoAndRemovalCommands.IsPresent) {
    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $servicePrincipalName = $($CSVFile.ServicePrincipal | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $AzureADGroupName = $($CSVFile.AzureADGroup | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $usersList = $($CSVFile.Users | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $storageAccountSubscription = $($CSVFile.StorageAccountSubscription | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $storageAccountResourceGroup = $($CSVFile.StorageAccountResourceGroup | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $storageAccountName = $($CSVFile.StorageAccountName | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()
    $billingAccountId = $($CSVFile.BillingAccountId | Where-Object { $_.PSObject.Properties.Value -ne '' }).Trim()

    # Add a string implementation of each removal commands and an explanation of it to the array variable to print and export the commands to file
    $commandsComments = @()
    $commandsComments += "# Command to remove service principal `"$servicePrincipalName`""
    $commandsComments += "Get-AzADServicePrincipal -DisplayName `"$servicePrincipalName`" | Remove-AzADServicePrincipal -Verbose`n"
    $commandsComments += "# Command to remove Azure ADgroup `"$AzureADGroupName`""
    $commandsComments += "Get-AzADGroup -Filter `"DisplayName eq '$AzureADGroupName'`" | Remove-AzADGroup -Verbose`n"
    $commandsComments += "# Command to remove Azure AD users $($($usersList | ForEach-Object {`"'$_'"}) -join ',')"
    $commandsComments += "$($($usersList | ForEach-Object {`"'$_'"}) -join ',') | ForEach-Object { Get-AzADUser -Filter `"Mail eq '`$_' or UserPrincipalName eq '`$_'`" | Remove-AzADUser -Verbose }`n"
    # If the one of the following varaibles with the values from the CSV file equal to 'Not Relevant' return a null value from the function
    if ($storageAccountSubscription -ne 'Not Relevant' -or $storageAccountName -ne 'Not Relevant') { 
        $commandsComments += "# Command to remove storage account `"$storageAccountName`" in subscription `"$storageAccountSubscription`""
        $commandsComments += "Set-AzContext -SubscriptionName `"$storageAccountSubscription`" | Out-Null; Get-AzStorageAccount -ResourceGroupName `"$storageAccountResourceGroup`" -Name `"$storageAccountName`" | Remove-AzStorageAccount -Verbose`n"
    }
    # If the following varaible with the value from the CSV file equal to 'Not Relevant' return a null value from the function
    if ($billingAccountId -ne 'Not Relevant') {
        $commandsComments += "# Command to remove Azure cost exports: $(Get-AzCostManagementExport -Scope $billingAccountId | Where-Object {$_.Name -Like "ChiActualCost*" -or $_.Name -Like "ChiAmortizedCost*"} | Select-Object -ExpandProperty Name)"
        $commandsComments += "Get-AzCostManagementExport -Scope $billingAccountId | Where-Object {`$_.Name -Like `"ChiActualCost*`" -or `$_.Name -Like `"ChiAmortizedCost*`"} | Remove-AzCostManagementExport -Verbose`n" 
    }
    # Print and Export the array variable
    Write-Host "# Commands to undo the script operations:`n`n$($commandsComments | ForEach-Object {"`r$_`n"})"
    "# Commands to undo the script operations:`n$($commandsComments | ForEach-Object {"`r$_"})" | Out-File "UndoOnboardingScriptCommands.txt" -Verbose
}

# Use this switch to create or get the service principal from CSV file
if ($CreateOrGetServicePrincipal.IsPresent) { CreateOrGetServicePrincipal -FilePath $FilePath }
# Use this switch to create or get the AzureAD group from CSV file
if ($CreateOrGetAzureADGroup.IsPresent) { CreateOrGetAzureADGroup -FilePath $FilePath }
# Use this switch to or get invite guest users from CSV file
if ($InviteOrGetGuestUsers.IsPresent) { InviteOrGetGuestUsers -FilePath $FilePath }

# Use those switches to add existing users to the AzureAD group or invite new users and then add them to the AzureAD group
if ($AddUsersToGroup.IsPresent -and $InviteGuestUsers_AddUsersToGroup.IsPresent) {
    # Get only the AzureAD group id
    $AzureADGroupId = CreateOrGetAzureADGroup -FilePath $FilePath -GetOnly
    # Invite new guest users or only get the existing relevant users
    $guestUsersInvitationIds = if ($InviteGuestUsers_AddUsersToGroup.IsPresent) { InviteOrGetGuestUsers -FilePath $FilePath }
    elseif ($AddUsersToGroup.IsPresent) { InviteOrGetGuestUsers -FilePath $FilePath -GetOnly }
    # If AzureAD group id found and relevant users ids also found call the AddUsersToGroup function to add the users to the AzureAD group
    if ($AzureADGroupId -and $guestUsersInvitationIds.Count -ne 0) { Start-Sleep -Seconds 5; AddUsersToGroup -AzureADGroupId $AzureADGroupId -AzureADUsersIds $guestUsersInvitationIds }
}

# Use this switch to create or get a storage account for the BillCSV export
if ($CreateOrGetStorageAccount.IsPresent) { CreateOrGetStorageAccount -FilePath $FilePath }
# Use those switches to create or get the BillCSV exports to a created storage account or create a new storage account and then create BillCSV exports
if ($CreateOrGetBillCSVExports.IsPresent -or $CreateStorageAccount_CreateOrGetBillCSVExports.IsPresent) {
    # Create a new storage account and get its id or get a created one id
    $storageAccountId = if ($CreateStorageAccount_CreateOrGetBillCSVExports.IsPresent) { CreateOrGetStorageAccount -FilePath $FilePath }
    elseif ($CreateOrGetBillCSVExports.IsPresent) { CreateOrGetStorageAccount -FilePath $FilePath -GetOnly }
    # If storage account id have been found call the CreateOrGetBillCSVExports function to create or get the BillCSV exports
    if ($storageAccountId) { CreateOrGetBillCSVExports -FilePath $FilePath -StorageAccountResourceId $storageAccountId }
}

# Use this switch to assign roles to the service principal and AzureAD group for the BillCSV storage account
if ($AssignRolesToStorageAccount.IsPresent) { 
    # Get the service principal id
    $servicePrincipalId = CreateOrGetServicePrincipal -FilePath $FilePath -GetOnly
    # Get the Azure AD group id
    $AzureADGroupId = CreateOrGetAzureADGroup -FilePath $FilePath -GetOnly
    # Get the storage account id
    $storageAccountId = CreateOrGetStorageAccount -FilePath $FilePath -GetOnly

    # Create a hashtable of each object name as key and the id as value
    $objectsNamesIds = @{}
    $objectsNamesIds['ServicePrincipal'] = $servicePrincipalId
    $objectsNamesIds['AzureADGroup'] = $AzureADGroupId
    # If the storage account id found call the AssignRolesToScopeAndIdIfExist to assign the relevant roles
    if ($storageAccountId) { AssignRolesToScopeAndIdIfExist -FilePath $FilePath -ObjectIds $objectsNamesIds -StorageAccountId $storageAccountId }
}

# Use this switch to assign roles to the service principal and AzureAD group for the passed assignment scope parameter
if ($AssignRolesToScope.IsPresent -and $AssignmentScope) { 
    # Get the service principal id
    $servicePrincipalId = CreateOrGetServicePrincipal -FilePath $FilePath -GetOnly
    # Get the Azure AD group id
    $AzureADGroupId = CreateOrGetAzureADGroup -FilePath $FilePath -GetOnly

    # Create a hashtable of each object name as key and the id as value
    $objectsNamesIds = @{}
    $objectsNamesIds['ServicePrincipal'] = $servicePrincipalId
    $objectsNamesIds['AzureADGroup'] = $AzureADGroupId
    # If the AssignmentScope parameter is used call the AssignRolesToScopeAndIdIfExist to assign the relevant roles
    if ($AssignmentScope) { AssignRolesToScopeAndIdIfExist -FilePath $FilePath -ObjectIds $objectsNamesIds -AssignmentScope $AssignmentScope }
}

# Use this switch to execute all script commands by the relvant order of creation and assingment (assingment phase can be excluded if AssignmentScope parameter not used)
if ($ExecuteAllOnboardingCommands.IsPresent) {
    # Create or get the service principal id from CSV file
    $servicePrincipalId = CreateOrGetServicePrincipal -FilePath $FilePath
    # Create or get the Azure AD group id from CSV file
    $AzureADGroupId = CreateOrGetAzureADGroup -FilePath $FilePath
    # Invite new guest users or only get the existing users from CSV file
    $guestUsersInvitationIds = InviteOrGetGuestUsers -FilePath $FilePath
    # If AzureAD group id found and relevant users ids also found call the AddUsersToGroup function to add the users to the AzureAD group
    if ($AzureADGroupId -and $guestUsersInvitationIds) { Start-Sleep -Seconds 5; AddUsersToGroup -AzureADGroupId $AzureADGroupId -AzureADUsersIds $guestUsersInvitationIds }
    
    # Create or get the storage account for the BillCSV export from CSV file
    $storageAccountId = CreateOrGetStorageAccount -FilePath $FilePath
    # Create or get the BillCSV exports if a storage account id is found
    if ($storageAccountId) { CreateOrGetBillCSVExports -FilePath $FilePath -StorageAccountResourceId $storageAccountId }

    # If AssignmentScope parameter is used
    if ($AssignmentScope) { 
        # Create a hashtable of each object name as key and the id as value
        $objectsNamesIds = @{}
        $objectsNamesIds['ServicePrincipal'] = $servicePrincipalId
        $objectsNamesIds['AzureADGroup'] = $AzureADGroupId
        # If the storage account id found call the AssignRolesToScopeAndIdIfExist to assign the relevant roles to the storage account
        if ($storageAccountId) { AssignRolesToScopeAndIdIfExist -FilePath $FilePath -ObjectIds $objectsNamesIds -StorageAccountId $storageAccountId }
        # # If the AssignmentScope parameter is used call the AssignRolesToScopeAndIdIfExist to assign the relevant roles to the given scope
        AssignRolesToScopeAndIdIfExist -FilePath $FilePath -ObjectIds $objectsNamesIds -AssignmentScope $AssignmentScope 
    }
}