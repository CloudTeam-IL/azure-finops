#!/usr/bin/env python3

######################################################################################################################

#  Copyright 2021 CloudTeam & CloudHiro Inc. or its affiliates. All Rights Reserved.                                 #

#  You may not use this file except in compliance with the License.                                                  #

#  https://www.cloudhiro.com/AWS/TermsOfUse.php                                                                      #

#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES                                                  #

#  OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions    #

#  and limitations under the License.                                                                                #

######################################################################################################################

# Import module dependencies
from typing import List
from azure.mgmt import core, resource
from azure.mgmt import compute
from azure.mgmt.monitor import MonitorManagementClient
from azure.mgmt.resource import SubscriptionClient, subscriptions
from azure.mgmt.resource import ResourceManagementClient
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.billing import BillingManagementClient
import datetime ,os
import csv
from datetime import date, timedelta
from azure.common.credentials import ServicePrincipalCredentials
# For vscode login
from azure.identity import AzureCliCredential
from isodate.isostrf import DATE_BAS_ORD_COMPLETE
import adal


credential = None

# For Azure portal login
if os.getenv('AUTOMATION_ASSET_ACCOUNTID'):
    import automationassets

    def get_automation_runas_credential(runas_connection):
        from OpenSSL import crypto
        import binascii
        from msrestazure import azure_active_directory
        import adal

        # Get the Azure Automation RunAs service principal certificate
        cert = automationassets.get_automation_certificate("AzureRunAsCertificate")
        pks12_cert = crypto.load_pkcs12(cert)
        pem_pkey = crypto.dump_privatekey(
            crypto.FILETYPE_PEM, pks12_cert.get_privatekey())

        # Get run as connection information for the Azure Automation service principal
        application_id = runas_connection["ApplicationId"]
        thumbprint = runas_connection["CertificateThumbprint"]
        tenant_id = runas_connection["TenantId"]

        # Authenticate with service principal certificate
        resource = "https://management.core.windows.net/"
        authority_url = ("https://login.microsoftonline.com/"+tenant_id)
        context = adal.AuthenticationContext(authority_url)
        return azure_active_directory.AdalAuthentication(
            lambda: context.acquire_token_with_client_certificate(
                resource,
                application_id,
                pem_pkey,
                thumbprint)
        )

    # Authenticate to Azure using the Azure Automation RunAs service principal
    runas_connection = automationassets.get_automation_connection(
        "AzureRunAsConnection")
    credential = get_automation_runas_credential(runas_connection)

else:
    credential = AzureCliCredential()

# Initiate sub client
subscription_client = SubscriptionClient(credential)
subscription_ids = subscription_client.subscriptions.list()

# Initiate function to filter vms by tag.
def tag_is_present(tags_dict):
    return tags_dict and tags_dict.get('right_size') == 'false'

# Iterate through all subs and export data utilization to CSV.
with open('/home/yahav/right_sizing.csv', 'a') as file:
    field_names = ['Subscription Name','ResourceGroup','Location','Resource id', 'Previous Size','Current Size','Tags']
    writer = csv.DictWriter(file, fieldnames=field_names)
    writer.writeheader()
    for sub in list(subscription_ids):
        compute_client = ComputeManagementClient(credential, subscription_id=sub.subscription_id)
        resource_list = ResourceManagementClient(credential, subscription_id=sub.subscription_id)
        tagged_vms = [vm for vm in compute_client.virtual_machines.list_all() if tag_is_present(vm.tags)]
        original_size = {}
        # Iterate through all tagged vms and get there hardware specs(Memory ,CPU).
        for vm in tagged_vms:
            original_size[vm.name] = vm.hardware_profile.vm_size
            list_vm_sizes = compute_client.virtual_machine_sizes.list(location=vm.location)
            for vm_size in list_vm_sizes:
                if (original_size[vm.name]) in vm_size.name:
                    cores = vm_size.number_of_cores
                    memory = vm_size.memory_in_mb
                    size = vm_size.name
        # Iterate through all available sizes and resize by 2.
        # for vm in tagged_vms:
                    right_size = ""
                    available_sizes = compute_client.virtual_machines.list_available_sizes(resource_group_name=vm.id.split('/')[4],vm_name=vm.name)
                    for a in list(available_sizes):
                        if a.number_of_cores >= cores/2 and a.number_of_cores < cores and a.memory_in_mb >= memory/2 and a.memory_in_mb < memory:
                            # If vms are in Promo(Preview) size than resize them also to Promo.
                            if original_size[vm.name].split('_')[-1] == "Promo":
                                if (len(original_size[vm.name].split('_'))) == len(a.name.split('_')) and a.name.split('_')[1].startswith(original_size[vm.name].split('_')[1][0]) and a.name.split('_')[-2] == original_size[vm.name].split('_')[-2]:
                                    if all(l[0] == l[1] for l in zip(original_size[vm.name], a.name) if not l[0].isdigit()):
                                        right_size = a.name
                                        break
                            # If vms are not in Promo(Preview) size than resize them to regular size.
                            elif (len(original_size[vm.name].split('_'))) == len(a.name.split('_')) and a.name.split('_')[1].startswith(original_size[vm.name].split('_')[1][0]):
                                if (len(original_size[vm.name].split('_'))) == 4 and a.name.split('_')[-1] == original_size[vm.name].split('_')[-1] and a.name.split('_')[-2] == original_size[vm.name].split('_')[-2]:
                                    if all(l[0] == l[1] for l in zip(original_size[vm.name], a.name) if not l[0].isdigit()):
                                        right_size = a.name
                                        break
                                if (len(original_size[vm.name].split('_'))) == 3:
                                    if a.name.split('_')[-1] == original_size[vm.name].split('_')[-1]:
                                        if all(l[0] == l[1] for l in zip(original_size[vm.name], a.name) if not l[0].isdigit()):
                                            right_size = a.name
                                            break
                                if (len(original_size[vm.name].split('_'))) == 2:
                                    if all(l[0] == l[1] for l in zip(original_size[vm.name], a.name) if not l[0].isdigit()):
                                        right_size = a.name
                                        break
                    # If there is no options to resize the vm and export to CSV.
                    if not right_size:
                        writer.writerow({'Resource id': vm.id,'Current Size': original_size[vm.name]})
                        print(f"No Available Resize For The VM: '{vm.name}'")
                    # Resize the vm and export all the data into CSV.
                    else:
                        vm_resize = compute_client.virtual_machines.begin_update(resource_group_name=vm.id.split('/')[4],vm_name=vm.name,parameters={'location': vm.location, 'hardware_profile':{'vm_size': right_size}})
                        # vm_del_tag = resource_list.tags.delete(tag_name='candidate')
                        vm_log = compute_client.virtual_machines.get(resource_group_name=vm.id.split('/')[4],vm_name=vm.name)
                        # Validate if the vm changed her size and print
                        if vm_log.hardware_profile.vm_size == right_size:
                            writer.writerow({'Subscription Name': sub.display_name,'ResourceGroup': vm_log.id.split('/')[4],'Location': vm_log.location, 'Resource id': vm.id,'Previous Size': original_size[vm_log.name],'Current Size': right_size,'Tags': vm_log.tags})
                            print(f"Vm Name:'{vm_log.name}' Changed from {original_size[vm_log.name]} To {right_size}")
                        else:
                            print(f"Falied to change {vm_log.name} size.")
