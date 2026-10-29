#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
parameters_file="${1:-$script_dir/main.parameters.json}"
deployment_name="${DEPLOYMENT_NAME:-cyclecloud-aks-$(date -u +%Y%m%d%H%M%S)}"
deployment_location="${DEPLOYMENT_LOCATION:-westus2}"
ssh_public_key_file="${AKS_SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"

if [[ ! -f "$parameters_file" ]]; then
  echo "Parameter file not found: $parameters_file" >&2
  exit 1
fi

if [[ -z "${AKS_SSH_PUBLIC_KEY:-}" ]]; then
  if [[ ! -f "$ssh_public_key_file" ]]; then
    echo "SSH public key not found: $ssh_public_key_file" >&2
    echo "Set AKS_SSH_PUBLIC_KEY or AKS_SSH_PUBLIC_KEY_FILE and try again." >&2
    exit 1
  fi

  AKS_SSH_PUBLIC_KEY="$(<"$ssh_public_key_file")"
fi

az account show --output none

az deployment sub validate \
  --name "$deployment_name" \
  --location "$deployment_location" \
  --template-file "$script_dir/main.bicep" \
  --parameters "$parameters_file" \
  --parameters sshPublicKey="$AKS_SSH_PUBLIC_KEY"

az deployment sub create \
  --name "$deployment_name" \
  --location "$deployment_location" \
  --template-file "$script_dir/main.bicep" \
  --parameters "$parameters_file" \
  --parameters sshPublicKey="$AKS_SSH_PUBLIC_KEY" \
  --only-show-errors
