<#
	to delete disks you need Microsoft.Compute/disks/delete permissions
	and to create snapshots you need Disk Snapshot Contributor
    and reader persmissions
#>
Param
(
	[Parameter (Mandatory = $false)]
	[ValidateSet(“ManagedIdentity”, ”ServicePrincipal”)]
	[String] $AccountType = "ManagedIdentity",
	[Parameter(Mandatory = $false)]
	[String] $AccountName = "",
	[Parameter (Mandatory = $true)]
	[String] $SubForLog,
	[Parameter (Mandatory = $true)]
	[String] $StorageAccName,
	[Parameter (Mandatory = $true)]
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
	foreach ($Item in $listOfItems) {
		if ($Item.Name -eq $desiredItem) {
			return 1
		}
	}
	return 0
}

<#
 this function connect as service principal
 dosnt have parameters
 dosnt return anything
#>
function ServiceConnect {
	Write-Output "----Service connection----"
	$runAsConnection = Get-AutomationConnection -Name 'AzureRunAsConnection' -ErrorAction Stop
	Add-AzAccount -ServicePrincipal -Tenant $runAsConnection.TenantId -ApplicationId $runAsConnection.ApplicationId `
		-CertificateThumbprint $runAsConnection.CertificateThumbprint -ErrorAction Stop | Out-Null
}

<#
 this function connect as Identity
 dosnt have parameters
 dosnt return anything
#>
function IdentityConnect {
	if ($AccountName) {
		$ID = Get-AutomationVariable -Name $AccountName
	}
	else {
		$ID = ""
	}
	Write-Output "----Identity connection-----"
	Disable-AzContextAutosave -Scope Process | Out-Null
	if ($ID) {
		Write-Output "----User assigned----"
		Connect-AzAccount -Identity -AccountId $ID
	}
	else {
		Write-Output "----System assigned----"
		Connect-AzAccount -Identity
	}
}

<#
 this function create the blob storage inside the container
 parameters: Logname - the log file name, ContainerName - the name of the storage container, ctx - the context of the storage account
 returning the blob storage
#>
function CreateBlobStorage {
	param (
		$logsName,
		$ContainerName,
		$ctx
	)
	#creating the blob
	$BlobFile = @{
		File      = ".\$($logsName)"
		Container = $ContainerName
		Blob      = $logsName
		Context   = $ctx
		BlobType  = "Append"
	}
	#pushing the blob to the container
	$Blob = Set-AzStorageBlobContent @BlobFile
	return $Blob
}

<#
 this function connecting to a blob storage for logging, if the blob or the container doesnt exists then it creates them
 parameters: allContainers - a list of all the storage containers, containerName - the name of the storage container, logsName - the log file name, ctx - the storage account context, logSubjects - the headers for the log file
 returns the blob storage for logging
#>
function ConnectToLogFile {
	param (
		$allContainers,
		$ContainerName,
		$logsName,
		$ctx,
		$LogSubjects
	)
	#checking if the is no containers or the desire container is not exists
	if (!$allContainers -or !(FindItemInList -listOfItems $allContainers -desiredItem $ContainerName)) {
		#creating a log file to push to the container
		New-Item -Path . -Name $logsName -ItemType "file"
		#creating logging container
		New-AzStorageContainer -Name $ContainerName -Context $ctx #-Permission blob
		$Blob = CreateBlobStorage -logsName $logsName -ContainerName $ContainerName -ctx $ctx
		$Blob = Get-AzStorageBlob -Container $ContainerName -Blob $logsName -Context $ctx
		#pushing to the log all the subjects
		$Blob.ICloudBlob.AppendText($LogSubjects)
	}
	#if the container is exists
	else {
		#getting all the blobs from the container
		$AllBlobs = Get-AzStorageBlob -Context $ctx -Container $ContainerName
		#checking if the log blob exists
		if (!(FindItemInList -listOfItem $AllBlobs -desiredItem $logsName)) {
			#creating a log file to push to the container
			New-Item -Path . -Name $logsName -ItemType "file"
			#creating the blob
			$Blob = CreateBlobStorage -logsName $logsName -ContainerName $ContainerName -ctx $ctx
			$Blob = Get-AzStorageBlob -Container $ContainerName -Blob $logsName -Context $ctx
			#pushing to the log all the subjects
			$Blob.ICloudBlob.AppendText($LogSubjects)
		}
		#if the blob exists
		else {
			#save the blob
			$Blob = Get-AzStorageBlob -Container $ContainerName -Context $ctx -Blob $logsName
		}
	}
	return $Blob
}

<#
 this function create a snapshot from disk
 parameters: disk - the disk we will snapshot, loc - the region, snapshotName - the name of the snapshot, rg - resource group, currentDate - the date for the tag
 returns the new snapshot
#>
function CreateSnapshot {
	param (
		$disk,
		$loc,
		$snapshotName,
		$rg,
		$CurrentDate
	)
	Write-Verbose "---Snapshot $($disk.name)---" -verbose
	$snapshot = New-AzSnapshotConfig -SourceUri $disk.Id -Location $loc -CreateOption copy
	#creating the new snapshot
	$newSnapshot = New-AzSnapshot -Snapshot $snapshot -SnapshotName $snapshotName -ResourceGroupName $rg -ErrorAction SilentlyContinue
	#adding tag to delete after 90 days
	if ($newSnapshot) {
		Write-Verbose "Snapshot created for $($disk.Id)" -verbose
		Update-AzTag -ResourceId $newSnapshot.Id -Tag @{"Candidate" = $CurrentDate } -Operation Merge
	}
	else {
		Write-Error "Cant snapshot"
	}
	return $newSnapshot
}

<#
 this function Delete the disk and log the action
 parameters: rg - resource group, disk - the disk we delete, $newSnapshot - the snapshot for logging, loc - region, sub - the subscription
 doesnt return anything
#>
function DeleteAndLog {
	param (
		$rg,
		$disk,
		$newSnapshot,
		$loc,
		$sub
	)
	Write-Verbose "---Deleting $($disk.name)---" -verbose
	Remove-AzDisk -ResourceGroupName $rg -DiskName $disk.Name -Force -ErrorAction silentlycontinue
	$Deleted = Get-AzDisk -ResourceGroupName $disk.ResourceGroupName -DiskName $disk.Name -ErrorAction silentlycontinue
	if (!$Deleted) {
		Write-Verbose "$($disk.Id) Deleted" -verbose
		#creating the log string
		$LogValues = "$($disk.Id),$($newSnapshot.Id),$($loc),$($rg),$($sub.Name),$($disk.DiskSizeGB),$($disk.Sku.Name),Success`n"
		#appending the log into the log file
		$Blob.ICloudBlob.AppendText($LogValues)
	}
	else {
		$LogValues = "$($disk.Id),$($newSnapshot.Id),$($loc),$($rg),$($sub.Name),$($disk.DiskSizeGB),$($disk.Sku.Name),Failed`n"
		# $Blob.ICloudBlob.AppendText($LogValues)
		Write-Error "Cant Delete"
	}
	
}

#all the major vars\
$logsName = $logsName + ".csv"
$LogSubjects = "Resource Id,Snapshot Id,Region,Resource Group,Subscription,Size,Type,Status`n"
$LogValues = ""
$CurrentDate = Get-Date -Format $Format
#connecting to azure account
if ($env:AUTOMATION_ASSET_ACCOUNTID) {
	Write-Output "----Connecting----"
	if ($AccountType -eq "ServicePrincipal") {
		ServiceConnect
	}
	else {
		IdentityConnect
	}
}
else {
	Connect-AzAccount
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
$Blob = ConnectToLogFile -allContainers $allContainers -ContainerName $ContainerName -logsName $logsName -ctx $ctx -LogSubjects $LogSubjects
#iterating through all the subscriptions
foreach ($sub in $allSubs) {
	#connecting to the subscription
	Set-AzContext -SubscriptionName $sub.Name | Out-Null
	Write-Output "---- $($sub.Name) ----"
	#getting all the disks from the subscription
	$allDisks = Get-azDisk | Where-Object { -not $_.ManagedBy }
	#iterating through all the disks
	foreach ($disk in $allDisks) {
		#if the disk have the deletion tag
		if ($disk.Tags.Candidate -eq "DeleteUnAttached") {
			$rg = $disk.ResourceGroupName
			$loc = $disk.Location
			$snapshotName = "$($disk.Name)_snapShot"
			#creating the snapshot configuration
			#-AccountType Standard_LRS
			$newSnapshot = CreateSnapshot -disk $disk -loc $loc -snapshotName $snapshotName -rg $rg -CurrentDate $CurrentDate
			#deleting the disk
			if ($newSnapshot) {
				DeleteAndLog -rg $rg -disk $disk -newSnapshot $newSnapshot -loc $loc -sub $sub
			}
		}
	}
}
