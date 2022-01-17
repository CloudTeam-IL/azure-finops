PARAM(
    [parameter (Mandatory = $false)]
    [string] $AccountType = "ManagedIdentity",
    [parameter (Mandatory = $false)]
    [string] $AccountName = "",
    [parameter (Mandatory = $false)]
    [string] $SubscriptionNamePattern = '.*',
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
        if ($disk.DiskSizeGB -gt 50) {
            $flag = 1
        }
    }
    if ($flag) {
        return $ids
    }
    return New-Object System.Collections.ArrayList
}


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

            $vmDetails = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
            # $tmpIds = New-Object System.Collections.ArrayList
            $tmpIds = New-Object System.Collections.ArrayList
            if ($vm.PowerState -eq "VM deallocated") {
                Write-Output ($vm.id)
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
    }


}
catch {
    Write-Output ($_)
}
finally {
    Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Completed' -f (Get-Date))
}