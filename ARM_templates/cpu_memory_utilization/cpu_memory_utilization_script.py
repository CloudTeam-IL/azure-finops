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
# from typing import List
from logging import exception
from azure.mgmt.monitor import MonitorManagementClient
from azure.mgmt.resource import SubscriptionClient, subscriptions
from azure.mgmt.resource import ResourceManagementClient
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.billing import BillingManagementClient
import datetime,csv,os
from datetime import date, timedelta
from azure.common.credentials import ServicePrincipalCredentials
# For Azure portal login
# import automationassets
# For vscode login
from azure.identity import AzureCliCredential
from isodate.isostrf import DATE_BAS_ORD_COMPLETE
import adal
import argparse
from azure.core.exceptions import ResourceExistsError

# parser = argparse.ArgumentParser(description='Please insert subscription id.')
# parser.add_argument('subid', type=str)
# args = parser.parse_args()

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

today = date.today()
last_two_weeks = today - datetime.timedelta(days=14)

# Monitor function for vms by cpu.
def fetch_metrics_cpu (monitor_client, resource_id, interval = 'PT24H'):
    metrics_data = monitor_client.metrics.list(
        resource_id,
        timespan="{}/{}".format(last_two_weeks, today),
        interval=interval,
        metricnames='Percentage CPU',
        aggregation='Average,Maximum',
    )
    # Get vm metrics by cpu average/maximum usage utilization.
    sum = 0 
    count = 0 
    max = 0
    for item in metrics_data.value:
        for timeserie in item.timeseries:
            for data in timeserie.data:
                if not data.average or not data.maximum:
                    data.average = 0
                    data.maximum = 0
                sum = sum + data.average
                if data.maximum > max:
                    max = data.maximum
                count = count + 1
    if count == 0 or sum == 0:
        count = 1
        sum = 1
    return [resource_id, sum/count, max]



# Monitor function for vms by memory.
def fetch_metrics_memory (monitor_client, resource_id, interval = 'PT24H'):
    metrics_data = monitor_client.metrics.list(
        resource_id,
        timespan="{}/{}".format(last_two_weeks, today),
        interval=interval,
        metricnames='Available Memory Bytes',
        aggregation='Average,Maximum',
    )
    # Get vm metrics by memory average/maximum usage utilization.
    sum = 0 
    count = 0 
    max = 0
    for item in metrics_data.value:
        for timeserie in item.timeseries:
            for data in timeserie.data:
                if not data.average or not data.maximum:
                    data.average = 0
                    data.maximum = 0
                sum = sum + data.average
                if data.maximum > max:
                    max = data.maximum
                count = count + 1 
    if count == 0 or sum == 0:
        count = 1
        sum = 1
    return [((sum/count)/1000)/1000, (max/1000)/1000]


lt_50 = "False"


# Iterate all vms and export data utilization to CSV.
with open('/home/yahav/cpu_memory_utilization_average.csv', 'a') as file:
    field_names = ['Resource id', 'Average CPU','Maximum CPU','Average Memory','Maximum Memory' ,'Total Memory(MB)', 'Vm Size', 'Region','LT 50%']
    writer = csv.DictWriter(file, fieldnames=field_names)
    writer.writeheader()
    for sub in list(subscription_ids):
        compute_client = ComputeManagementClient(credential, subscription_id=sub.subscription_id)
        monitor_client = MonitorManagementClient(credential, subscription_id=sub.subscription_id)
        resource_client = ResourceManagementClient(credential, subscription_id=sub.subscription_id)
        # resource_group_client = ResourceManagementClient(credential, subscription_id=sub.subscription_id)
        
        vm_list = compute_client.virtual_machines.list_all()
        # rg_list = resource_group_client.resource_groups.list()
        # for rg in rg_list:
        for vm in list(vm_list):
            generalized_vms = compute_client.virtual_machines.get(resource_group_name=vm.id.split('/')[4], vm_name=vm.name,expand='instanceView')
            generalized = generalized_vms.instance_view.statuses
            # Exclude vms that in "OSState/generalized" state.
            if generalized[0].code == "OSState/generalized":
                continue
            vm_list_size = compute_client.virtual_machine_sizes.list(vm.location)            
            for vm_size in list(vm_list_size):
                if vm.hardware_profile.vm_size == vm_size.name:
                    fetch_data_cpu = fetch_metrics_cpu(monitor_client, vm.id)
                    fetch_data_memory = fetch_metrics_memory(monitor_client, vm.id)
                    #Check if Maximum CPU and Maximum Memory are less than 50% in use - if yes than tag them with {'right_size': 'true'}.
                    if (fetch_data_cpu[2] < 50 and fetch_data_memory[1]/vm_size.memory_in_mb*100 < 50):
                        lt_50 = "True"

                        body = {
                                'operation': 'Merge',
                                "properties" : { 
                                    'tags': 
                                        {'candidate': 'right_size'},
                                }
                            }
                        try:
                            vm_tagging = resource_client.tags.update_at_scope(vm.id , body)
                            writer.writerow({'Resource id': fetch_data_cpu[0], 'Average CPU': fetch_data_cpu[1], 'Maximum CPU': fetch_data_cpu[2],'Average Memory': (fetch_data_memory[0]/vm_size.memory_in_mb)*100, 'Maximum Memory': (fetch_data_memory[1]/vm_size.memory_in_mb)*100 ,'Total Memory(MB)': vm_size.memory_in_mb ,'Vm Size': vm.hardware_profile.vm_size ,'Region': vm.location,
                            'LT 50%':  lt_50})
                        except ResourceExistsError as e:
                            writer.writerow({'Resource id': fetch_data_cpu[0], 'Average CPU': fetch_data_cpu[1], 'Maximum CPU': fetch_data_cpu[2],'Average Memory': (fetch_data_memory[0]/vm_size.memory_in_mb)*100, 'Maximum Memory': (fetch_data_memory[1]/vm_size.memory_in_mb)*100 ,'Total Memory(MB)': vm_size.memory_in_mb ,'Vm Size': vm.hardware_profile.vm_size ,'Region': vm.location,
                            'LT 50%':  "SPOT"})
                    else:
                        writer.writerow({'Resource id': fetch_data_cpu[0], 'Average CPU': fetch_data_cpu[1], 'Maximum CPU': fetch_data_cpu[2],'Average Memory': (fetch_data_memory[0]/vm_size.memory_in_mb)*100, 'Maximum Memory': (fetch_data_memory[1]/vm_size.memory_in_mb)*100 ,'Total Memory(MB)': vm_size.memory_in_mb ,'Vm Size': vm.hardware_profile.vm_size ,'Region': vm.location,
                        'LT 50%':  "False"})
        
