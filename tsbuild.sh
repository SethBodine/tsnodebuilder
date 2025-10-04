#!/usr/bin/env bash

# Simplified azure exit node builder (vibe coded because I'm lazy and I needed this done fast-ish)
# TS Key can be found at https://login.tailscale.com/admin/machines/new-linux

# Update as required
VM_OFFER="ubuntu-24_04-lts-daily"

usage() {
  echo "Usage:"
  echo "  bash $0 --list regions"
  echo "  bash $0 --list vms"
  echo "  bash $0 --build -h HOSTNAME -r REGION [--ssh-key /path/to/key.pub]"
  exit 1
}

check_az() {
  command -v az >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "Azure CLI not found."
    exit 1
  fi

  az account show >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "Please login to Azure CLI"
    az login --use-device-code
  fi
}

list_regions() {
  check_az
  az account list-locations -o table
}

list_vms() {
  check_az
  echo "Fetching VMs..."
  az vm list --query "[].{Name:name,RG:resourceGroup,Location:location,Power:powerState}" -o tsv | while read NAME RG LOC POWER; do
    # Try to get public IP
    PUB_IP=$(az network public-ip list --resource-group "$RG" --query "[?contains(ipConfiguration.id, '$NAME')].ipAddress" -o tsv)
    FQDN=$(az network public-ip list --resource-group "$RG" --query "[?contains(ipConfiguration.id, '$NAME')].dnsSettings.fqdn" -o tsv)
    echo -e "$NAME\t$RG\t$LOC\t$POWER\t$PUB_IP\t$FQDN"
  done
}

build_vm() {
  HOSTNAME="$1"
  REGION="$2"
  SSH_KEY="$3"

  check_az

  read -s -p "Enter Tailscale Key: " TSKEY
  echo  # to move to a new line after prompt

  # Fail if empty
  if [ -z "$TSKEY" ]; then
    echo "No Tailscale key provided. Aborting."
    exit 1
  fi

  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  CLOUD_INIT_FILE="$SCRIPT_DIR/cloud-init.yaml"

  if [ ! -f "$CLOUD_INIT_FILE" ]; then
    echo "cloud-init.yaml not found in script folder ($SCRIPT_DIR)"
    exit 1
  fi

  # --- Fetching Public IP for NSG ---
  echo "Fetching your public IP..."
  MYIP=$(curl -s ifconfig.co)
  if [ -z "$MYIP" ]; then
    echo "Could not determine public IP"
    exit 1
  fi
  echo "Detected public IP: $MYIP"

  RG="tailscale-nodes-${REGION}"

  # --- Ensure RG exists (per region) ---
  echo "Ensuring resource group $RG exists in $REGION..."
  RG_EXISTS=$(az group exists --name "$RG")
  if [ "$RG_EXISTS" = "false" ]; then
  echo "Creating resource group $RG in $REGION..."
    az group create --name "$RG" --location "$REGION" --output none
  fi

  # --- Select VM size dynamically using az vm list-skus ---
  echo "Selecting smallest available VM in $REGION..."
  VM_SIZE=$(az vm list-skus \
    --location "$REGION" \
    --size Standard_B \
    --query "sort_by([?capabilities[?name=='vCPUs' && value<=`2`] | [0] && capabilities[?name=='MemoryGB' && value<=`2`] | [0]], &capabilities[?name=='MemoryGB'].value)[0].name" \
    -o tsv)

  if [ -z "$VM_SIZE" ]; then
    echo "No VM with 2 vCPU and 2GB RAM found in $REGION. Defaulting to Standard_B1s."
    VM_SIZE="Standard_B1s"
  fi
  echo "Selected VM size: $VM_SIZE"

  # --- Select latest Ubuntu minimal LTS image dynamically ---
  echo "Selecting latest Ubuntu minimal LTS image..."
  IMAGE=$(az vm image list \
    --publisher Canonical \
    --offer "${VM_OFFER}" \
    --all \
    --query "sort_by([].{urn:urn,version:version}, &version)[-1].urn" \
    -o tsv)
  echo "Selected image: $IMAGE"

  # --- Create NSG ---
  echo "Creating network security group..."
  NSG_NAME="${HOSTNAME}-nsg"
  az network nsg create --resource-group "$RG" --name "$NSG_NAME" --location "$REGION" --output none

  echo "Adding SSH inbound rule restricted to $MYIP..."
  az network nsg rule create \
    --resource-group "$RG" \
    --nsg-name "$NSG_NAME" \
    --name "AllowSSHFromMyIP" \
    --priority 1000 \
    --protocol Tcp \
    --direction Inbound \
    --source-address-prefixes "$MYIP" \
    --source-port-ranges "*" \
    --destination-address-prefixes "*" \
    --destination-port-ranges 22 \
    --access Allow \
    --output none

  # --- Create VM ---
  echo "Creating VM..."
  DNS_LABEL="${HOSTNAME,,}"   # lowercase for DNS
  if [ -n "$SSH_KEY" ]; then
    az vm create \
      --resource-group "$RG" \
      --name "$HOSTNAME" \
      --image "$IMAGE" \
      --size "$VM_SIZE" \
      --os-disk-size-gb 5 \
      --admin-username tsuser \
      --ssh-key-values "$SSH_KEY" \
      --custom-data @"$CLOUD_INIT_FILE" \
      --nsg "$NSG_NAME" \
      --public-ip-address-dns-name "$DNS_LABEL"
  else
    az vm create \
      --resource-group "$RG" \
      --name "$HOSTNAME" \
      --image "$IMAGE" \
      --size "$VM_SIZE" \
      --os-disk-size-gb 5 \
      --admin-username tsuser \
      --generate-ssh-keys \
      --custom-data @"$CLOUD_INIT_FILE" \
      --nsg "$NSG_NAME" \
      --public-ip-address-dns-name "$DNS_LABEL"
  fi

  # --- Wait for VM to be healthy ---
  echo "Waiting for VM to be running and provisioning succeeded..."
  for i in $(seq 1 20); do
    POWER_STATE=$(az vm get-instance-view \
      --resource-group "$RG" \
      --name "$HOSTNAME" \
      --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
      -o tsv 2>/dev/null)
    PROV_STATE=$(az vm show \
      --resource-group "$RG" \
      --name "$HOSTNAME" \
      --query "provisioningState" -o tsv 2>/dev/null)
    if [ "$POWER_STATE" = "VM running" ] && [ "$PROV_STATE" = "Succeeded" ]; then
      echo "VM is running and provisioned."
      break
    fi
    echo "VM not ready yet (Power: $POWER_STATE, Provisioning: $PROV_STATE), retrying..."
    sleep 10
  done

  echo "Fetching VM details..."
  VM_PUBLIC_IP=$(az vm show -d \
    --resource-group "$RG" \
    --name "$HOSTNAME" \
    --query "publicIps" -o tsv)

  VM_FQDN=$(az vm show -d \
    --resource-group "$RG" \
    --name "$HOSTNAME" \
    --query "fqdns" -o tsv)

  echo "VM ready:"
  echo "  Hostname: $HOSTNAME"
  echo "  Public IP: $VM_PUBLIC_IP"
  echo "  FQDN: $VM_FQDN"

  echo "Waiting for VM agent to be ready..."
  for i in $(seq 1 30); do
    AGENT_STATE=$(az vm get-instance-view \
      --resource-group "$RG" \
      --name "$HOSTNAME" \
      --query "instanceView.vmAgent.statuses[0].displayStatus" -o tsv 2>/dev/null)

    if [ "$AGENT_STATE" = "Ready" ]; then
      echo "VM Agent is ready."
      break
    fi

    echo "VM Agent state: $AGENT_STATE, retrying..."
    sleep 10
  done



  # --- Run Tailscale setup via extension ---
  echo "Setting CustomScript extension for Tailscale..."
  CMD="echo '$TSKEY' > /tmp/tskey; curl -fsSL https://tailscale.com/install.sh | sh; tailscale up --authkey=\$(cat /tmp/tskey) --advertise-exit-node --accept-routes; rm -f /tmp/tskey"

  az vm extension set \
    --resource-group "$RG" \
    --vm-name "$HOSTNAME" \
    --name customScript \
    --publisher Microsoft.Azure.Extensions \
    --protected-settings "{\"commandToExecute\":\"$CMD\"}"

  echo "VM '$HOSTNAME' created and Tailscale setup initiated."

  # --- Verify Tailscale started ---
  echo "Waiting for Tailscale to start..."
  for i in $(seq 1 10); do
    STATUS=$(az vm run-command invoke \
      --resource-group "$RG" \
      --name "$HOSTNAME" \
      --command-id RunShellScript \
      --scripts "tailscale status" \
      --query "value[0].message" -o tsv 2>/dev/null)
    if [ -n "$STATUS" ]; then
      echo "Tailscale node is up:"
      echo "$STATUS"
      break
    fi
    echo "Tailscale not ready yet, retrying..."
    sleep 5
  done
}

# --- CLI parsing ---
if [ $# -lt 1 ]; then usage; fi

case "$1" in
  --list)
    if [ "$2" = "regions" ]; then list_regions
    elif [ "$2" = "vms" ]; then list_vms
    else usage
    fi
    ;;
  --build)
    shift
    HOSTNAME=""
    REGION=""
    SSH_KEY=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -h) HOSTNAME="$2"; shift 2 ;;
        -r) REGION="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    if [ -z "$HOSTNAME" ] || [ -z "$REGION" ]; then usage; fi
    build_vm "$HOSTNAME" "$REGION" "$SSH_KEY"
    ;;
  *)
    usage
    ;;
esac
