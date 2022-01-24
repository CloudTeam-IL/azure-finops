<#
  .SYNOPSIS
  CloudTeam & CloudHiro onboarding script for clients

  .DESCRIPTION
  The Onboarding.ps1 script using a CSV file and different parameters to do the following:
  - Create a service principal
  - Create an Azure AD group
  - Invite external users
  - Add users to Azure AD group
  - Assign roles to the service principal and Azure AD group
  For undoing and removing all those operation another paramters exist also

  .PARAMETER FilePath
  Specifies the path to the CSV file.

  .PARAMETER AssignmentScope
  Choosing on which scope to apply the role assingnment: Subscriptions or Management Groups.

  .PARAMETER ExportUndoCommands
  Undoing and removing all other script operations.

  .INPUTS
  None. You cannot pipe objects to Onboarding.ps1.

  .OUTPUTS
  Different for each of the Switch based parameters

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -CreateServicePrincipal

  .EXAMPLE
  PS>  ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -CreateAzureADGroup

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -InviteGuestUsers

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -AddUsersToGroup

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -AssignServicePrincipalRoles -AssignAzureADGroupRoles -AssignmentScope Subscritpions

  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -AssignServicePrincipalRoles -AssignmentScope ManagementGroups
  
  .EXAMPLE
  PS> ./Onboarding.ps1 -FilePath ./OnBoardingData.csv -AssignAzureADGroupRoles -AssignmentScope Subscritpions
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

    [Parameter(ParameterSetName = 'CreateServicePrincipal')]
    [Switch]$CreateServicePrincipal,

    [Parameter(ParameterSetName = 'CreateAzureADGroup')]
    [Switch]$CreateAzureADGroup,

    [Parameter(ParameterSetName = 'InviteGuestUsers')]
    [Switch]$InviteGuestUsers,

    [Parameter(ParameterSetName = 'AddUsersToGroup')]
    [Switch]$AddUsersToGroup,

    [Parameter(ParameterSetName = 'AssignRoles')]
    [Switch]$AssignServicePrincipalRoles,

    [Parameter(ParameterSetName = 'AssignRoles')]
    [Switch]$AssignAzureADGroupRoles,

    [Parameter(ParameterSetName = 'AssignRoles')]
    [ValidateSet('Subscriptions', "ManagementGroups")]
    [String]$AssignmentScope,

    [Parameter(ParameterSetName = 'ExportUndoCommands')]
    [Switch]$ExportUndoCommands
)

# Check if connected to AzureAD and ARM if not connect 
if (-not $(Get-AzContext -ErrorAction SilentlyContinue)) { Connect-AzAccount }
try { Get-AzureADDomain | Out-Null } catch { AzureAD.Standard.Preview\Connect-AzureAD -Identity -TenantID $env:ACC_TID }

# Create Service Principal
if ($CreateServicePrincipal.IsPresent) {
    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $servicePrincipalName = $CSVFile.ServicePrincipal | Where-Object { $_.PSObject.Properties.Value -ne '' }

    if ($servicePrincipalName) {
        # Create the service principal with RBAC authintication and a certificate
        $servicePrincipal = $(az ad sp create-for-rbac -n $servicePrincipalName --create-cert --only-show-errors)
        # Get the newly create service principal 
        $servicePrincipalExist = Get-AzADServicePrincipal -DisplayName $servicePrincipalName
        if ($servicePrincipalExist) {
            # Export to file and print the service principal info
            Write-Host "Exporting Service Principal Info to $($servicePrincipalName)SP.json" 
            $servicePrincipal | Out-File -FilePath .\$($servicePrincipalName)SP.json -Verbose
            Write-Host "Service Principal $($servicePrincipalName):" -ForegroundColor Green; $servicePrincipal
        }
        else { Write-Host "Failed to create and get the Service Principal" -ForegroundColor Red }
    }
    else { Write-Host "No Service Principal was found in CSV file" -ForegroundColor Red }
}

# Create Azure AD Group
if ($CreateAzureADGroup.IsPresent) {
    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $AzureADGroupName = $CSVFile.AzureADGroup | Where-Object { $_.PSObject.Properties.Value -ne '' }

    if ($AzureADGroupName) {
        # Check if the Azure AD group already exist
        $AzureADGroupExist = Get-AzADGroup -DisplayName $AzureADGroupName -ErrorAction SilentlyContinue
        if (-not $AzureADGroupExist) {
            # Create the Azure AD group as a Security group
            $AzureADGroup = New-AzADGroup -DisplayName $AzureADGroupName -MailNickname $AzureADGroupName -SecurityEnabled
            # Check and print if the Azure AD group created or not
            if ($AzureADGroup) { Write-Host "Azure AD group $($AzureADGroup.DisplayName) created" -ForegroundColor Green }
            else { Write-Host "Failed to create and get Azure AD group" -ForegroundColor Red }
        }
        else { Write-Host "Azure AD Group with name $AzureADGroupName already exists in Azure AD" -ForegroundColor Red }
    }
    else { Write-Host "No Azure AD group was found in CSV file" -ForegroundColor Red }
}

# Send and invitation for external users
if ($InviteGuestUsers.IsPresent) {
    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $usersList = $CSVFile.Users | Where-Object { $_.PSObject.Properties.Value -ne '' }

    if ($usersList) {
        # Loop over the list of users from the CSV file varaible
        $usersList | ForEach-Object {
            # Check if a user with the same Mail address or UserPrincipalName already exist in Azure AD
            $AzureADUser = Get-AzADUser -Mail $_ -ErrorAction SilentlyContinue | Where-Object { $_.UserPrincipalName -like "$($([String]$_).Replace("@", "_"))*" } 
            if (-not $AzureADUser) {
                # Send and invitaiton to the external user using his Mail address
                $invitation = New-AzureADMSInvitation -InvitedUserEmailAddress $_ -InviteRedirectUrl 'https://myapps.microsoft.com' -SendInvitationMessage $true -Verbose 
                # Check if invitation sent to the correct user and is in pending state
                if ($invitation.InvitedUserEmailAddress -eq $_ -and $invitation.Status -eq "PendingAcceptance") { Write-Host "Invitation sent to $_ and pending acceptance" -ForegroundColor Green }
                else { Write-Host "Failed to send invitation to $_" -ForegroundColor Red }
            }
            else { Write-Host "Azure AD User with mail $_ exists in Azure AD" -ForegroundColor Red }
        }
    }
    else { Write-Host "No users were found in CSV file" -ForegroundColor Red }
}

# Add users (external and internal) to Azure AD group
if ($AddUsersToGroup.IsPresent) {
    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $usersList = $CSVFile.Users | Where-Object { $_.PSObject.Properties.Value -ne '' }
    $AzureADGroupName = $CSVFile.AzureADGroup | Where-Object { $_.PSObject.Properties.Value -ne '' }

    if ($usersList -and $AzureADGroupName) {
        # Loop over the list of users from the CSV file varaible
        $AzureADUsers = $usersList | ForEach-Object {
            $mail = $_
            # Find each user by his Mail address and then also the UserPrincipalName (for external users)
            $user = Get-AzADUser -Mail $mail -ErrorAction SilentlyContinue | Where-Object { $_.UserPrincipalName -like "$($([String]$mail).Replace("@", "_"))*" }
            # If user not found look for the user by his UserPrincipalName (for internal users)
            if (-not $user) { $user = Get-AzADUser -UserPrincipalName $mail -ErrorAction SilentlyContinue }
            # Return the user object or print a message if the user not found
            if ($user) { $user }
            else { Write-Host "No Azure AD user with Mail or UserPrincipalName of $mail was found" -ForegroundColor Red }
        }

        # If users were found
        if ($AzureADUsers) {
            # Find and get the Azure AD Group
            $AzureADGroup = Get-AzADGroup -DisplayName $AzureADGroupName -ErrorAction SilentlyContinue
            if ($AzureADGroup) {
                # Add the users to the Azure AD group
                Add-AzADGroupMember -TargetGroupDisplayName $AzureADGroup.DisplayName -MemberUserPrincipalName $AzureADUsers.UserPrincipalName -ErrorAction SilentlyContinue -Verbose
                Start-Sleep -Seconds 5
                # Get all the Azure AD Group members
                $groupMembers = Get-AzADGroupMember -GroupDisplayName $AzureADGroup.DisplayName
                # If users were found in group print them
                if ($groupMembers) { Write-Host "The following users are members of $($AzureADGroupName):" -ForegroundColor Green; $groupMembers }
                else { Write-Host "No users were found in $AzureADGroupName" -ForegroundColor Red }
            }
            else { Write-Host "No Azure AD group with name $AzureADGroupName was found" -ForegroundColor Red }
        }
        else { Write-Host "No users were found to add to Azure AD group" -ForegroundColor Red }
    }
    else { Write-Host "No Azure AD users or Azure AD Group were found in CSV file" -ForegroundColor Red }
}

# Assing permissions to Service Principal or Azure AD group or both
if ($($AssignServicePrincipalRoles.IsPresent -or $AssignAzureADGroupRoles.IsPresent) -and $AssignmentScope) {
    # Get and import the CSV file
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    
    # Function for assigning roles for Service Principal or Azure AD group 
    function AssignRoles {
        param (
            [ValidateNotNullOrEmpty()]
            $ObjectName, 
            [ValidateSet('ServicePrincipal', 'AzureADGroup')]
            $ObjectType,
            [ValidateNotNullOrEmpty()]
            $RolesNames
        )
        
        # Check if the relevant object is a service principal or Azure AD group and get the relevant object by it
        $object = if ($ObjectType -eq 'ServicePrincipal') { Get-AzADServicePrincipal -DisplayName $ObjectName }
        elseif ($ObjectType -eq 'AzureADGroup') { Get-AzADGroup -DisplayName $AzureADGroupName -ErrorAction SilentlyContinue }
        # Find each azure role definition object
        $roles = $RolesNames | ForEach-Object { Get-AzRoleDefinition -Name $_ }
        
        # If the service principal or Azure AD group were found and the number of roles found is the same as was in the CSV file
        if ($object -and $roles.Length -eq $RolesNames.Length) {
            # Check if the desired assignment scope is for subscriptions or management groups
            # After check get all the subscriptions id and format the string as needed or all management groups ids that the user has access to
            $scopesList = if ($AssignmentScope -eq 'Subscriptions') { Get-AzSubscription | Select-Object -ExpandProperty SubscriptionId | ForEach-Object { "/subscriptions/$_" } }
            elseif ($AssignmentScope -eq 'ManagementGroups') { $scopesList = Get-AzManagementGroup | Select-Object -ExpandProperty Id }
            else { Write-Host "No assignment scope was choosed" -ForegroundColor Red }

            # If subscriptions or management group were found
            if ($scopesList) {
                # Loop over each scope id in the scopes list variable
                foreach ($scope in $scopesList) {
                    # Loop over each of the roles names to assign
                    $roles.Name | ForEach-Object {
                        # Find if role already been assigned to the object in the current scope iteration
                        if (-not $(Get-AzRoleAssignment -ObjectId $object.Id -Scope $scope -RoleDefinitionName $_ -WarningAction SilentlyContinue)) {
                            # Assing the role to the object in the current scope iteration
                            $assignment = New-AzRoleAssignment -ObjectId $object.Id -Scope $scope -RoleDefinitionName $_ -WarningAction SilentlyContinue
                            # Check if the role assigned succeeded or not and print it
                            if ($assignment) { Write-Host "Succefully assigned role $_ was already assigned to $ObjectName on scope $scope" -ForegroundColor Green }
                            else { Write-Host "Failed to assign role $_ was already assigned to $ObjectName on scope $scope" -ForegroundColor Red }
                        }
                        else { Write-Host "Role $_ was already assigned to $ObjectName on scope $scope" }
                    }
                }
            }
            else { Write-Host "No scope ids for assignment were found" -ForegroundColor Red }
        }
        else { 
            # Check if no object was found with the name from the CSV file and print it
            if (-not $object) { Write-Host "Failed to object of $ObjectName" -ForegroundColor Red }
            # Check if no roles at all were found and print it 
            if (-not $roles) { Write-Host "Failed to find roles with names: $RolesNames" -ForegroundColor Red }
            # Check if specific roles only were not found while others did and print the ones not found 
            else { Write-Host "Failed to find roles with names: $($RolesNames | Where-Object {$_ -notin $roles.Name})" -ForegroundColor Red }
        }
    }

    # Assing roles to Service Principal
    if ($AssignServicePrincipalRoles.IsPresent) {
        # Get the data from the relevant collumn from the CSV file variable
        $servicePrincipalName = $CSVFile.ServicePrincipal | Where-Object { $_.PSObject.Properties.Value -ne '' }
        $servicePrincipalRoles = $CSVFile.ServicePrincipalRoles | Where-Object { $_.PSObject.Properties.Value -ne '' }
        
        # Check if service principal and designated service principal roles have values and run the AssignRoles function
        if ($servicePrincipalName -and $servicePrincipalRoles) { AssignRoles -ObjectName $servicePrincipalName -ObjectType 'ServicePrincipal' -RolesNames $servicePrincipalRoles }
        else { Write-Host "No Service Principal or Service Principal Roles were found in CSV file" -ForegroundColor Red }
    }

    # Assing roles to Azure AD group
    if ($AssignAzureADGroupRoles.IsPresent) {
        # Get the data from the relevant collumn from the CSV file variable
        $AzureADGroupName = $CSVFile.AzureADGroup | Where-Object { $_.PSObject.Properties.Value -ne '' }
        $AzureADGroupRoles = $CSVFile.AzureADGroupRoles | Where-Object { $_.PSObject.Properties.Value -ne '' }

        # Check if Azure AD group and designated Azure AD group roles have values and run the AssignRoles function
        if ($AzureADGroupName -and $AzureADGroupRoles) { AssignRoles -ObjectName $AzureADGroupName -ObjectType 'AzureADGroup' -RolesNames $AzureADGroupRoles }
        else { Write-Host "No Azure AD Group or Azure AD Group Roles were found in CSV file" -ForegroundColor Red }
    }
}

# This will print and export the removal commands to undo the script operations
if ($ExportUndoCommands.IsPresent) {
    # Get and import the CSV file, after that get the data from the relevant collumn
    $path = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
    $CSVFile = Import-Csv -Path $path -ErrorAction SilentlyContinue
    $servicePrincipalName = $CSVFile.ServicePrincipal | Where-Object { $_.PSObject.Properties.Value -ne '' }
    $AzureADGroupName = $CSVFile.AzureADGroup | Where-Object { $_.PSObject.Properties.Value -ne '' }
    $usersList = $CSVFile.Users | Where-Object { $_.PSObject.Properties.Value -ne '' }

    # Add a string implementation of each removal commands to the array variable
    $commands = @()
    $commands += "Get-AzADServicePrincipal -DisplayName `"$servicePrincipalName`" | Remove-AzADServicePrincipal -Verbose"
    $commands += "Get-AzADGroup -Filter `"DisplayName eq '$AzureADGroupName'`" | Remove-AzADGroup -Verbose"
    $commands += "$($($usersList | ForEach-Object {`"'$_'"}) -join ',') | ForEach-Object { Get-AzADUser -Filter `"Mail eq '`$_' or UserPrincipalName eq '`$_'`" | Remove-AzADUser -Verbose }"
    # Print and Export the commands array variable
    Write-Host "Commands to undo the script operations:`n$($commands | ForEach-Object {"`r$_`n"})"
    "Commands to undo the script operations:$($commands | ForEach-Object {"`r$_"})" | Out-File "UndoOnboardingScriptCommands.txt" -Verbose
}
