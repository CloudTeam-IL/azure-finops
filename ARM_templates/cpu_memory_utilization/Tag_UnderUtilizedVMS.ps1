param(
    [Parameter (Mandatory = $false)]
    [ValidateSet("ManagedIdentity", "ServicePrincipal")]
    [String] $AccountType = "ManagedIdentity",
    [Parameter (Mandatory = $false)]
    [string] $AccountName = "",
    [Parameter (Mandatory = $true)]
    [String] $StorageAccountId,
    [Parameter (Mandatory = $true)]
    [String] $container,
    [Parameter (Mandatory = $false)]
    [int] $LookBack = 14,
    [Parameter (Mandatory = $false)]
    [int] $MinHoursOn = 10,
    [Parameter (Mandatory = $false)]
    [int] $minPercentToReport = 60
)

#Globals
$LogName = "UnderUtilizedMachine-$(get-date -f "yyyyMMddHHmmss").csv"

#Input: VM data and a timespan
#Output: the max cpu usage
function getprecentageCpuMax {
    param (
        $VM,
        $ts
    )
    $CpuMetric = Get-AzMetric -ResourceId $VM.Id -AggregationType Maximum -StartTime (Get-Date).AddDays(-$LookBack) -MetricName "Percentage CPU" -TimeGrain $ts
    $CpuavgMetric = Get-AzMetric -ResourceId $VM.Id -AggregationType Average -StartTime (Get-Date).AddDays(-$LookBack) -MetricName "Percentage CPU" -TimeGrain $ts
    $CpuMetric = $CpuMetric.Data | Where-Object { $_.Maximum -and $_.Maximum -ne 0 }
    $CpuavgMetric = $CpuavgMetric.Data | Where-Object { $_.Average -and $_.Average -ne 0 }
    $max = 0
    if ($CpuMetric.Count -le $MinHoursOn) {
        return 0
    }
    foreach ($m in $CpuMetric) {
        if ($m.Maximum -gt $max) {
            $max = $m.Maximum
        }
    }
    $avg = 0
    foreach ($m in $CpuavgMetric) {
        if ($m.Average -gt $avg) {
            $avg = $m.Average
        }
    }
    return @($max, $avg)
}

#input: VM Data and a timespan
#Output: the max ram usage
function getPrecentageRamMax {
    param (
        $VM,
        $ts
    )
    $RamMetric = Get-AzMetric -ResourceId $vm.Id -AggregationType Minimum -StartTime (Get-Date).AddDays(-$LookBack) -MetricName "Available Memory Bytes" -TimeGrain $ts
    $RamavgMetric = Get-AzMetric -ResourceId $vm.Id -AggregationType Average -StartTime (Get-Date).AddDays(-$LookBack) -MetricName "Available Memory Bytes" -TimeGrain $ts
    $RamMetric = $RamMetric.Data | Where-Object { $_.Minimum -and $_.Minimum -ne 0 }
    $RamavgMetric = $RamavgMetric.Data | Where-Object { $_.Average -and $_.Average -ne 0 }
    if ($RamMetric.Count -le $MinHoursOn) {
        return 0
    }
    $min = [decimal]::MaxValue
    foreach ($m in $RamMetric) {
        if ($m.Minimum -lt $min) {
            $min = $m.Minimum
        }
    }
    $avg = [decimal]::MaxValue
    foreach ($m in $RamavgMetric) {
        if ($m.Average -lt $avg) {
            $avg = $m.Average
        }
    }
    #converting bytes to megabytes
    $min = $min / 1048576
    $avg = $avg / 1048576
    $vmsize = $VM.properties.HardwareProfile.VmSize
    $vmsz = Get-AzVMSize -Location $VM.Location | Where-Object { $_.Name -eq $vmsize }
    $MaxUsedRamInPercentage = (($vmsz.MemoryInMB - $min) / $vmsz.MemoryInMB) * 100
    $MaxavgUsedRamInPercentage = (($vmsz.MemoryInMB - $avg) / $vmsz.MemoryInMB) * 100
    return @($MaxUsedRamInPercentage, $MaxavgUsedRamInPercentage)
}

#input: VM Data, Timespan, Blob for report
#output: true if the vm is underutilized, false otherwise
function isUnderUtilized {
    param(
        $VM,
        $ts,
        $blob
    )
    $cpu = getprecentageCpuMax -VM $VM -ts $ts
    $ram = getPrecentageRamMax -VM $VM -ts $ts
    if ($cpu -eq 0 -and $ram -eq 0) {
        return $false
    }
    elseif ($cpu -lt $minPercentToReport -and $ram -lt $minPercentToReport) {
        ReportUnderUtilized -VM $VM -cpu $cpu -ram $ram -blob $blob
        if ($cpu[0] -lt 50 -and $ram[0] -lt 50 -and $cpu[1] -lt 40 -and $ram[1] -lt 40) {
            return $true
        }
    }
    return $false
}

#connect to storage account and create a blob
function GetStorageBlobContext {
    $allsadata = $StorageAccountId.Split("/")
    Set-AzContext -SubscriptionId $allsadata[2]
    $ctx = (Get-AzStorageAccount -Name $allsadata[-1] -ResourceGroupName $allsadata[4]).Context
    $BlobFile = @{
        File      = "./$($LogName)"
        Container = $container
        Blob      = $LogName
        Context   = $ctx
        BlobType  = "Append"
    }
    #pushing the blob to the container
    $Blob = Set-AzStorageBlobContent @BlobFile
    $blob.ICloudBlob.AppendText("VM name,VM subscription,VM rg,cpu max,avg cpu,ram max,avg ram`n")
    return $Blob
}

#Write to blob
function ReportUnderUtilized {
    param (
        $VM,
        $cpu,
        $ram,
        $blob
    )
    $subname = (Get-AzSubscription -SubscriptionId $VM.SubscriptionId).Name
    $blob.ICloudBlob.AppendText("$($VM.name),$($subname),$($VM.resourceGroup),$($cpu[0])%,$($cpu[1])%,$($ram[0])%,$($ram[1])%`n")
}

#tagging for resize
function TagForResize {
    param(
        $VMId
    )
    Update-AzTag -ResourceId $VMId -Tag @{"Candidate" = "RightSize" } -Operation Merge
}

#connecting as managed identity
function ConnectAsIdentity {
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

#connecting as service principal
function ConnectAsService {
    Write-Output "----Service connection----"
    $runAsConnection = Get-AutomationConnection -Name 'AzureRunAsConnection' -ErrorAction Stop
    Add-AzAccount -ServicePrincipal -Tenant $runAsConnection.TenantId -ApplicationId $runAsConnection.ApplicationId `
        -CertificateThumbprint $runAsConnection.CertificateThumbprint -ErrorAction Stop | Out-Null
}

$WarningPreference = 'SilentlyContinue'

New-Item -Path ".\$($LogName)"
if ($env:AUTOMATION_ASSET_ACCOUNTID) {
    if ($AccountType -eq "ManagedIdentity") {
        ConnectAsIdentity
    }
    else {
        ConnectAsService
    }
}
else {
    Connect-AzAccount -UseDeviceAuthentication
}

$Blb = GetStorageBlobContext
$query = @"
resources
| where type =~ "microsoft.compute/virtualmachines"
| where tags["Candidate"] !~ "RightSize" and  tags["Candidate"] !~ "Manual RightSizing"
"@

$Subs = Get-AzSubscription
$ts = New-TimeSpan -Hours 1
$VMS = Search-AzGraph -Query $query -Subscription $Subs.Id
if ($VMS.SkipToken) {
    for (; $VMS.SkipToken; $VMS = Search-AzGraph -Query $query -Subscription $Subs.Id -SkipToken $VMS.SkipToken) {
        foreach ($vm in $VMS) {
            Write-Output "Checking $($vm.Name)"
            if (isUnderUtilized -VM $vm -ts $ts -blob $Blb) { Write-Output " Tagging $($vm.Name)"; TagForResize -VMId $vm.Id }
        }
    }
}
foreach ($vm in $VMS) {
    Write-Output "Checking $($vm.Name)"
    if (isUnderUtilized -VM $vm -ts $ts -blob $Blb) { Write-Output " Tagging $($vm.Name)"; TagForResize -VMId $vm.Id }
}