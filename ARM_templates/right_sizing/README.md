# Right_Sizing
## About <a name = "about"></a>

This script getting all the deallocated VMS (To prevent DownTime) with the tag "candidate"="rightsize".  
The script checks if right sizing one tier down is possible.  
if its possible, then the script change the vm's tier.  
if its not possible, then the scripts add the tag: "candidate"="manual rightsizing".

### Prerequisites

The script needs the following Permissions:

```
reader
virtual machine contributor
```
and the script needs the following modules:
```
az.resourcegraph
```

### Parameters
1. AccountType - ManagedIdentity or ServicePrincipal (ManagedIdentity by default).
2. AccountName - If user assigned ManagedIdentity, then add the objectID to the automation account variables and pass the var's name to this parameter.

