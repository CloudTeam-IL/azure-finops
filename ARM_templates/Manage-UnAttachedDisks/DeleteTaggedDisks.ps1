<#
	to delete disks you need Microsoft.Compute/disks/delete permissions
	and to create snapshots you need Disk Snapshot Contributor
    and reader persmissions
#>
Param
(
    [Parameter (Mandatory = $false)]
    [ValidateSet(“ManagedIdentity”,”ServicePrincipal”)]
    [String] $AccountType = "ManagedIdentity",
    [Parameter (Mandatory=$true)]
    [String] $SubForLog,
    [Parameter (Mandatory=$true)]
    [String] $StorageAccName,
    [Parameter (Mandatory=$true)]
    [String] $ResourceGroupName,
    [Parameter (Mandatory = $false)]
    [String] $ContainerName = "deleteunattacheddiskslogs",
    [Parameter (Mandatory = $false)]
    [String] $logsName = "Delete-Disks-Log",
    [Parameter (Mandatory = $false)]
    [String] $Format = "dd-MM-yyyy"
)
#this function check if item is in list
function FindItemInList {
	param (
		$listOfItems,
		$desiredItem
	)
	foreach($Item in $listOfItems)
	{
		if ($Item.Name -eq $desiredItem) {
			return 1
		}
	}
	return 0
}

#all the major vars\
$logsName = $logsName + ".csv"
$LogSubjects ="Resource Id,Snapshot Id,Region,Resource Group,Subscription,Size,Type`n"
$LogValues = ""
$CurrentDate = Get-Date -Format $Format
#connecting to azure account
if($env:AUTOMATION_ASSET_ACCOUNTID)
{
	Write-Output "----Connecting----"
    if($AccountType -eq "ServicePrincipal")
    {
		Write-Output "----Service connection----"
        $runAsConnection = Get-AutomationConnection -Name 'AzureRunAsConnection' -ErrorAction Stop
        Add-AzAccount -ServicePrincipal -Tenant $runAsConnection.TenantId -ApplicationId $runAsConnection.ApplicationId `
            -CertificateThumbprint $runAsConnection.CertificateThumbprint -ErrorAction Stop | Out-Null
    }
    else
    {
        $ID = Get-AutomationVariable -Name #<Identity Name>
		Write-Output "----Identity connection-----"
        Disable-AzContextAutosave -Scope Process | Out-Null
        if($ID)
        {
            Write-Output "----User assigned----"
            Connect-AzAccount -Identity -AccountId $ID
        }
        else
        {
            Write-Output "----System assigned----"
            Connect-AzAccount -Identity
        }
    }
}
#connecting to the logging subscription
$allSubs = Get-AzSubscription
Set-AzContext -SubscriptionName $SubForLog
#getting the storage account
$StorageAcc = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccName
#getting all the data from the storage account
$ctx = $StorageAcc.Context
#getting all the containers from the data
$allContainers = Get-AzStorageContainer -Context $ctx
#checking if the is no containers or the desire container is not exists
if (!$allContainers -or !(FindItemInList -listOfItems $allContainers -desiredItem $ContainerName)) {
	#creating a log file to push to the container
	New-Item -Path . -Name $logsName -ItemType "file"
	#creating logging container
	New-AzStorageContainer -Name $ContainerName -Context $ctx #-Permission blob
	#creating the blob
	$BlobFile = @{
		File = ".\$($logsName)"
		Container =$ContainerName
		Blob = $logsName
		Context =$ctx
		BlobType = "Append"
	}
	#pushing the blob to the container
	$Blob = Set-AzStorageBlobContent @BlobFile
	#pushing to the log all the subjects
	$Blob.ICloudBlob.AppendText($LogSubjects)
}
#if the container is exists
else
{
	#getting all the blobs from the container
	$AllBlobs = Get-AzStorageBlob -Context $ctx -Container $ContainerName
	#checking if the log blob exists
	if (!(FindItemInList -listOfItem $AllBlobs -desiredItem $logsName)) {
		#creating a log file to push to the container
		New-Item -Path . -Name $logsName -ItemType "file"
		#creating the blob
		$BlobFile = @{
			File = ".\$($logsName)"
			Container =$ContainerName
			Blob = $logsName
			Context =$ctx
			BlobType = "Append"
		}
		#pushing the blob to the container
		$Blob = Set-AzStorageBlobContent @BlobFile
		#pushing to the log all the subjects
		$Blob.ICloudBlob.AppendText($LogSubjects)
	}
	#if the blob exists
	else
	{
		#save the blob
		$Blob = Get-AzStorageBlob -Container $ContainerName -Context $ctx -Blob $logsName
	}
}

#iterating through all the subscriptions
foreach ($sub in $allSubs)
{
	#connecting to the subscription
	Set-AzContext -SubscriptionName $sub.Name | Out-Null
	Write-Output "---- $($sub.Name) ----"
	#getting all the disks from the subscription
	$allDisks = Get-AzDisk
	#iterating through all the disks
	foreach ($disk in $allDisks)
	{
		#if the disk have the deletion tag
		if ($disk.Tags.DeleteThisDisk -eq "UpForDelete") {
			$rg = $disk.ResourceGroupName
			$loc = $disk.Location
			$snapshotName = "$($disk.Name)_snapShot"
			#creating the snapshot configuration
            #-AccountType Standard_LRS
			$snapshot = New-AzSnapshotConfig -SourceUri $disk.Id -Location $loc -CreateOption copy
			#creating the new snapshot
			$newSnapshot = New-AzSnapshot -Snapshot $snapshot -SnapshotName $snapshotName -ResourceGroupName $rg
			#adding tag to delete after 90 days
			Update-AzTag -ResourceId $newSnapshot.Id -Tag @{"MarkedForDelete"=$CurrentDate} -Operation Merge
			#deleting the disk
			Remove-AzDisk -ResourceGroupName $rg -DiskName $disk.Name -Force
            $Deleted = Get-AzDisk -ResourceGroupName $disk.ResourceGroupName -DiskName $disk.Name -ErrorAction silentlycontinue
            if(!$Deleted)
            {
            #creating the log string
			    $LogValues = "$($disk.Id),$($newSnapshot.Id),$($loc),$($rg),$($sub.Name),$($disk.DiskSizeGB),$($disk.Sku.Name)`n"
			#appending the log into the log file
			    $Blob.ICloudBlob.AppendText($LogValues)
            }
            else
            {
                Write-Output "---- cannot delete $($disk.Name) ----"
            }
		}
	}
}
