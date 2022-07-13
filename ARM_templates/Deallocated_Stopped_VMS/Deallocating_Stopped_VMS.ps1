Connect-AzAccount -TenantId "667d9faa-186f-4608-8a36-cf595f0350fb"
$subs = Get-AzSubscription -TenantId "667d9faa-186f-4608-8a36-cf595f0350fb"
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