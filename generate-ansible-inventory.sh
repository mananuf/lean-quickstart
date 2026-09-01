#!/bin/bash
# Generate Ansible inventory from validator-config.yaml
# This script reads validator-config.yaml and generates hosts.yml for Ansible

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <validator-config.yaml> <output-hosts.yml>"
    exit 1
fi

VALIDATOR_CONFIG="$1"
OUTPUT_FILE="$2"

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    echo "Error: yq is required but not installed. Please install yq first."
    echo "On macOS: brew install yq"
    echo "On Linux: https://github.com/mikefarah/yq#install"
    exit 1
fi

# Check if validator config exists
if [ ! -f "$VALIDATOR_CONFIG" ]; then
    echo "Error: Validator config file not found: $VALIDATOR_CONFIG"
    exit 1
fi

# Create output directory if it doesn't exist
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
mkdir -p "$OUTPUT_DIR"

# Start generating the inventory file
cat > "$OUTPUT_FILE" << 'EOF'
---
# Ansible Inventory for Lean Quickstart
# Auto-generated from validator-config.yaml
# DO NOT EDIT MANUALLY - This file is auto-generated

all:
  children:
    local:
      hosts:
        localhost:
          ansible_connection: local
          ansible_python_interpreter: auto_silent
    bootnodes:
      hosts: {}
    zeam_nodes:
      hosts: {}
    ream_nodes:
      hosts: {}
    qlean_nodes:
      hosts: {}
    lantern_nodes:
      hosts: {}
    lighthouse_nodes:
      hosts: {}
    grandine_nodes:
      hosts: {}
    ethlambda_nodes:
      hosts: {}
EOF

# Extract node information from validator-config.yaml
nodes=($(yq eval '.validators[].name' "$VALIDATOR_CONFIG"))

# Process each node and generate inventory entries
for node_name in "${nodes[@]}"; do
    # Extract client type (zeam, ream, qlean, lantern, lighthouse, grandine, ethlambda)
    IFS='_' read -r -a elements <<< "$node_name"
    client_type="${elements[0]}"
    group_name="${client_type}_nodes"
    
    # Extract node-specific information
    node_ip=$(yq eval ".validators[] | select(.name == \"$node_name\") | .enrFields.ip // \"127.0.0.1\"" "$VALIDATOR_CONFIG")
    node_quic=$(yq eval ".validators[] | select(.name == \"$node_name\") | .enrFields.quic // \"9000\"" "$VALIDATOR_CONFIG")
    
# Addresses that belong to this machine. A node pinned to one of them runs on
# the controller itself, so ansible must connect locally: SSH-ing to your own
# address needs the host to trust its own key and otherwise fails with
# "Permission denied (publickey,password)". Covers single-host devnets reached
# by a routable/VPN address rather than 127.0.0.1.
# Override with LEAN_ANSIBLE_LOCAL_IPS="ip1 ip2" if detection misses one.
_local_ips=" 127.0.0.1 localhost ${LEAN_ANSIBLE_LOCAL_IPS:-} $(
    { hostname -I 2>/dev/null
      ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'
      ifconfig 2>/dev/null | awk '/inet /{print $2}'
    } | tr '\n' ' '
) "

is_local_ip() {
    case "$_local_ips" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

    # Check if this is a remote deployment (IP is not localhost/127.0.0.1)
    is_remote=false
    if ! is_local_ip "$node_ip"; then
        is_remote=true
    fi
    
    # Add node to the appropriate group
    if [ "$is_remote" = true ]; then
        # Remote deployment
        yq eval -i ".all.children.$group_name.hosts.$node_name.ansible_host = \"$node_ip\"" "$OUTPUT_FILE"
        yq eval -i ".all.children.$group_name.hosts.$node_name.node_name = \"$node_name\"" "$OUTPUT_FILE"
        yq eval -i ".all.children.$group_name.hosts.$node_name.client_type = \"$client_type\"" "$OUTPUT_FILE"
        yq eval -i ".all.children.$group_name.hosts.$node_name.quic_port = $node_quic" "$OUTPUT_FILE"
    else
        # Local deployment
        yq eval -i ".all.children.$group_name.hosts.$node_name.ansible_host = \"localhost\"" "$OUTPUT_FILE"
        yq eval -i ".all.children.$group_name.hosts.$node_name.ansible_connection = \"local\"" "$OUTPUT_FILE"
        yq eval -i ".all.children.$group_name.hosts.$node_name.node_name = \"$node_name\"" "$OUTPUT_FILE"
        yq eval -i ".all.children.$group_name.hosts.$node_name.client_type = \"$client_type\"" "$OUTPUT_FILE"
        yq eval -i ".all.children.$group_name.hosts.$node_name.quic_port = $node_quic" "$OUTPUT_FILE"
    fi
done

# One inventory host per remote IP for prepare.yml — avoids N parallel SSH/apt sessions
# to the same machine when validator-config lists zeam_0..zeam_4 on one IP.
PREPARE_FILE="${OUTPUT_DIR}/hosts-prepare.yml"
cat > "$PREPARE_FILE" << 'EOF'
---
# Deduplicated inventory for prepare.yml only (generated; do not edit manually).
all:
  children:
    prepare_hosts:
      hosts: {}
EOF

while IFS= read -r ip; do
    [ -z "$ip" ] || [ "$ip" = "null" ] && continue
    # Local addresses need no prepare pass: there is nothing to reach over SSH.
    if is_local_ip "$ip"; then
        continue
    fi
    inv_id="prep_${ip//./_}"
    yq eval -i ".all.children.prepare_hosts.hosts.\"$inv_id\".ansible_host = \"$ip\"" "$PREPARE_FILE"
done < <(yq eval '.validators[].enrFields.ip' "$VALIDATOR_CONFIG" | sort -u)

echo "✅ Generated Ansible inventory at: $OUTPUT_FILE"
echo "✅ Generated prepare inventory (one host per IP) at: $PREPARE_FILE"
echo "   Processed ${#nodes[@]} node(s): ${nodes[*]}"

