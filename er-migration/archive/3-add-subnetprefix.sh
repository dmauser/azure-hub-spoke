#Parameters
rg=lab-er-migration #Define your resource group
location=westus3 #Set location


# Ref: https://learn.microsoft.com/en-us/azure/virtual-network/how-to-multiple-prefixes-subnet?branch=main&branchFallbackFrom=pr-en-us-267737&tabs=cli
# Adding 10.0.0.64/26
az network vnet subnet update --name GatewaySubnet --vnet-name az-hub-vnet -g $rg --address-prefixes 10.0.0.32/27 10.0.0.64/26

# Show
az network vnet subnet show --name GatewaySubnet --vnet-name az-hub-vnet -g $rg --query addressPrefixes -o tsv




