# Azure Blob Lifecycle Management Policy

## Azure Policy definition that deploys an managementPolicies ARM Template and does the following:

<li>Deployment of the time series feature for enabling the LastAccessed rule.</li>
<li>Deployment of a Blob Lifecycle Management policy</li>
<br>

## 3 Modes:

<li><strong>LastAccessed</strong> - Last Accessed property for the policy to be based on.</li>
<li><strong>LastModified</strong> - Last Modified property for the policy to be based on.</li>
<li><strong>Disabled</strong> - Disable a tier.</li>

## - For more advanced settings, remove the hidden parameters in the policy assignment section.
