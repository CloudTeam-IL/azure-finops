<#
    this script requiring reader permissions and snapshot contributor permissions
#>
Param 
(
    [Parameter (Mandatory = $false)]
    [ValidateSet(“ManagedIdentity”,”ServicePrincipal”)]
    [String] $AccountType = "ManagedIdentity",
    [Parameter(Mandatory = $false)]
    [String] $AccountName = "",
    [Parameter (Mandatory=$false)]
    [Int] $timeToKill = 89,
    [Parameter (Mandatory=$true)]
    [String] $SubForLog,
    [Parameter (Mandatory=$true)]
    [String] $StorageAccName,
    [Parameter (Mandatory=$true)]
    [String] $ResourceGroupName,
    [Parameter (Mandatory = $false)]
    [String] $ContainerName = "deleteunattacheddiskslogs",
    [Parameter (Mandatory = $false)]
    [String] $logsName = "Delete-SnapShot-Logs",
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

<#
 this function connect as service principal
 dosnt have parameters
 dosnt return anything
#>
function ConnectAsService {
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
function ConnectAsIdentity {
    if($AccountName){
        $ID = Get-AutomationVariable -Name $AccountName
    }
    else
    {
        $ID = ""
    }
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
		File = ".\$($logsName)"
		Container =$ContainerName
		Blob = $logsName
		Context =$ctx
		BlobType = "Append"
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
	else
	{
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
		else
		{
			#save the blob
			$Blob = Get-AzStorageBlob -Container $ContainerName -Context $ctx -Blob $logsName
		}
	}
	return $Blob
}

<#
this function delete the snapshots and logging the actions
parameters: snap - the snapshot to delete, timeToKill - how many days passed since created until deleted
this function doesnt return anything
#>
function DeleteSnapshotAndLog {
    param (
        $snap,
        $timeToKill
    )
    Write-Output "----Deleting $($snap.Name)----"
    Remove-AzSnapshot -ResourceGroupName $snap.ResourceGroupName -SnapshotName $snap.Name -Force
    $Deleted = Get-AzSnapshot -ResourceGroupName $sub.Name -SnapshotName $snap.Name -ErrorAction silentlycontinue  
    if(!$Deleted)
    {
        $LogValues = "$($snap.Id),$($snap.Location),$($snap.ResourceGroupName),$($sub.Name),$($timeToKill) days,Success`n"
        $Blob.ICloudBlob.AppendText($LogValues)
    }
    else
    {
        $LogValues = "$($snap.Id),$($snap.Location),$($snap.ResourceGroupName),$($sub.Name),$($timeToKill) days,Failed`n"
        $Blob.ICloudBlob.AppendText($LogValues)
        Write-Output "---- Cannot delete $($snap.Name) ----"
    }
}

$logsName = $logsName + ".csv"
$LogSubjects ="Snapshot Id,Region,Resource Group,Subscription,Deleted After(days),Status`n"
$LogValues = ""
$DaysToRemove = Get-Date
$DaysToRemove = $DaysToRemove.AddDays(-$timeToKill).ToString($Format)
#connecting to azure account
if($env:AUTOMATION_ASSET_ACCOUNTID)
{
	Write-Output "----Connecting----"
    if($AccountType -eq "ServicePrincipal")
    {
		ConnectAsService
    }
    else
    {
        ConnectAsIdentity
    }
}else {
    Connect-AzAccount
}
$allSubs = Get-AzSubscription
Set-AzContext -SubscriptionName $SubForLog
#getting the storage account
$StorageAcc = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccName
#getting all the data from the storage account
$ctx = $StorageAcc.Context
#getting all the containers from the data
$allContainers = Get-AzStorageContainer -Context $ctx
$Blob = ConnectToLogFile -allContainers $allContainers -ContainerName $ContainerName -logsName $logsName -ctx $ctx -LogSubjects $LogSubjects
#iterating over all the snapshots in a subscription
foreach ($sub in $allSubs)
{
    Set-AzContext -SubscriptionName $sub.Name | Out-Null
    Write-Output "----$($sub.Name)----"
    $allSnapShots = Get-AzSnapshot
    ForEach($snap in $allSnapShots)
    {
        #checking if the tag on the snapshot is from 90 days
        if ($snap.Tags.Candidate -eq $DaysToRemove) {
            #if it is then it delete the snapshot
            DeleteSnapshotAndLog -snap $snap -timeToKill $timeToKill
        }
    }
}
