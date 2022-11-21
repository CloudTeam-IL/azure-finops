######################################################################################################################

#  Copyright 2021 CloudTeam & CloudHiro Inc. or its affiliates. All Rights Reserved.                                 #

#  You may not use this file except in compliance with the License.                                                  #

#  https://www.cloudhiro.com/AWS/TermsOfUse.php                                                                      #

#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES                                                  #

#  OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions    #

#  and limitations under the License.                                                                                #

######################################################################################################################


PARAM(
    [parameter (Mandatory = $false)]
    [string] $AccountType = "ManagedIdentity",
    [parameter (Mandatory = $false)]
    [string] $AccountName = "",
    [parameter (Mandatory = $true)]
    [string] $SubForLog,
    [parameter (Mandatory = $true)]
    [string] $ResourceGroupName,
    [parameter (Mandatory = $true)]
    [string] $StorageAccName,
    [parameter (Mandatory = $true)]
    [String] $BlobContainerName
)

Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Starting' -f (Get-Date))

try {

    # Login to Azure
    if ($env:AUTOMATION_ASSET_ACCOUNTID) {
        if ($AccountType -eq "ServicePrincipal") {
            $runAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection" -ErrorAction Stop
            Add-AzAccount -ServicePrincipal -Tenant $runAsConnection.TenantId -ApplicationId $runAsConnection.ApplicationId `
                -CertificateThumbprint $runAsConnection.CertificateThumbprint -ErrorAction Stop | Out-Null
        }
        elseif ($AccountType -eq "ManagedIdentity") {
            if (!$AccountName) {
                Connect-AzAccount -Identity
            }
            else {
                $ID = Get-AutomationVariable -Name $AccountName
                Connect-AzAccount -Identity -AccountId $ID
            }
        }
    }
    else {
        Connect-AzAccount
    }
    # Initialzie the blob stprage connection using the connection string parameter
    Set-AzContext -SubscriptionName $SubForLog
    $StorageAcc = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccName
    $ctx = $StorageAcc.Context
    # Get the current time by timezone
    $CurrentTime = Get-Date -Format "dd-MM-yyyy_HH:mm:ss"
    $CurrentDate = Get-Date -Format "dd-MM-yyyy"
    # Creating the name of the CSV file blob
    $blobName = $("deleted_unattached_disks_and_vms_$($CurrentTime).csv")
    # Craeting the temporary local CSV file
    New-Item -Name "tempFile.csv" -ItemType File -Force | Out-Null
    # Copying the the temporary CSV file to the blob storage container as an append blob
    Set-AzStorageBlobContent -File ".\tempFile.csv" -Blob $blobName -Container $BlobContainerName -BlobType Append -Context $ctx -Force | Out-Null
    # Get the CSV file blob from the container in the storage account
    $blobStorage = Get-AzStorageBlob -Blob $blobName -Container $BlobContainerName -Context $ctx
    # Add the header to the CSV file
    $blobStorage.ICloudBlob.AppendText("subscription_name,resource_group,location,resource_id,size,tags`n")

    $tagname = "Candidate"
    $TagValue = "DeleteMe"
    # Iterate all subscriptions
    $subs = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
    foreach ($sub in $subs ) {
        $subscriptionName = $sub.Name
        Write-Output ('Switching to subscription: {0}' -f $sub.Name)
        $null = Set-AzContext -SubscriptionObject $sub -Force

        $taggedResourcesVms = Get-AzResource -ResourceType "Microsoft.Compute/virtualMachines" -TagName $tagname -TagValue $TagValue
        $taggedResourcesDisks = Get-AzResource -ResourceType "Microsoft.Compute/Disks" -TagName $tagname -TagValue $TagValue
        #itterating over all the vms with the tag and deleting them
        foreach ( $resource in $taggedResourcesVms) {
            if ($resource.tags.Candidate) {
                Write-Host "test"
                $vmSize = Get-AzVM -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name
                $changed = $false
                if ($vmSize.StorageProfile.OsDisk.DeleteOption -ne "Detach") {
                    $vmSize.StorageProfile.OsDisk.DeleteOption = "Detach"
                    $changed = $true
                }
                for ($i = 0; $i -lt $vmSize.StorageProfile.DataDisks.Count; $i++) {
                    if ($vmSize.StorageProfile.DataDisks[$i].DeleteOption -ne "Detach") {
                        $vmSize.StorageProfile.DataDisks[$i].DeleteOption = "Detach"
                        $changed = $true
                    }
                }
                if ($changed) {
                    Write-Output "detaching disks from vms and deleting the vms"
                    if (-not (update-azvm -VM $vmSize -ResourceGroupName $vmSize.ResourceGroupName -ErrorAction SilentlyContinue)) {
                        Write-Host "couldnt update vm"
                        continue
                    }
                }
                $tags = $resource.Tags.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" } 
                $blobStorage.ICloudBlob.AppendText("$subscriptionName, $($resource.ResourceGroupName), $($resource.location), $($resource.ResourceId), $($vmSize.HardwareProfile.VmSize), $($tags)`n")
                Write-Output "will delete $($resource.Id)"
                Remove-AzResource -ResourceId $resource.Id -Force
            }
        }
        #itterating over all the disks of the deleted vms, snapshotting them, and deleting them.
        foreach ($resource in $taggedResourcesDisks) {
            if ($resource.tags.Candidate) {
                $excludeAttachedDisks = "Attached"
                # $tags = $resource.Tags.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" } 
                if ($diskInfo = Get-AzDisk -ResourceGroupName $resource.ResourceGroupName -DiskName $resource.Name | Where-Object { $excludeAttachedDisks -notcontains $_.DiskState }) {
                    Write-Output "----Snapshot $($disk.Name)----"
                    $snapshot = New-AzSnapshotConfig -SourceUri $diskInfo.Id -Location $diskInfo.Location -CreateOption copy
                    #creating the new snapshot
                    $newSnapshot = New-AzSnapshot -Snapshot $snapshot -SnapshotName "$($diskInfo.Name)-Snapshot1" -ResourceGroupName $diskInfo.ResourceGroupName -ErrorAction SilentlyContinue
                    Write-Host "here"
                    #adding tag to delete after 90 days
                    if ($newSnapshot) {
                        Update-AzTag -ResourceId $newSnapshot.Id -Tag @{"MarkedForDelete" = $CurrentDate } -Operation Merge
                        $blobStorage.ICloudBlob.AppendText("$subscriptionName, $($resource.ResourceGroupName), $($resource.location), $($resource.ResourceId), $($diskInfo.DiskSizeGB), $($tags)`n")
                        Write-Output "will delete $($resource.Id)"
                        Remove-AzResource -ResourceId $diskInfo.Id -Force
                    }
                }
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
