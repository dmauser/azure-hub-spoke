#Parameters
rg=lab-er-migration #Define your resource group
location=westus3 #Set location

# Establish ssh using native Azure Bastion in Azure Cloud Shell
az network bastion ssh --name az-hub-bastion --resource-group $rg --target-resource-id $(az vm show -g $rg -n az-hub-lxvm --query id -o tsv) --auth-type password --username azureuser

# Using hping3 to test connectivity to 10.0.1.4

# Redo the loop script above by adding a timestamp to the output
#!/bin/bash
while true; do echo -n "$(date) "; netcat -v -z 10.0.0.4 22; sleep 1; done

while true; do echo -n "$(date) "; netcat -v -z 192.168.100.2 22; sleep 1; done


# need similar test above using hping3
#!/bin/bash
sudo nping 10.0.0.4 --tcp -p 82 -c 100000

sudo apt install tcptraceroute
sudo wget http://www.vdberg.org/~richard/tcpping -O /usr/bin/tcping
sudo chmod 755 /usr/bin/tcping

tcping -d 192.168.100.2 22
tcping -d 10.0.0.4 22

# Admin property
# https://learn.microsoft.com/en-us/dotnet/api/microsoft.azure.management.network.models.virtualnetworkgateway.adminstate?view=az-ps-latest

# Lista all ExpressRoute Gateways in the resource group
az network vnet-gateway list --resource-group $rg --query [].name -o tsv


######### ER Gateways BGP and Routes #########
# Get the BGP peer status for all ExpressRoute Gateways in the resource group
ergwnames=$(az network vnet-gateway list --resource-group $rg --query "[].name" -o tsv)
for ergwname in $ergwnames; do
    echo ExpressRoute Gateway name $ergwname:
    az network vnet-gateway list-bgp-peer-status --name $ergwname --resource-group $rg -o table
done

# Get the BGP peer status for all ExpressRoute Gateways in the resource group
ergwnames=$(az network vnet-gateway list --resource-group $rg --query "[].name" -o tsv)
for ergwname in $ergwnames; do
    echo ExpressRoute Gateway learned routes for $ergwname: 
    az network vnet-gateway list-learned-routes --name $ergwname --resource-group $rg -o table
done

######### Dump ExpressRoute Circuit Routes #########
# Get the ExpressRoute Circuit Routes for all ExpressRoute Circuits in the resource group
ercircuitnames=$(az network express-route list --resource-group $rg --query "[].name" -o tsv)
for ercircuitname in $ercircuitnames; do
    echo ExpressRoute Circuit Routes for $ercircuitname:
    az network express-route list-route-tables --name $ercircuitname --path Primary --resource-group $rg --query value --peering-name AzurePrivatePeering -o table
done

######### Admin State to Control Migration #########
# Get AdminState of all ExpressRoute Gateways in the resource group
echo ExpressRoute Gateway AdminState:
for i in $(az network vnet-gateway list --resource-group $rg --query [].name -o tsv); 
do 
 echo $i: $(az network vnet-gateway show --name $i --resource-group $rg --query adminState -o tsv)
done

# Migrate from az-hub-ergw to az-hub-ergw_migrated
az network vnet-vpn-gateway update --name az-hub-ergw_migrated --resource-group $rg --set adminState=Enabled -o none
az network vnet-gateway update --name az-hub-ergw --resource-group $rg --set adminState=Disabled -o none

# Can both be enabled at the same time? :-)
az network vnet-vpn-gateway update --name az-hub-ergw_migrated --resource-group $rg --set adminState=Enabled -o none
az network vnet-gateway update --name az-hub-ergw --resource-group $rg --set adminState=Enabled -o none

# Reverting back to original 
az network vnet-gateway update --name az-hub-ergw --resource-group $rg --set adminState=Enabled -o none
az network vnet-vpn-gateway update --name az-hub-ergw_migrated --resource-group $rg --set adminState=Disabled -o none




