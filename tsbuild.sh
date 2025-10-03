#!/usr/bin/env bash

# Simplified azure exit node builder
# Save as az-exitnode-simple.sh, chmod +x

RG="tsnode-rg"
VM_SIZE="Standard_B1ms"
IMAGE="UbuntuLTS"

usage() {
  echo "Usage:"
  echo "  $0 --list regions"
  echo "  $0 --list vms"
  echo "  $0 --build -h HOSTNAME -r REGION [--ssh-key /path/to/key.pub]"
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
  az vm list -o table
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

  echo "Creating resource group $RG in $REGION..."
  az group create --name "$RG" --location "$REGION" --output none

  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  CLOUD_INIT_FILE="$SCRIPT_DIR/cloud-init.yaml"

  if [ ! -f "$CLOUD_INIT_FILE" ]; then
    echo "cloud-init.yaml not found in script folder ($SCRIPT_DIR)"
    exit 1
  fi

  echo "Creating VM..."
  if [ -n "$SSH_KEY" ]; then
    az vm create \
      --resource-group "$RG" \
      --name "$HOSTNAME" \
      --image "$IMAGE" \
      --size "$VM_SIZE" \
      --admin-username tsuser \
      --ssh-key-values "$SSH_KEY" \
      --custom-data @"$CLOUD_INIT_FILE"
  else
    az vm create \
      --resource-group "$RG" \
      --name "$HOSTNAME" \
      --image "$IMAGE" \
      --size "$VM_SIZE" \
      --admin-username tsuser \
      --generate-ssh-keys \
      --custom-data @"$CLOUD_INIT_FILE"
  fi

  echo "Setting CustomScript extension for Tailscale..."
  CMD="echo '$TSKEY' > /tmp/tskey; curl -fsSL https://tailscale.com/install.sh | sh; tailscale up --authkey=\$(cat /tmp/tskey) --advertise-exit-node --accept-routes; rm -f /tmp/tskey"

  az vm extension set \
    --resource-group "$RG" \
    --vm-name "$HOSTNAME" \
    --name customScript \
    --publisher Microsoft.Azure.Extensions \
    --protected-settings "{\"commandToExecute\":\"$CMD\"}"

  echo "VM '$HOSTNAME' created and Tailscale setup initiated."
}

# Wait for Tailscale daemon and report status
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
