<#
    .DESCRIPTION
    This script will look for deallocated VMS and if the VMS are deallocated more than a given time
    then the script will tag the VM and all the disks that are attached to it.

    .PARAMETER AccountType
    The type of connection you make: Managed Identity or Service Principal

    .PARAMETER AccountName
    Incase of User Assigned Managed Identity, then you need to save the client id to an automation variable and provide the variable name

    .PARAMETER SubscriptionNamePattern
    Adding a pattern to the subscription fetch, so it will take only a certain subscriptions

    .PARAMETER exceptionTags
    If you have certain tags that you want to check with a different daysToDelete, like dev=0,prod=50. keep empty if there are no tags

    .PARAMETER daysToDelete
    The number of days that have passed since the disk became deallocated
#>


PARAM(
    [parameter (Mandatory = $false)]
    [string] $AccountType = "ManagedIdentity",
    [parameter (Mandatory = $false)]
    [string] $AccountName = "",
    [parameter (Mandatory = $false)]
    [string] $SubscriptionNamePattern = '.*',
    [parameter (Mandatory = $false)]
    [string] $exceptionTags = "",
    [parameter (Mandatory = $false)]
    [int] $daysToDelete = 89
)

<#
    This function gets a vm and alist of all the disks in him
    returns a list of the resources id
#>
function getDisksFromVm($vm, $disks) {

    [bool]$flag = 0
    $ids = New-Object System.Collections.ArrayList
    $null = $ids.Add($vm.Id)
    foreach ($d in $disks) {
        $disk = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -Name $d
        $null = $ids.Add($disk.Id)
        if ($disk.DiskSizeGB -gt 29) {
            $flag = 1
        }
    }
    if ($flag) {
        return $ids
    }
    return New-Object System.Collections.ArrayList
}

function ConvertCommaToNewLine
{
    param
    (
        $data
    )
    $Converted = $data -replace ",","`r`n"
    return $Converted
}

Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Starting' -f (Get-Date))

try {
    #converting the exception string to object
    $TagsExceptions = ConvertCommaToNewLine -data $exceptionTags
    $Exceptions = ConvertFrom-StringData -StringData $TagsExceptions
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
    # Iterate all subscriptions
    Get-AzSubscription | Where-Object { ($_.Name -match $SubscriptionNamePattern) -and ($_.State -eq 'Enabled') } | ForEach-Object {

        Write-Output ('Switching to subscription: {0}' -f $_.Name)
        $null = Set-AzContext -SubscriptionObject $_ -Force
        $logsStartDate = Get-Date
        $logsStartDate = $logsStartDate.AddDays(-$daysToDelete)
        $getCurrentDate = Get-Date

        # Get Stopped/Deallocated Vms More Than x Days & DiskSize Over 50GB & Tag Them
        $ids = New-Object System.Collections.ArrayList
        $mergedTags = @{"Candidate" = "DeleteMe" }
        $vms = (Get-AzVM -Status)
        foreach ($vm in $vms ) {
            $alreadyChecked = $false
            $vmDetails = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
            # $tmpIds = New-Object System.Collections.ArrayList
            $tmpIds = New-Object System.Collections.ArrayList
            if ($vm.PowerState -eq "VM deallocated") {
                Write-Output ($vm.id)
                #iterrating over all the vms tags
                foreach($tag in $vm.Tags.Keys)
                {
                    #iterrating over all the tags with the exceptions
                    foreach($exception in $Exceptions.Keys)
                    {
                        #if a vm has a tag with the exception as value
                        if ($vm.Tags.$tag -eq $exception) {
                            #remeber that the vm was already checked
                            $alreadyChecked = $true
                            #getting the exception date to check
                            $days = $Exceptions.$exception -as [Int]
                            $exceptionDate = $(Get-Date).AddDays(-$days)
                            $exceptionDate = $exceptionDate.ToString("yyyy-MM-ddTHH:mm:ss")
                            #getting the logs
                            $logEntry = (Get-AzLog  -ResourceId $vm.Id -Status Accepted -DetailedOutput -StartTime $exceptionDate | Where-Object { $_.Authorization.Action -eq "Microsoft.Compute/virtualMachines/deallocate/action" })
                            #if there are no logs
                            if ($logEntry.Length -eq 0) {
                                #saving vm and disks to tag
                                $tmpIds = getDisksFromVm -vm $vm -disks $vmDetails.Disks.Name
                                Write-Output $tmpIds.Length
                            }
                            $ids = $ids + $tmpIds
                            break
                        }
                    }
                    if ($alreadyChecked) {
                        break
                    }
                }
                if (-not $alreadyChecked) {
                $logEntry = (Get-AzLog  -ResourceId $vm.Id -Status Accepted -DetailedOutput -StartTime $logsStartDate | Where-Object { $_.Authorization.Action -eq "Microsoft.Compute/virtualMachines/deallocate/action" })
                # if there are no log entries we can assume VM has been down and no changes made
                # for more than x days so it's OK to remove
                if ((!$logEntry) -or ($logEntry.EventTimestamp -eq $null)) {
                    $tmpIds = getDisksFromVm -vm $vm -disks $vmDetails.Disks.Name
                }
                else {
                    #if there are logs then it checking if there are logs from x days ago
                    $ts = if ($logEntry -is [System.array]) 
                    { New-TimeSpan  -Start ($logEntry[0].EventTimestamp) -End $getCurrentDate } 
                    else { New-TimeSpan  -Start ($logEntry.EventTimestamp) -End $getCurrentDate }
                    #if there are no logs then sending the vm to deletion
                    if ($ts.Days -gt $daysToDelete) {
                        $tmpIds = getDisksFromVm -vm $vm -disks $vmDetails.Disks.Name
                    }
                }
                $ids = $ids + $tmpIds
                }
        }
            Write-Output('will tag {0} resources' -f $ids.Count)
            foreach ($id in $ids) {
                Write-Output('tagging {0}' -f $id)
                $null = Update-AzTag -ResourceId $id -Tag $mergedTags -Operation Merge
                # Update-AzTag -ResourceId $id -Tag $mergedTags -Operation Merge
            }
            $ids = @()
        }
    }
}
catch {
    Write-Output ($_)
}
finally {
    Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Completed' -f (Get-Date))
}
