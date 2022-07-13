param (
    [Parameter ()]
    [String] $ConnectionType = "managedidentity",
    [Parameter ()]
    [string] $ConnectionVarName = "",
    [Parameter()]
    [string] $TenantId
)
function ConnectToAzure {
    param (
        [Parameter()]
        [string] $TenantId,
        [Parameter()]
        [string] $ConnectionVarName
    )
    if ($env:AUTOMATION_ASSET_ACCOUNTID) {
        $ConnectionType = $ConnectionType.ToLower()
        if ($ConnectionType -eq "managedidentity") {
            Write-Output "----Identity connection-----"
            Disable-AzContextAutosave -Scope Process | Out-Null
            if ($ConnectionVarName) {
                Write-Output "----User assigned----"
                Connect-AzAccount -Identity -AccountId $(Get-AutomationVariable -Name $ConnectionVarName)
            }
            else {
                Write-Output "----System assigned----"
                Connect-AzAccount -Identity
            }
        }
        elseif ($ConnectionType -eq "serviceprincipal") {
            Write-Output "----Service connection----"
            $runAsConnection = Get-AutomationConnection -Name 'AzureRunAsConnection' -ErrorAction Stop
            Add-AzAccount -ServicePrincipal -Tenant $runAsConnection.TenantId -ApplicationId $runAsConnection.ApplicationId `
                -CertificateThumbprint $runAsConnection.CertificateThumbprint -ErrorAction Stop | Out-Null 
        }
    }
    else { Connect-AzAccount -TenantId $TenantId }
}
if (-not $(ConnectToAzure -TenantId $TenantId)) {
    Write-Error "Failed to Connect to Azure."
    exit 1
}
else { Write-Output "Successfully Connected to Azure." }
$subs = Get-AzSubscription -WarningAction SilentlyContinue | Where-Object { $_.State.ToLower() -eq "enabled" }
$count = 0
foreach ($sub in $subs) {
    Set-AzContext $sub.Id
    $allVms = Get-AzVM -Status | Where-Object { $_.PowerState.ToLower() -eq "vm stopped" }
    Write-Host "$($allVms.Count) Stopped Vms" -ForegroundColor Cyan
    $allVms | ForEach-Object -Parallel {
        Write-Host "Deallocating $($_.Name)" -ForegroundColor Cyan
        Stop-AzVM -ResourceGroupName $_.ResourceGroupName -Name $_.Name -Force
    } -ThrottleLimit 5
    # foreach ($vm in $allVms) {
    #     Write-Host "Deallocating $($vm.Name)" -ForegroundColor Cyan
    #     Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force
    # }
    $count++
    Write-Host "$($count)/$($Subs.Count) Subscriptions Finished" -ForegroundColor Green
}