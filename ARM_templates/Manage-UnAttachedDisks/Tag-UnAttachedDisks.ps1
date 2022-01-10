<#
    To run this script you need Tag Contributor permissions and reader permissions.
    this permission allow you to add tags to resources even if you dont have persmissions to the resources 
#>

Param
(
    [Parameter (Mandatory = $false)]
    [ValidateSet(“ManagedIdentity”,”ServicePrincipal”)]
    [String] $AccountType = "ManagedIdentity",
    [Parameter (Mandatory=$false)]
    [Int] $TimeAlive = 7,
    [Parameter (Mandatory=$true)]
    [String] $SubForLog,
    [Parameter (Mandatory=$true)]
    [String] $StorageAccName,
    [Parameter (Mandatory=$true)]
    [String] $ResourceGroup,
    [Parameter (Mandatory = $false)]
    [String] $logsName = "Tag-Disks-Log",
    [Parameter (Mandatory = $false)]
    [String] $ContainerName = "deleteunattacheddiskslogs",
    [Parameter (Mandatory = $false)]
    [String] $Format = "dd/MM/yyyy"
)

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

#getting the last time a resources should have benn attached
$logsName = $logsName + ".csv"
$CurrentDate = Get-Date
$DateToLog = Get-Date -Format $Format
$LogSubjects ="Resource Id,Region,Resource Group,Subscription,Date`n"
$LogValues = ""
$CurrentDate = $CurrentDate.AddDays(-$TimeAlive)
$CurrentDate = $CurrentDate.ToString("yyyy-MM-ddTHH:mm:ss")
#connecting to the Azure account
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
#getting all the subscriptions of the tenent
Set-AzContext -SubscriptionName $SubForLog
#getting the storage account
$StorageAcc = Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccName
#getting all the data from the storage account
$ctx = $StorageAcc.Context
#getting all the containers from the data
$allContainers = Get-AzStorageContainer -Context $ctx
Write-Output "---- Creating storage containers and log files ----"
if (!$allContainers -or !(FindItemInList -listOfItems $allContainers -desiredItem $ContainerName)) {
	#creating a log file to push to the container
	New-Item -Path . -Name $logsName -ItemType "file" -Force
	#creating logging container
	New-AzStorageContainer -Name $ContainerName -Context $ctx #-Permission blob
    Start-Sleep -Seconds 10
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
    Write-Output $Blob
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
$allSub = Get-AzSubscription
#moving between all the subscriptions
foreach($sub in $allSub)
{
	Write-Output "--- $($sub.Name) ---"
    Set-AzContext -SubscriptionName $sub.Name
    #getting all the disks in a subscription
    $AllDisks = Get-AzDisk
    foreach($md in $AllDisks)
    {
        if (!$md.ManagedBy)
        {
            #checking if there is activity in the disk since the desire time
            $ListOfLogs = Get-AzLog -ResourceId $md.Id -StartTime $CurrentDate
            if ($ListOfLogs.Length -eq 0)
            {
                #if there is no activity then add the tag
                Update-AzTag -ResourceId $md.Id -Tag @{"DeleteThisDisk"="UpForDelete"} -Operation Merge #-ErrorAction Stop
                $LogValues = "$($md.Id),$($md.Location),$($md.ResourceGroupName),$($sub.Name),$($DateToLog)`n"
                $Blob.ICloudBlob.AppendText($LogValues)

            }
        }
    }
}
