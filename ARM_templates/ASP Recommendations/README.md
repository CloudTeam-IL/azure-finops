# App Service Plan Convertions Recommendations

## About <a name = "about"></a>

This script will give you a CSV file with the recommendations about converting/deleting app service plan, and will tag every resource.

### Prerequisites

1. automation account for the script
2. storage account for logs
3. container for the logs
4. managed identity or service principal
5. reader permissions, storage account contributor(on the storage account for the logs), tag contributor.

### Installing

1. download the script to the automation account(as powershell 7.1).
2. create a schedual in the automation account for once a week.
3. attach the script to the schedule.
4. enter the following parameters to the script:
   - (Optional) AccountType - ManagedIdentity / ServicePrincipal.  
   - (Optional) AccountName - the automation account var where the user assigned managed identity client id is saved.  
   - (Mandatory) StorageForLogID - The id for the storage account where you want to save the logs.  
   - (Optional) logsName - The name you want for the log file.  
   - (Mandatory) ContainerName - The name for the container in the storage account.
