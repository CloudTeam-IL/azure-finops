param(
    [parameter (Mandatory = $true)]
    [string] $fileLocation
)
$WarningPreference = 'SilentlyContinue'
function createArrayForQuery {
    param(
        $resourceIds
    )
    $array = "('"
    foreach ($id in $resourceIds) {
        $array += "$($id)','"
    }
    $length = $array.Length
    $array = $array.Substring(0, $length - 2) + ")"
    return $array
}

Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
if (-not (Get-InstalledModule -Name az.resourcegraph)) { Install-Module az.resourcegraph }


$disks = Get-Content $fileLocation
$disksArray = createArrayForQuery -resourceIds $disks
$subs = Get-AzSubscription
$query = @"
resources
| where type =~ "Microsoft.Compute/disks"
| where properties["diskState"] =~ "unattached"
| where id in~ $($disksArray)
| order by subscriptionId
"@
$currentSub = ''
do {
    if ($result) {
        $result = Search-AzGraph -Query $query -Subscription $subs -SkipToken $result.SkipToken
    }
    else {
        $result = Search-AzGraph -Query $query -Subscription $subs
    }
    foreach ($disk in $result) {
        if (-not $currentSub -or $disk.subscriptionId -ne $currentSub) {
            $currentSub = $disk.subscriptionId
            Set-AzContext -SubscriptionId $disk.subscriptionId
        }
        $snapshotconfig = New-AzSnapshotConfig -Location $disk.location -SourceUri $disk.id -CreateOption copy
        $snapshot = New-AzSnapshot -ResourceGroupName $disk.resourceGroup -SnapshotName "$($disk.name)-snapshot" -Snapshot $snapshotconfig -ErrorAction SilentlyContinue
        if (-not $snapshot) {
            Write-Host "Could not snapshot disk: $($disk.id)" -ForegroundColor Red
        }
        else {
            Write-Host "Snapshot created for $($disk.id)" -ForegroundColor Green
            $DeletedDisk = Remove-AzDisk -ResourceGroupName $disk.resourceGroup -DiskName $disk.name -Force -ErrorAction SilentlyContinue
            if (-not $DeletedDisk) {
                Write-Host "Could not delete disk: $($disk.id)" -ForegroundColor Red
            }
            else {
                Write-Host "$($disk.id) Deleted" -ForegroundColor Green
            }
        }
    }
}while ($result.SkipToken)
