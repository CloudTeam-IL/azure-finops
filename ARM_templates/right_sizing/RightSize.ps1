param(
    [Parameter (Mandatory = $false)]
    [ValidateSet("ManagedIdentity", "ServicePrincipal")]
    [String] $AccountType = "ManagedIdentity",
    [Parameter (Mandatory = $false)]
    [string] $AccountName = ""
)


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



function RightSizeVM {
    param(
        $vm,
        $wantedsku
    )
    $vmobject = Get-AzVM -Name $vm.name -ResourceGroupName $vm.resourceGroup
    $vmobject.HardwareProfile.VmSize = $wantedsku
    Update-AzVM -VM $vmobject -ResourceGroupName $vmobject.ResourceGroupName
    Write-Host "$($vmobject.Name) sku changed to $($wantedsku)"
    Update-AzTag -ResourceId $vmobject.Id -Tag @{"candidate" = "RightSize" } -Operation Delete
}

function getTierDownMachine {
    param(
        $VM
    )
    $specs = Get-AzVMSize -VMName $VM.Name -ResourceGroupName $VM.resourceGroup | Where-Object { $_.Name -eq $VM.properties.hardwareProfile.VmSize }
    $vcpu = $specs.NumberOfCores / 2
    $ram = $specs.MemoryInMB / 2
    if ([char]$specs.Name[-1] -ge 49 -and [char]$specs.Name[-1] -le 57) { 
        if ($specs.Name.ToLower().Contains('v')) {
            $tempV = $specs.Name[-1]
        }
    }
    $regex = $specs.Name -replace "[0-9]+", '[0-9]+'
    if ($tempV) {
        $regex = $regex.Substring(0, $regex.Length - 6)
        $regex = $regex + $tempV
    }
    $tier = Get-AzVMSize -VMName $VM.Name -ResourceGroupName $VM.resourceGroup | Where-Object { $_.NumberOfCores -eq $vcpu -and $_.MemoryInMB -eq $ram -and $_.Name -match $regex }
    if ($tier) {
        return $tier.Name
    }
    else {
        return $null
    }
}

if ($env:AUTOMATION_ASSET_ACCOUNTID) {
    if ($AccountType -eq "ManagedIdentity") {
        ConnectAsIdentity
    }
    else {
        ConnectAsService
    }
}
else {
    Connect-AzAccount
}

$query = @"
resources
| where tolower(type) == "microsoft.compute/virtualmachines"
| mv-expand tags
| where ['tags'] =~ '{"candidate":"RightSize"}'
"@
$Subs = Get-AzSubscription
Write-Output "Getting all the vms skus"
$VMS = Search-AzGraph -Query $query -Subscription $Subs
$VMS = $VMS | Sort-Object -Property subscriptionId
$currentsub = ""
if ($VMS.SkipToken) {
    for (; $VMS.SkipToken; $VMS = Search-AzGraph -Query $query -Subscription $Subs -SkipToken $VMS.SkipToken) {
        $VMS = $VMS | Sort-Object -Property subscriptionId
        foreach ($vm in $VMS) {
            Write-Output "Checking $($vm.Name)" -ForegroundColor Green
            if (-not $currentsub -or $currentsub -ne $vm.subscriptionId) {
                Set-AzContext -SubscriptionId $vm.subscriptionId
                $currentsub = $vm.subscriptionId
            }
            $wantedsku = getTierDownMachine -VM $vm
            if (-not $wantedsku) {
                Update-AzTag -ResourceId $vm.id -Tag @{"Candidate" = "Manual RightSizing" } -Operation Merge
            }
            else {
                Write-Output $vm.id
                RightSizeVM -vm $vm -wantedsku $wantedsku
            }
        }
    }
}
$VMS = $VMS | Sort-Object -Property subscriptionId
foreach ($vm in $VMS) {
    Write-Output "Checking $($vm.Name)" -ForegroundColor Green
    if (-not $currentsub -or $currentsub -ne $vm.subscriptionId) {
        Set-AzContext -SubscriptionId $vm.subscriptionId
        $currentsub = $vm.subscriptionId
    }
    $wantedsku = getTierDownMachine -VM $vm
    if (-not $wantedsku) {
        Update-AzTag -ResourceId $vm.id -Tag @{"Candidate" = "Manual RightSizing" } -Operation Merge
    }
    else {
        Write-Output $vm.id
        RightSizeVM -vm $vm -wantedsku $wantedsku
    }
}