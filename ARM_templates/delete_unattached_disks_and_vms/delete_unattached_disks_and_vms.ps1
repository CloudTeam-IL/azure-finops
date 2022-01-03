######################################################################################################################

#  Copyright 2021 CloudTeam & CloudHiro Inc. or its affiliates. All Rights Reserved.                                 #

#  You may not use this file except in compliance with the License.                                                  #

#  https://www.cloudhiro.com/AWS/TermsOfUse.php                                                                      #

#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES                                                  #

#  OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions    #

#  and limitations under the License.                                                                                #

######################################################################################################################


PARAM(
    [string] $SubscriptionNamePattern = '.*',
    [String]$ConnectionString = $(Get-AutomationVariable -Name 'CONNECTION_STRING'),
    [String]$BlobContainer = $(Get-AutomationVariable -Name 'BLOB_CONTAINER'),
    [string] $ConnectionName = 'AzureRunAsConnection'
)

Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Starting' -f (Get-Date))

try {

    # Login to Azure
    if ($env:AUTOMATION_ASSET_ACCOUNTID) {
        $runAsConnection = Get-AutomationConnection -Name $ConnectionName -ErrorAction Stop
        Add-AzAccount -ServicePrincipal -Tenant $runAsConnection.TenantId -ApplicationId $runAsConnection.ApplicationId `
            -CertificateThumbprint $runAsConnection.CertificateThumbprint -ErrorAction Stop | Out-Null
    }
    # Initialzie the blob stprage connection using the connection string parameter
    $blobStorageContext = New-AzStorageContext -ConnectionString $ConnectionString
    # Get the current time by timezone
    $currentTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($($(Get-Date).ToUniversalTime()), $([System.TimeZoneInfo]::GetSystemTimeZones() | Where-Object {$_.Id -match "Israel"}))
    # Creating the name of the CSV file blob
    $blobName = $("deleted_unattached_disks_and_vms_$(Get-Date -Date $currentTime -Format 'dd-MM-yyyy_HH:mm:ss').csv")
    # Craeting the temporary local CSV file
    New-Item -Name "tempFile.csv" -ItemType File -Force | Out-Null
    # Copying the the temporary CSV file to the blob storage container as an append blob
    Set-AzStorageBlobContent -File ".\tempFile.csv" -Blob $blobName -Container $BlobContainer -BlobType Append -Context $blobStorageContext -Force | Out-Null
    # Get the CSV file blob from the container in the storage account
    $blobStorage = Get-AzStorageBlob -Blob $blobName -Container $BlobContainer -Context $blobStorageContext
    # Add the header to the CSV file
    $blobStorage.ICloudBlob.AppendText("subscription_name,resource_group,location,resource_id,size,tags`n")


    # Iterate all subscriptions
    Get-AzSubscription | Where-Object { ($_.Name -match ".*") -and ($_.State -eq 'Enabled') } | ForEach-Object {
        $subscriptionName = $_.Name
        Write-Output ('Switching to subscription: {0}' -f $_.Name)
        $null = Set-AzContext -SubscriptionObject $_ -Force
    
          

        $tagname = "Candidate"
        $TagValue = "DeleteMe"
        $taggedResourcesVms = Get-AzResource -ResourceType Microsoft.Compute/virtualMachines -TagName $tagname -TagValue $TagValue
        $taggedResourcesDisks = Get-AzResource -ResourceType Microsoft.Compute/Disks -TagName $tagname -TagValue $TagValue

        
    # Iterate all Vms with specific tag key 'bla'(replace bla with your key name you want to filter out!)
        foreach ( $resource in $taggedResourcesVms) {
            if (!$resource.tags.bla) {
                $vmSize = Get-AzVM -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name
                $tags = $resource.Tags.GetEnumerator() | ForEach-Object {"$($_.Key): $($_.Value)"} 
                $blobStorage.ICloudBlob.AppendText("$subscriptionName, $($resource.ResourceGroupName), $($resource.location), $($resource.ResourceId), $($vmSize.HardwareProfile.VmSize), $($tags)`n")
                Write-Output('will remove {0} resources' -f $resource.Count) 
                Remove-AzResource -ResourceId $resource.Id -Force

                
            }
        }
    # Iterate all Disks with specific tag key 'bla' (replace bla with your key name you want to filter out!)
        foreach ( $resource in $taggedResourcesDisks) {
            if (!$resource.tags.bla) {
                $excludeAttachedDisks = "Attached"
                $tags = $resource.Tags.GetEnumerator() | ForEach-Object {"$($_.Key): $($_.Value)"} 
                $diskInfo = Get-AzDisk -ResourceGroupName $resource.ResourceGroupName -DiskName $resource.Name | Where-Object {$excludeAttachedDisks -notcontains $_.DiskState}
                $blobStorage.ICloudBlob.AppendText("$subscriptionName, $($resource.ResourceGroupName), $($resource.location), $($resource.ResourceId), $($diskInfo.DiskSizeGB), $($tags)`n")
                Write-Output('will remove {0} resources' -f $resource.Count)
                Remove-AzResource -ResourceId $diskInfo.Id -Force
            }
        }
        
    }
}
    

catch {
    Write-Output ($_)
}
finally {
    Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Completed' -f (Get-Date))
}




