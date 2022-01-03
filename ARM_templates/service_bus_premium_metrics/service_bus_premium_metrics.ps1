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
    [String] $ConnectionString = "DefaultEndpointsProtocol=https;AccountName=cloudshellctigor;AccountKey=NjzBq9pCQqY0Nz5KNbi9uXIg9tYTn6tCtlZY4W3ou22O2e5CUua2Vs46zX1I+y0gbhkmU5svgL2etXdBpk/G+Q==;EndpointSuffix=core.windows.net",
    [String] $BlobContainer = "reports-test",
    # Number of days to look backwards.
    [int]    $daysChart = "14",
    # Cpu utilization in %
    [int]    $cpuPrecentage = "20"
          

)


Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Starting' -f (Get-Date))
try {


    # Login to Azure
    if ($env:AUTOMATION_ASSET_ACCOUNTID) {
        $runAsConnection = Get-AutomationConnection -Name $ConnectionName -ErrorAction Stop
        Add-AzAccount -ServicePrincipal -Tenant $runAsConnection.TenantId -ApplicationId $runAsConnection.ApplicationId `
            -CertificateThumbprint $runAsConnection.CertificateThumbprint -ErrorAction Stop | Out-Null
    }

    # Initialzie the blob stprage connection using the connection string parameter
    $blobStorageContext = New-AzStorageContext -ConnectionString $ConnectionString
    # Get the current time by timezone
    #$currentTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($($(Get-Date).ToUniversalTime()), $([System.TimeZoneInfo]::GetSystemTimeZones() | Where-Object { $_.Id -match "Israel" }))
    $currentTime = Get-Date
    # Creating the name of the CSV file blob
    $blobName = $("service_bus_data_$(Get-Date -Date $currentTime -Format 'dd-MM-yyyy_HH:mm:ss').csv")
    # Craeting the temporary local CSV file
    New-Item -Name "tempFile.csv" -ItemType File -Force | Out-Null
    # Copying the the temporary CSV file to the blob storage container as an append blob
    Set-AzStorageBlobContent -File ".\tempFile.csv" -Blob $blobName -Container $BlobContainer -BlobType Append -Context $blobStorageContext -Force | Out-Null
    # Get the CSV file blob from the container in the storage account
    $blobStorage = Get-AzStorageBlob -Blob $blobName -Container $BlobContainer -Context $blobStorageContext
    # Add the header to the CSV file
    $blobStorage.ICloudBlob.AppendText("sub_name,resource_group,resource_name,current_units,min_units,max_units,cpu_usage(%),memory_usage(%),service_tier,resource_id,location,auto_scale,tags`n")

    Get-AzSubscription | Where-Object { ($_.Name -match ".*") -and ($_.State -eq 'Enabled') } | ForEach-Object {
        $subscriptionName = $_.Name
        Write-Output ('Switching to subscription: {0}' -f $_.Name)
        $null = Set-AzContext -SubscriptionObject $_ -Force

        
        # Set-AzContext -SubscriptionName "Aviad@Energyteam" -Force | Out-Null

        $datenow = Get-Date
        $getServiceBus = Get-AzServiceBusNamespace -WarningAction SilentlyContinue
        $resizeTag = "resize"
        foreach ($sbid in $getServiceBus) {

            if (($sbid.Sku.Name -eq "Premium") -and ($sbid.Sku.Capacity -gt 1)) {
                az account set --subscription $subscriptionName | Out-Null
                $autoScale = $(az monitor autoscale list --resource-group $sbid.Id.Split('/')[4] --query "[?contains(name,'$($sbid.Name)-Autoscale-')]") | ConvertFrom-Json -ErrorAction SilentlyContinue              
                # Check if ServiceBus has an Auto Scale
                
                if (-not $autoScale) {

                    $cpuMetrics = Get-AzMetric -ResourceId $sbid.Id -MetricName "NamespaceCpuUsage" -StartTime $datenow.AddDays(-$daysChart) -EndTime $datenow -AggregationType "Maximum" -TimeGrain 01:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                    $memoryMetrics = Get-AzMetric -ResourceId $sbid.Id -MetricName "NamespaceMemoryUsage" -StartTime $datenow.AddDays(-$daysChart) -EndTime $datenow -AggregationType "Maximum" -TimeGrain 01:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

                    $cpuPrecent = ($cpuMetrics.Data.Maximum | Sort-Object -Descending | Select-Object -First 1)
                    $memoryPrecent = ($memoryMetrics.Data.Maximum | Sort-Object -Descending | Select-Object -First 1) 
                    
                    $tags = $sbid.Tags.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }
                    # Check if cpu utilization less than X and if yes export to CSV.                
                    if ($cpuPrecent -lt $cpuPrecentage) {
                        #Update-AzTag -ResourceId $sbid.Id -Tag @{ candidate = $resizeTag } -Operation Merge
                        $blobStorage.ICloudBlob.AppendText("$subscriptionName, $($sbid.ResourceGroupName),$($sbid.Name),$($sbid.Sku.Capacity),None,None,$($cpuPrecent),$($memoryPrecent),$($sbid.Sku.Name), $($sbid.Id),$($sbid.Location),No,$($tags)`n")
                    }
                }
                else {
                    # Check auto-scale setting if exist , Than check if CPU is underutilaized if yes consider to scale in auto-scale minimum unit.                
                    $getMinimumScaleCapacity = $autoScale.Profiles.Capacity.Minimum | Select-Object -First 1
                    $cpuMetrics3Days = Get-AzMetric -ResourceId $sbid.Id -MetricName "NamespaceCpuUsage" -StartTime $datenow.AddDays(-3) -EndTime $datenow -AggregationType "Maximum" -TimeGrain 01:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                    $memoryMetrics3Days = Get-AzMetric -ResourceId $sbid.Id -MetricName "NamespaceMemoryUsage" -StartTime $datenow.AddDays(-3) -EndTime $datenow -AggregationType "Maximum" -TimeGrain 01:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                    
                    $cpuPrecent3Days = ($cpuMetrics3Days.Data.Maximum | Sort-Object -Descending | Select-Object -First 1)
                    $memoryPrecent3Days = ($memoryMetrics.Data.Maximum | Sort-Object -Descending | Select-Object -First 1) 


                    if ($cpuPrecent3Days -lt $cpuPrecentage ) {

                        #Update-AzTag -ResourceId $sbid.Id -Tag @{ candidate = $resizeTag } -Operation Merge
                        $blobStorage.ICloudBlob.AppendText("$subscriptionName, $($sbid.ResourceGroupName),$($sbid.Name),$($sbid.Sku.Capacity),$($autoScale.Profiles.Capacity.Minimum),$($autoScale.Profiles.Capacity.Maximum),$($cpuPrecent3Days),$($memoryPrecent3Days),$($sbid.Sku.Name), $($sbid.Id),$($sbid.Location),Yes,$($tags)`n")
                    }
                }
            }
            # else {
            #     if ($sbid.Sku.Capacity -eq 1) {
            #         $cpuMetrics = Get-AzMetric -ResourceId $sbid.Id -MetricName "NamespaceCpuUsage" -StartTime $datenow.AddDays(-$daysChart) -EndTime $datenow -AggregationType "Maximum" -TimeGrain 01:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            #         $memoryMetrics = Get-AzMetric -ResourceId $sbid.Id -MetricName "NamespaceMemoryUsage" -StartTime $datenow.AddDays(-$daysChart) -EndTime $datenow -AggregationType "Maximum" -TimeGrain 01:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

                    
            #         $cpuPrecent = ($cpuMetrics.Data.Maximum | Sort-Object -Descending | Select-Object -First 1)
            #         $memoryPrecent = ($memoryMetrics.Data.Maximum | Sort-Object -Descending | Select-Object -First 1) 

            #         $tags = $sbid.Tags.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }

                    
            #         $blobStorage.ICloudBlob.AppendText("$subscriptionName, $($sbid.ResourceGroupName),$($sbid.Name),$($sbid.Sku.Capacity),$($cpuPrecent),$($memoryPrecent),$($sbid.Sku.Name), $($sbid.Id),$($sbid.Location),No,$($tags)`n")
                        
            #     }
                
        }
    }
}
catch {
    Write-Output ($_)
}
finally {
    Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Completed' -f (Get-Date))
}
