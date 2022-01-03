######################################################################################################################

#  Copyright 2021 CloudTeam & CloudHiro Inc. or its affiliates. All Rights Reserved.                                 #

#  You may not use this file except in compliance with the License.                                                  #

#  https://www.cloudhiro.com/AWS/TermsOfUse.php                                                                      #

#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES                                                  #

#  OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions    #

#  and limitations under the License.                                                                                #

######################################################################################################################

Param (
    # Default parameter for connection with azure
    [String]$ConnectionName = 'AzureRunAsConnection',
    # Default paramters using the runbooks variables
    [String]$ExcludeSubscriptions = $(Get-AutomationVariable -Name 'excludedSubscriptions'),
    [String]$BlobContainer = $(Get-AutomationVariable -Name 'BlobContainer'),
    [String]$BlobContainerCT = $(Get-AutomationVariable -Name 'BlobContainerCT'),
    [String]$ConnectionString = $(Get-AutomationVariable -Name 'ConnectionString'),
    [String]$ConnectionStringCT = $(Get-AutomationVariable -Name 'ConnectionStringCT'),
    [Int]$Minutes = $(Get-AutomationVariable -Name 'minutes'),
    [Int]$Hours = $(Get-AutomationVariable -Name 'houres'),
    [Int]$Days = $(Get-AutomationVariable -Name 'days'),
    # Default time date paramters
    [String]$TimeZone = 'Israel',
    [String]$DateTimeFormat = 'dd/MM/ss HH:mm:ss'

)
# Function to the current correct time and date by time zone and in specific format 
function Get-CurrentTime {
    param ([String]$CurrentTimeZone, [String]$TimeDateFormat)
    # Get the current time and date by speciific time zone of the command failes get the default time from the system 
    $currentTimeFormatted = try {
        $currentTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($($(Get-Date).ToUniversalTime()), $([System.TimeZoneInfo]::GetSystemTimeZones() | 
        Where-Object {$_.Id -match $CurrentTimeZone}))
        Get-Date -Date $currentTime -Format $TimeDateFormat
    } catch {
        Get-Date -Format $TimeDateFormat
    }
    return $currentTimeFormatted
}
# Function to find a specific CSV file in blob storage and if not found create one if needed
function Find-BlobStorageCSVFile {
    param ([String]$BlobName, [String]$BlobFileHeader, [String]$BlobContainer, [String]$ConnectionString, [Bool]$CreateIfNotExit, [Bool]$BlobFilter)
    # Checks if the blob name and the csv blob headers paramter was passed
    if ($BlobName -and $BlobFileHeader) {
        # Tries to create connection to the storage accounr of the blob using a connection string
        $blobStorageContext = try {New-AzStorageContext -ConnectionString $ConnectionString -ErrorAction SilentlyContinue} catch {$null}
        $blobStorage = if ($blobStorageContext) {
            try {
                # If the blob filter paramter is used and true try to find all blobs contains the name of the blob and return only the last modified one 
                if ($BlobFilter) {
                    Get-AzStorageBlob -Container $BlobContainer -Context $blobStorageContext -ErrorAction SilentlyContinue | 
                    Where-Object {$_.Name -like "*$blobName*.csv"} | Sort-Object -Property LastModified -Descending | Select-Object -First 1
                #  If no blob filter parameter was passed or it's false, find a blob with the passed blob name parameter excatly
                } else {
                    Get-AzStorageBlob -Blob $BlobName -Container $BlobContainer -Context $blobStorageContext -ErrorAction SilentlyContinue
                }
            } catch {$null}
        # If the CreateIfNotExit param was passed and true and no blob csv file was found try to create a new one
        } 
        if ($CreateIfNotExit -and (-not $blobStorage)) {
            # Create an empty new CSV file locally
            New-Item -Name "tempFile.csv" -ItemType File -Force | Out-Null
            # Copy the empty CSV file to the blob storage container and give him the ne name from the blob name paramter
            Set-AzStorageBlobContent -File ".\tempFile.csv" -Blob $BlobName -Container $BlobContainer -BlobType Append -Context $blobStorageContext -Force | Out-Null
            # Get the blob CSV file object
            $blobStorage = Get-AzStorageBlob -Blob $BlobName -Container $BlobContainer -Context $blobStorageContext
            # Append to the blob CSV file the headers passed in the BlobFileHeader parameter
            $blobStorage.ICloudBlob.AppendText("$BlobFileHeader`n")
        }
        # return the blob object
        return $blobStorage
    } else {
        # If failed return null object
        return $null
    }
}

Write-Output "Script execution started at $(Get-CurrentTime -CurrentTimeZone $TimeZone -TimeDateFormat $DateTimeFormat)`n"

# If running in a runbook environment authenticate with Azure using the Azure Automation RunAs service principal and adding the account to the session 
if ($env:AUTOMATION_ASSET_ACCOUNTID) {
    $runAsConnection = Get-AutomationConnection -Name $ConnectionName -ErrorAction Stop
    Add-AzAccount -ServicePrincipal -Tenant $runAsConnection.TenantId -ApplicationId $runAsConnection.ApplicationId `
        -CertificateThumbprint $runAsConnection.CertificateThumbprint -ErrorAction Stop | Out-Null
}
# Getting excluded subscriptions names from runbook variable
$excludedSubscriptions = @(foreach ($sub in $ExcludeSubscriptions.Split(',')) {$sub.Trim()})

# Get object of a date by the number of minutes/hours/days specified
$date = $($($(Get-Date).AddDays(-$Days)).AddHours(-$Hours)).AddMinutes(-$Minutes)

try {
    # Create the blob CSV file name wth the current date and time
    $blobName = $("unused_subscriptions_$(Get-CurrentTime -CurrentTimeZone $TimeZone -TimeDateFormat 'dd-MM-yyyy_HH:mm:ss').csv")
    # Create the blob CSV file for the Client and for CloudTeam
    $blobStorageFile = Find-BlobStorageCSVFile -BlobName $blobName -BlobFileHeader "subscription_name,subscription_id" -BlobContainer $BlobContainer -ConnectionString $ConnectionString -CreateIfNotExit $true
    $blobStorageCTFile = Find-BlobStorageCSVFile -BlobName $blobName -BlobFileHeader "subscription_name,subscription_id" -BlobContainer $BlobContainerCT -ConnectionString $ConnectionStringCT -CreateIfNotExit $true

    $subscriptionsList = @()
    $subscriptionsListExcluded = @()
    # Get all subscriptions that the account can access and their State is Enabled, after that iterate over them
    Get-AzSubscription | Where-Object {$_.State -eq 'Enabled'} | ForEach-Object {
        # If the subscription not in the excluded subscription list get it id and name
        if ($_.Name -notin $excludedSubscriptions) {
            $subscriptionsList += [PSCustomObject]@{
                subscription_id = $_.Id
                subscription_name = $_.Name
            }
        # Else get the excluded subscription name only
        } else {
            $subscriptionsListExcluded += $_.Name
        }
    }

    # Print to the screen the number of excluded subscriptions and the subscriptions themselves 
    Write-Output "Number of excluded subscriptions: $($subscriptionsListExcluded.Length)`n`rExcluded subscriptions names: $($subscriptionsListExcluded -join ', ')"
    # Print to the screen the number of subscriptions and the subscriptions themselves 
    Write-Output "Number of subscriptions: $($subscriptionsList.Length)`n`rSubscriptions names: $($subscriptionsList.subscription_name -join ', ')"

    # If subscriptions have benn found for checking the logs
    if ($subscriptionsList) {
        # Loop over the subscriptions
        foreach ($sub in $subscriptionsList) {
            # Initialze an empty logs variable for populating each iteration if needed
            $logs = $null
            # Set the current Azure subscription for use
            $azContext = Set-AzContext -SubscriptionId $sub.subscription_id -Force -ErrorAction SilentlyContinue
            
            # Checki if the current subscription id equal to the one from the current iteration varaible
            if ($azContext.Subscription.Id -eq $sub.subscription_id) {
                Write-Output "Checking activity logs of subscription: $($sub.subscription_name)"

                # Get the activity logs in the current subscription by:
                # If the 'caller' username is in the format of an Azure AD user principal name
                # If the event dictionary have the user ip address and a user full name
                $logs = Get-AzActivityLog -StartTime $date -WarningAction SilentlyContinue | 
                Where-Object {$_.Caller -like "*@*.*" -and $_.Claims.Content.ContainsKey('name') -and $_.Claims.Content.ContainsKey('ipaddr')}
            } else {
                # If failed to set/cange to the subscription in the current iteration varaible
                Write-Output "Failed to set/change subscription $($sub.subscription_name) with id $($sub.subscription_id)"
            }

            # Check if activity logs were found
            if ($logs) {
                # If activity logs were found append to the CSV file
                $blobStorageFile.ICloudBlob.AppendText("$($sub.subscription_name),$($sub.subscription_id)`n")
                if ($blobStorageCTFile) {
                    $blobStorageCTFile.ICloudBlob.AppendText("$($sub.subscription_name),$($sub.subscription_id)`n")
                }
            } else {
                # If no activity logs were
                Write-Output "No activity logs or modification from $date were found in subscription: $($sub.subscription_name)"
            }
        }
    } else {
        Write-Output "No subscriptions have been found or all subscriptions are excluded"
    }
} catch  {
    throw "$($Error[0].Exception.Message)"
} finally {
    Write-Output "`nScript execution finished at $($(Get-CurrentTime -CurrentTimeZone $TimeZone -TimeDateFormat $DateTimeFormat))"
}