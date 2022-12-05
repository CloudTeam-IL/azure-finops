param(
    [parameter (Mandatory = $false)]
    [string]$key = $null,
    [parameter (Mandatory = $false)]
    [string]$value = $null
)

Connect-AzAccount
$query = @"
resources
| where type =~ "microsoft.storage/storageaccounts" and (tolower(kind) == "storage" or tolower(kind) == "blobstorage")@@
| sort by subscriptionId
"@
if (-not $key) {
    $query.Replace("@@", "")
}
else {
    $tags = "tags['$($key)']"
    $query = $query.Replace("@@", " and (isnull($($tags)) or $($tags) != '$($value)')")
    write-host $query
}
$subs = Get-AzSubscription
do {
    $resources = Search-AzGraph -Query $query -Subscription $subs -SkipToken $resources.skiptoken
    $subsToRun = $resources.subscriptionId | Get-Unique
    foreach ($sub in $subsToRun) {
        Set-AzContext $sub
        $currentR = $resources | Where-Object { $_.subscriptionId -eq $sub }
        $currentR | foreach -Parallel {
            Set-AzStorageAccount -ResourceGroupName $_.resourceGroup -Name $_.name -UpgradeToStorageV2
        } -ThrottleLimit 10
    }
}while ($resources.skiptoken)