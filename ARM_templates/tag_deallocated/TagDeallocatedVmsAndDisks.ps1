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
    [string] $ConnectionName = 'AzureRunAsConnection',
    [int] $daysToDelete = 89
)

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
    if($flag){
        return $ids
    }
    return New-Object System.Collections.ArrayList
}


Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Starting' -f (Get-Date))

try {
    # Login to Azure
    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName
    $null = Add-AzAccount -ServicePrincipal -Tenant $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint
    # Iterate all subscriptions
    Get-AzSubscription | Where-Object { ($_.Name -match $SubscriptionNamePattern) -and ($_.State -eq 'Enabled') } | ForEach-Object {

        Write-Output ('Switching to subscription: {0}' -f $_.Name)
        $null = Set-AzContext -SubscriptionObject $_ -Force
        $logsStartDate = Get-Date
        $logsStartDate = $logsStartDate.AddDays(-90)
        $getCurrentDate = Get-Date

        # Get Stopped/Deallocated Vms More Than 90 Days & DiskSize Over 50GB & Tag Them
        $ids = New-Object System.Collections.ArrayList
        $mergedTags = @{"Candidate" = "DeleteMeCloudTeam"}
        $vms = (Get-AzVM -Status)
        foreach ($vm in $vms ) {

            $vmDetails = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
            # $tmpIds = New-Object System.Collections.ArrayList
            $tmpIds = New-Object System.Collections.ArrayList
            if ($vm.PowerState -eq "VM deallocated") {
                Write-Output ($vm.id)
                $logEntry = (Get-AzLog  -ResourceId $vm.Id -Status Accepted -DetailedOutput -StartTime $logsStartDate | Where-Object { $_.Authorization.Action -eq "Microsoft.Compute/virtualMachines/deallocate/action" })
                # if there are no log entries we can assume VM has been down and no changes made
                # for more than 90 days so it's OK to remove
                if ((!$logEntry) -or ($logEntry.EventTimestamp -eq $null)) {
                    $tmpIds = getDisksFromVm -vm $vm -disks $vmDetails.Disks.Name
                }
                else {
                    $ts = if ($logEntry -is [System.array]) { New-TimeSpan  -Start ($logEntry[0].EventTimestamp) -End $getCurrentDate } else { New-TimeSpan  -Start ($logEntry.EventTimestamp) -End $getCurrentDate }
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
