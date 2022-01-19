#!/bin/bash
cost_id=$(az ad sp list -o tsv --filter "displayname eq 'Costi'" --query '[].{id:objectId}')

if [ -z "$cost_id" ]
then
    echo no cost id
    exit
    fi

for f in $(az account list -o tsv --query "[].{id:id}")
do
    echo "/subscriptions/$f"
    az role assignment create --assignee-object-id $cost_id --scope "/subscriptions/$f" --role Reader
    az role assignment create --assignee-object-id $cost_id --scope "/subscriptions/$f" --role "Billing Reader"
    done
