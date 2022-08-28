# Tag_UnderUtilizedVMS

## About <a name = "about"></a>

This script find all the vms that are underUtilized and tag them "candidate"="rightsize".  
The script determan what is underUtilized based on cpu and ram.  
If max CPU and RAM in under 50% and avg CPU and RAM is under 40%.

### Prerequisites

This script needs the following permissions

```
Reader
Tag Contributor
Storage Blob Data Contributor (for the log's storage account)
```
and the script needs the following modules:
```
az.resourcegraph
```

### Parameters
1. AccountType - ManagedIdentity or ServicePrincipal (ManagedIdentity by default).
2. AccountName - If user assigned ManagedIdentity, then add the objectID to the automation account variables and pass the var's name to this parameter.
3. StorageAccountId - The Storage account id for the logs.
4. container - the container name for the logs.
5. LookBack - How many days to look back to check metrics.
6. MinHoursOn - minimum hours the vm should be on.
7. minPercentToReport - minimum cpu percentage to report.
