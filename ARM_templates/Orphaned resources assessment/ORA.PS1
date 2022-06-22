
#Requires -Modules Az.DataProtection
function FindOrphanedIPs {
    $OIP = Get-AzPublicIpAddress | Where-Object { !$_.IpConfiguration }
    return $OIP
}

function FindOrphanedLoadBalancers {
    $OLB = Get-AzLoadBalancer | Where-Object { $_.BackendAddressPools.Count -eq 0 }
    return $OLB
}

function FindOrphanedDisks {
    $Disks = Get-AzDisk | Where-Object { !$_.ManagedBy }
    return $Disks
}

function FindOrphanedASP {
    param(
        $RG
    )
    $OASP = @()
    foreach ($Group in $RG) {
        $OASP += Get-AzAppServicePlan -ResourceGroupName $Group | Where-Object { $_.NumberOfSites -eq 0 }
    }
    return $OASP
}

function FindOrphanedNics {
    $Nics = Get-AzNetworkInterface | Where-Object { !$_.VirtualMachine }
    return $Nics
}

function FindEmptyVnet {
    $Vnet = Get-AzVirtualNetwork | Where-Object { $_.Subnets.ipConfigurations.count -eq 0 }
    return $Vnet
}

function FindEmptyRouteTables {
    $RT = Get-AzRouteTable | Where-Object { !$_.Subnets }
    return $RT
}

function FindOrphanedVPNs {
    function FindOrphanedVPNs {
        param (
            $RG
        )
        $OVPN = @()
        foreach ($group in $RG) {
            $vng = Get-AzVirtualNetworkGateway -ResourceGroupName $group
            $connection = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $group
            if ($connection.count -eq 0) {
                $OVPN += $vng
            }
            else {
                foreach ($gateway in $vng) {
                    if (!$connection.VirtualNetworkGateway1.Id.Contains($gateway.Id)) {
                        $OVPN += $gateway
                    }
                }
            }
        }
        return $OVPN
    }
}

function FindOrphanedLNG {
    param (
        $RG
    )
    $OLNG = @()
    foreach ($group in $RG) {
        $lng = Get-AzLocalNetworkGateway -ResourceGroupName $group
        $connection = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $group
        if ($connection.count -eq 0) {
            $OLNG += $lng
        }
        else {
            <# Action when all if and elseif conditions are false #>
            foreach ($gateway in $lng) {
                if (!$connection.LocalNetworkGateway2.Id.Contains($gateway.Id)) {
                    $OLNG += $gateway
                }
            }
        }
    }
    return $OLNG
}

function FindEmptyPrivateDnsZones {
    $EDNS = Get-AzPrivateDnsZone | Where-Object { $_.NumberOfVirtualNetworkLinks -eq 0 }
    return $EDNS
}

function FindEmptyAvailabilitySets {
    $EAS = Get-AzAvailabilitySet | Where-Object { $_.VirtualMachinesReferences.Count -eq 0 }
    return $EAS
}

function FindEmptyContainerRegistry {
    $Cr = Get-AzContainerRegistry
    $ecr = @()
    foreach ($registry in $Cr) {
        $usage = $(Get-AzContainerRegistryUsage -ResourceGroupName $registry.ResourceGroupName -Name $registry.Name | Select-Object Name, CurrentValue | Where-Object { $_.Name -eq "Size" }).CurrentValue
        if ($usage -eq 0) {
            $ecr += $registry
        }
    }
    return $ecr
}

function FindEmptyNatGateway {
    $Vnets = Get-AzVirtualNetwork
    $Natgateways = Get-AzNatGateway
    $isExists = $false
    $ONatG = @()
    foreach ($NG in $Natgateways) {
        foreach ($Vnet in $Vnets) {
            if (-not $isExists) {
                foreach ($subnet in $Vnet.Subnets) {
                    if ($subnet.NatGateway.Id -eq $NG.Id) {
                        $isExists = $true
                        break
                    }
                }
            }
        }
        if (-not $isExists) {
            $ONatG += $NG
        }
    }
    return $ONatG
}

function FindEmptyASRVault {
    $allVaults = Get-AzRecoveryServicesVault
    $replicatedFlag = $false
    $BackupFlag = $false
    $BackupContainerTypes = @("AzureVM", "Windows", "AzureStorage", "AzureVMAppContainer")
    $Workloadtype = @("AzureVM", "AzureFiles", "MSSQL", "FileFolder", "SAPHanaDatabase")
    $BackupManagementType = @("AzureVM", "MAB", "AzureWorkload", "AzureStorage")
    $EASR = @()
    foreach ($vault in $allVaults) {
        Set-AzRecoveryServicesAsrVaultContext -Vault $vault -ErrorAction SilentlyContinue
        $fabrics = Get-AzRecoveryServicesAsrFabric -ErrorAction SilentlyContinue
        foreach ($fabric in $fabrics) {
            $containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric -ErrorAction SilentlyContinue
            foreach ($container in $containers) {
                if (Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container -ErrorAction SilentlyContinue) {
                    $replicatedFlag = $true
                    break
                }
            }
            if ($replicatedFlag) {
                break
            }
        }
        foreach ($type in $BackupContainerTypes) {
            if ($type -eq "Windows") {
                $containers = @()
                foreach ($managementType in $BackupManagementType) {
                    $containers += Get-AzRecoveryServicesBackupContainer -ContainerType $type -Status "Registered" -BackupManagementType $managementType -VaultId $vault.ID -ErrorAction SilentlyContinue
                }
            }
            else { $Containers = Get-AzRecoveryServicesBackupContainer -ContainerType $type -Status "Registered" -VaultId $vault.ID -ErrorAction SilentlyContinue }
            foreach ($container in $containers) {
                foreach ($worktype in $Workloadtype) {
                    if (Get-AzRecoveryServicesBackupItem -Container $Container -WorkloadType $worktype -VaultId $vault.ID -ErrorAction SilentlyContinue) {
                        $BackupFlag = $true
                        break
                    }
                }
                if ($BackupFlag) {
                    break
                }
            }
            if ($BackupFlag) {
                break
            }
        }
        if (!$BackupFlag -and !$replicatedFlag) {
            $EASR += $vault
        }
        $BackupFlag = $false
        $replicatedFlag = $false
    }
    return $EASR
}


function findEmptyBackupVault {
    param
    (
        $RG
    )
    $EmptyBackupVaults = @()
    foreach ($group in $RG) {
        $allBackupVaults = Get-AzDataProtectionBackupVault -ResourceGroupName $group
        foreach ($vault in $allBackupVaults) {
            if (!(Get-AzDataProtectionBackupInstance -ResourceGroupName $group -VaultName $vault.Name)) {
                $EmptyBackupVaults += $vault
            }
        }
    }
    return $EmptyBackupVaults
}


$FileLocation = "./Orphaned.csv"
Login-AzAccount -TenantId "d4187394-68c7-4e1b-840d-3507a69b9230"
New-Item -Path "./" -Name "Orphaned.csv"
Add-Content -Path $FileLocation -Value "Resource Id,Type"
$subs = Get-AzSubscription -WarningAction SilentlyContinue | Where-Object { ($_.Id -ne "0cc4f4ea-1137-4602-8a11-4aeaf8322156") -and ($_.Id -ne "ad0e1789-1ed8-4f92-9512-0cfae867069a") -and ($_.Id -ne "ac7ee52c-3b51-43b5-b667-2498be58418b") -and ($_.State -ne "Disabled") }
$OR = @{"Public_IPs" = @(); "LoadBalancers" = @(); "Disks" = @(); "App_Service_Plan" = @(); "Nics" = @(); "Vnet" = @(); "RouteTable" = @(); "Virtual_Private_Gateway" = @(); "Local_Network_Gateway" = @(); "Private_DNS" = @(); "Availability_Sets" = @(); "Container_Registry" = @(); "Nat_Gateway" = @(); "Service_Recovery_Vaults" = @(); "Backup_Vaults" = @() }
$count = 1
foreach ($sub in $subs) {
    Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue
    $allresources = Get-AzResource
    $ASPRG = $allresources | Where-Object { $_.Type -eq "Microsoft.Web/serverfarms" } | ForEach-Object { $_.ResourceGroupName } | Sort-Object | Get-Unique
    $VPNRG = $allresources | Where-Object { $_.Type -eq "Microsoft.Network/connections" -or $_.Type -eq "Microsoft.Network/virtualNetworkGateways" } | ForEach-Object { $_.ResourceGroupName } | Sort-Object | Get-Unique
    $LNGRG = $allresources | Where-Object { $_.Type -eq "Microsoft.Network/connections" -or $_.Type -eq "Microsoft.Network/localNetworkGateways" } | ForEach-Object { $_.ResourceGroupName } | Sort-Object | Get-Unique
    $BVRG = $allresources | Where-Object { $_.Type -eq "Microsoft.DataProtection/BackupVaults" } | ForEach-Object { $_.ResourceGroupName } | Sort-Object | Get-Unique
    $OR.Public_IPs += FindOrphanedIPs
    $OR.LoadBalancers += FindOrphanedLoadBalancers
    $OR.Disks += FindOrphanedDisks
    $OR.App_Service_Plan += FindOrphanedASP -RG $ASPRG
    $OR.Nics += FindOrphanedNics
    $OR.Vnet += FindEmptyVnet
    $OR.RouteTable += FindEmptyRouteTables
    $OR.Virtual_Private_Gateway += FindOrphanedVPNs -RG $VPNRG
    $OR.Local_Network_Gateway += FindOrphanedLNG -RG $LNGRG
    $OR.Private_DNS += FindEmptyPrivateDnsZones
    $OR.Availability_Sets += FindEmptyAvailabilitySets
    $OR.Container_Registry += FindEmptyContainerRegistry
    $OR.Nat_Gateway += FindEmptyNatGateway
    $OR.Service_Recovery_Vaults += FindEmptyASRVault
    $OR.Backup_Vaults += findEmptyBackupVault -RG $BVRG
    Write-Host "$($count)/$($subs.Count) Finished" -ForegroundColor Green
    $count++
}

Write-Host $OR.Backup_Vaults.Name
# foreach ($objectType in $OR.Keys) {
#     foreach ($object in $OR[$objectType]) {
#         Add-Content -Path $FileLocation -Value "$($object.Id),$($object.Type)"
#     }
# }