<#
    To run this script you need Tag Contributor permissions and reader permissions.
    these permission allow you to add tags to resources even if you dont have persmissions to the resources 
#>

Param
(
    [Parameter (Mandatory = $false)]
    [ValidateSet(“ManagedIdentity”,”ServicePrincipal”)]
    [String] $AccountType = "ManagedIdentity",
    [Parameter(Mandatory = $false)]
    [String] $AccountName = "",
    [Parameter (Mandatory=$false)]
    [Int] $TimeAlive = 89,
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

<#
 this function create the blob storage inside the container
 parameters: Logname - the log file name, ContainerName - the name of the storage container, ctx - the context of the storage account
 returning the blob storage
#>
function createLogFile {
    param (
        $LogName,
        $ContainerName,
        $ctx
    )
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
    if (!$allContainers -or !(FindItemInList -listOfItems $allContainers -desiredItem $ContainerName)) {
        #creating a log file to push to the container
        New-Item -Path . -Name $logsName -ItemType "file" -Force
        #creating logging container
        New-AzStorageContainer -Name $ContainerName -Context $ctx #-Permission blob
        Start-Sleep -Seconds 10
        #creating the blob
        $Blob = createLogFile -LogName $logsName -ContainerName $ContainerName -ctx $ctx
        $Blob = Get-AzStorageBlob -Container $ContainerName -Blob $logsName -Context $ctx
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
            $Blob = createLogFile -LogName $logsName -ContainerName $ContainerName -ctx $ctx
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
 this function itterate over all the disks and tags the one that unattached for x days
 parameters: allSubs - list of all the subscriptions, blob - the blob storage for logging, dateToLog - the current date to enter the log
 doesnt return anythig
#>
function diskCheckOnAllSubs {
    param (
        $allSub,
        $Blob,
        $DateToLog
    )
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
                    TagDisk -md $md -sub $sub -DateToLog $DateToLog
                }
            }
        }
    }
    
}

<#
 this function tag the given disk and log the action
 parameters: md - managed disk, sub - disk's subscription, dateToLog - the date of the tag creation
 doent return anything
#>
function TagDisk {
    param (
        $md,
        $sub,
        $DateToLog
    )
    Update-AzTag -ResourceId $md.Id -Tag @{"Candidate"="DeleteUnAttached"} -Operation Merge #-ErrorAction Stop
    Start-Sleep 5
    $md = Get-AzDisk -ResourceGroupName $md.ResourceGroupName -DiskName $md.Name
    if ($md.Tags.Candidate -eq "DeleteUnAttached") {
        Write-Output "tag success"
        $LogValues = "$($md.Id),$($md.Location),$($md.ResourceGroupName),$($sub.Name),$($DateToLog),Success`n"
        $Blob.ICloudBlob.AppendText($LogValues)  
    }
    else {
        Write-Output "tag failed"
        $LogValues = "$($md.Id),$($md.Location),$($md.ResourceGroupName),$($sub.Name),$($DateToLog),Failed`n"
        $Blob.ICloudBlob.AppendText($LogValues)    
    }

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

#getting the last time a resources should have benn attached
$logsName = $logsName + ".csv"
$CurrentDate = Get-Date
$DateToLog = Get-Date -Format $Format
$LogSubjects ="Resource Id,Region,Resource Group,Subscription,Date,status`n"
$LogValues = ""
$CurrentDate = $CurrentDate.AddDays(-$TimeAlive)
$CurrentDate = $CurrentDate.ToString("yyyy-MM-ddTHH:mm:ss")
#connecting to the Azure account
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
}
else {
    Connect-AzAccount
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
$Blob = ConnectToLogFile -allContainers $allContainers -ContainerName $ContainerName -logsName $logsName -ctx $ctx -LogSubjects $LogSubjects
$allSub = Get-AzSubscription
#moving between all the subscriptions
diskCheckOnAllSubs  -allSub $allSub -Blob $Blob -DateToLog $DateToLog


