Param
(
    [Parameter (Mandatory = $false)]
    [ValidateSet(“ManagedIdentity”, ”ServicePrincipal”)]
    [String] $AccountType = "ManagedIdentity",
    [Parameter(Mandatory = $false)]
    [String] $AccountName = "",
    [Parameter (Mandatory = $false)]
    [String] $StorageForLogID,
    [Parameter (Mandatory = $false)]
    [String] $logsName = "Converting_Service_Plan_SKU",
    [Parameter (Mandatory = $false)]
    [String] $ContainerName
)


<#
    This function create the blob file inside the storage container
    INPUT:  $logName - the log file name to enter
            $ContainerName - the container name where the log is saved
            $ctx - the context of the storage account
            $LogSubjects - the subjects inside the csv log file
    
    OUTPUT: $Blob - the created blob for future writing
#>
function createLogFile {
    param (
        $LogName,
        $ContainerName,
        $ctx,
        $LogSubjects
    )
    $BlobFile = @{
        File      = ".\$($logsName)"
        Container = $ContainerName
        Blob      = $logsName
        Context   = $ctx
        BlobType  = "Append"
    }
    #pushing the blob to the container
    $Blob = Set-AzStorageBlobContent @BlobFile
    $blob.ICloudBlob.AppendText($LogSubjects)
    return $Blob
}


<#
    this function connect to azure via Service Principal
    INPUT: NONE
    OUTPUT: NONE
#>
function ConnectAsService {
    Write-Output "----Service connection----"
    $runAsConnection = Get-AutomationConnection -Name 'AzureRunAsConnection' -ErrorAction Stop
    Add-AzAccount -ServicePrincipal -Tenant $runAsConnection.TenantId -ApplicationId $runAsConnection.ApplicationId `
        -CertificateThumbprint $runAsConnection.CertificateThumbprint -ErrorAction Stop | Out-Null
}

<#
 This function connect to azure as managed identity
 INPUT: NONE
 OUTPUT: NONE
#>
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

<#
    This function checks if ASP has sites or not
    INPUT: $asp - the App Service plan
    $OUTPUT: True if it has not sites and False if it has sites
#>
function CheckToDelete {
    param(
        $asp
    )
    if ($asp.NumberOfSites -eq 0) {
        return $true
    }
    return $false
}


<#
    This function check convertions options to App service plan
    INPUT: $asp - the App Service plan
    OUTPUT: Return a string that says the convertion option or empty string
#>
function SwitchRecommendation {
    param (
        $asp
    )
    switch ($asp.sku.Name) {
        "P1v2" { return "P1v2 -> P1v3 + RI" }
        "P2v2" { return "P2v2 -> P1v3" }
        "P3v2" { return "P3v2 -> P2v3" }
        "S2" { return "S2 -> P1v3" }
        "S3" { return "S3 -> P1v3" }
        default { return "" }
    }
    
}


<#
    This function returns the subscription, resource group and name of a storage account from a resource id

    INPUT: $saID - Storage account ID
    OUTPUT: array of the data
#>
function GetStorageAccountData {
    param(
        $saID
    )
    $allSaData = $saID.Split("/")
    $neededData = @($allSaData[2], $allSaData[4], $allSaData[-1])
    return $neededData
}


#check if the script is in Automation account or local and run the desired connection
if ($env:AUTOMATION_ASSET_ACCOUNTID) {
    if ($AccountType -eq "ManagedIdentity") {
        ConnectAsIdentity
    }
    else {
        ConnectAsService
    }
}
else {
    Connect-AzAccount -TenantId "667d9faa-186f-4608-8a36-cf595f0350fb" -WarningAction SilentlyContinue
}

#connecting to the storage account and creating the blob
#$saData = GetStorageAccountData -saID $StorageForLogID
Write-Output $saData
$LogSubjects = "Resource Name,Resource Group,Subscription,Recommendation,Need To Delete?"
$subs = Get-AzSubscription
$logsName = $logsName + "_" + (Get-Date -Format "dd_MM_yyyy:HH_mm") + ".csv"
New-Item -Path . -Name $logsName
Start-Sleep -Seconds 5
Add-Content -Path "./$logsName" -Value $LogSubjects
#Set-AzContext -SubscriptionId $saData[0] -WarningAction SilentlyContinue
#$ctx = $(Get-AzStorageAccount -ResourceGroupName $saData[1] -Name $saData[2]).Context
#$blob = createLogFile -LogName $logsName -ContainerName $ContainerName -ctx $ctx -LogSubjects $LogSubjects
#itterating over all the subscriptions
foreach ($sub in $subs) {
    Set-AzContext -SubscriptionName $sub.Name -WarningAction SilentlyContinue
    #gets all the rg with app service plans
    $rg = $(get-AzResource -ResourceType "Microsoft.Web/serverFarms").ResourceGroupName
    $rg = $rg | sort | Get-Unique
    foreach ($r in $rg) {
        $asp = Get-AzAppServicePlan -ResourceGroupName $r
        foreach ($plan in $asp) {
            #checking if the ASP has any sites
            if (CheckToDelete -asp $plan) {
                #tagging for deletion and logging
                #Update-AzTag -ResourceId $plan.Id -Tag @{"Candidate" = "DeleteASP" } -Operation Merge
                #$blob.ICloudBlob.AppendText("$($plan.Name),$($r),$($sub.Name),X,V`n")
                Add-Content -Path "./$($logsName)" -Value "$($plan.Name),$($r),$($sub.Name),X,V"
            }
            #Checking if there is a recommendations for the plan
            elseif ($recommendation = SwitchRecommendation -asp $plan) {
                #tagging for convertion and logging
                #Update-AzTag -ResourceId $plan.Id -Tag @{"Candidate" = "Convert: $($recommendation)" } -Operation Merge
                #$blob.ICloudBlob.AppendText("$($plan.Name), $($r),$($sub.Name),$($recommendation),X`n")
                Add-Content -Path "./$($logsName)" -Value "$($plan.Name), $($r),$($sub.Name),$($recommendation),X"
            }
        }
    }
}