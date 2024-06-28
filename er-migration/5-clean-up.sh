#Azure Clean up
rg=lab-er-migration #Define your resource group
# Delete the resource group
az group delete --name $rg --yes --no-wait

# Define your variables
project=angular-expanse-327722 #Set your project Name. Get your PROJECT_ID use command: gcloud projects list 
region=us-central1 #Set your region. Get Regions/Zones Use command: gcloud compute zones list
zone=us-central1-c # Set availability zone: a, b or c.
vpcrange=192.168.100.0/24
envname=er-migration
vmname=vm1
mypip=$(curl -4 ifconfig.io -s) #Gets your Home Public IP or replace with that information. It will add it to the Firewall Rule.

# GCP Cleanup
gcloud compute interconnects attachments delete $envname-vlan --region $region --quiet 
gcloud compute routers delete $envname-router --region=$region --quiet
gcloud compute instances delete $envname-vm1 --zone=$zone --quiet
gcloud compute firewall-rules delete $envname-allow-traffic-from-azure --quiet
gcloud compute networks subnets delete $envname-subnet --region=$region --quiet
gcloud compute routes list --filter "network:$envname-vpc" --format="value(name)" | xargs -n 1 gcloud compute routes delete --quiet
gcloud compute networks delete $envname-vpc --quiet