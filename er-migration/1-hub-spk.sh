#Parameters
rg=lab-er-migration #Define your resource group
location=westus3 #Set location
username=azureuser #Set username
password=Msft123Msft123 #Set password
virtualMachineSize=Standard_DS1_v2 #Set VM size

#Variables
mypip=$(curl -4 ifconfig.io -s) #Captures your local Public IP and adds it to NSG to restrict access to SSH only for your Public IP.

#Define parameters for Azure Hub and Spokes:
AzurehubName=az-hub #Azure Hub Name
AzurehubaddressSpacePrefix=10.0.0.0/24 #Azure Hub VNET address space
AzurehubNamesubnetName=subnet1 #Azure Hub Subnet name where VM will be provisioned
Azurehubsubnet1Prefix=10.0.0.0/27 #Azure Hub Subnet address prefix
AzurehubgatewaySubnetPrefix=10.0.0.32/27 #Azure Hub Gateway Subnet address prefix
AzureFirewallPrefix=10.0.0.64/26 #Azure Firewall Prefix
AzurehubrssubnetPrefix=10.0.0.128/27 #Azure Hub Route Server subnet address prefix
AzureHubBastionSubnet=10.0.0.192/26
Azurespoke1Name=az-spk1 #Azure Spoke 1 name
Azurespoke1AddressSpacePrefix=10.0.1.0/24 # Azure Spoke 1 VNET address space
Azurespoke1Subnet1Prefix=10.0.1.0/27 # Azure Spoke 1 Subnet1 address prefix
Azurespoke2Name=az-spk2 #Azure Spoke 2 name
Azurespoke2AddressSpacePrefix=10.0.2.0/24 # Azure Spoke 1 VNET address space
Azurespoke2Subnet1Prefix=10.0.2.0/27 # Azure Spoke 1 VNET address space

#Parsing parameters above in Json format (do not change)
JsonAzure={\"hubName\":\"$AzurehubName\",\"addressSpacePrefix\":\"$AzurehubaddressSpacePrefix\",\"subnetName\":\"$AzurehubNamesubnetName\",\"subnet1Prefix\":\"$Azurehubsubnet1Prefix\",\"AzureFirewallPrefix\":\"$AzureFirewallPrefix\",\"gatewaySubnetPrefix\":\"$AzurehubgatewaySubnetPrefix\",\"rssubnetPrefix\":\"$AzurehubrssubnetPrefix\",\"bastionSubnetPrefix\":\"$AzureHubBastionSubnet\",\"spoke1Name\":\"$Azurespoke1Name\",\"spoke1AddressSpacePrefix\":\"$Azurespoke1AddressSpacePrefix\",\"spoke1Subnet1Prefix\":\"$Azurespoke1Subnet1Prefix\",\"spoke2Name\":\"$Azurespoke2Name\",\"spoke2AddressSpacePrefix\":\"$Azurespoke2AddressSpacePrefix\",\"spoke2Subnet1Prefix\":\"$Azurespoke2Subnet1Prefix\"}

#Deploy base lab environment = Hub + VPN Gateway + VM and two Spokes with one VM on each.
echo Deploying base lab: Hub with Spoke1 and 2. VMs and Azure Route Server.
echo "*** It will take around 20 minutes to finish the deployment ***"
az group create --name $rg --location $location --output none
az deployment group create --name lab-$RANDOM --resource-group $rg \
--template-uri https://raw.githubusercontent.com/dmauser/azure-hub-spoke-base-lab/main/azuredeployv5.json \
--parameters Restrict_SSH_VM_AccessByPublicIP=$mypip deployHubERGateway=true Azure=$JsonAzure VmAdminUsername=$username VmAdminPassword=$password virtualMachineSize=$virtualMachineSize deployBastion=true \
--output none \
--no-wait

# Step 2 - Create an ExpressRoute Circuit

# 1) Create ExpressRoute Circuit
# In this example ExpressRoute is created in Chicago using Mepgaport as Provider. Make the necessary changes based on your needs
# Define variables
ername=$(echo $rg) # ExpressRoute Circuit Name
cxlocation="Chicago" #Peering Location
provider=Megaport # Provider
az network express-route create --bandwidth 50 -n $ername --peering-location $cxlocation -g $rg --provider $provider -l $location --sku-family MeteredData --sku-tier Standard -o none

# Display express route circuit service key
az network express-route show -n $ername -g $rg --query serviceKey -o tsv

# Only continue if the ExpressRoute Circuit has provider provisioning state as Provisioned
while [ $(az network express-route show -n $ername -g $rg --query serviceProviderProvisioningState -o tsv) != "Provisioned" ]; do echo "Waiting for ExpressRoute Circuit to be provisioned at the Provider..."; sleep 30; done

# Only continue if ExpressRoute Gateways has provisioning state as Succeeded
while [ $(az network vnet-gateway  list -g $rg --query '[].provisioningState' -o tsv) != "Succeeded" ]; do echo "Waiting for ExpressRoute Gateway to be provisioned..."; sleep 30; done

# Step 4 - Attach ER Circuit to the VNET ERGW on hub and Hub2
# Add check for Service Provider serviceProviderProvisioningState = Provisioned
erid=$(az network express-route show -n $ername -g $rg --query id -o tsv) 
az network vpn-connection create --name er-connection-to-hub \
--resource-group $rg --vnet-gateway1 az-hub-ergw \
--express-route-circuit2 $erid \
--routing-weight 0 \
--output none

### Installing tools for networking connectivity validation such as traceroute, tcptraceroute, iperf and others (check link below for more details) 
echo "Installing net utilities inside VMs (traceroute, tcptraceroute, iperf3, hping3, and others)"
nettoolsuri="https://raw.githubusercontent.com/dmauser/azure-vm-net-tools/main/script/nettools.sh"
for vm in `az vm list -g $rg --query "[?contains(storageProfile.imageReference.publisher,'Canonical')].name" -o tsv`
do
 az vm extension set --force-update \
 --resource-group $rg \
 --vm-name $vm \
 --name customScript \
 --publisher Microsoft.Azure.Extensions \
 --protected-settings "{\"fileUris\": [\"$nettoolsuri\"],\"commandToExecute\": \"./nettools.sh\"}" \
 --no-wait
done