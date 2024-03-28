#!/bin/bash
set -e

# Setup some vars for use later on
# The private key used to send transactions
private_key="0903a9a721167e2abaa0a33553cbeb209dc9300d28e4e4d6d2fac2452f93e357"
# The destination network (zero corresponds to L1/Ethereum)
destination_net="0"
# The address of the recipient
destination_addr="0x85dA99c8a7C2C95964c8EfD687E95E632Fc533D6"
# The bridge address
bridge_addr="$(kurtosis service exec cdk-v1 contracts-001 "cat /opt/zkevm/combined.json" | tail -n +2 | jq -r .polygonZkEVMBridgeAddress)"

# Grab the endpoints for l1 and the bridge service
l1_rpc_url=http://$(kurtosis port print cdk-v1 el-1-geth-lighthouse rpc)
bridge_api_url="$(kurtosis port print cdk-v1 zkevm-bridge-service-001 bridge-rpc)"

# The signature for claiming is long - just putting it into a var
claim_sig="claimAsset(bytes32[32],bytes32[32],uint256,bytes32,bytes32,uint32,address,uint32,address,uint256,bytes)"

# Get the list of deposits for the destination address
echo "Getting the list of deposits..."
curl -s "$bridge_api_url/bridges/$destination_addr?limit=100&offset=0" | jq > bridge-deposits.json
cat bridge-deposits.json

# Filter the list of deposits down to the first claimable tx that hasn't already been claimed and is destined for L1
echo "Filtering the list of deposits..."
jq '[.deposits[] | select(.ready_for_claim == true and .claim_tx_hash == "" and .dest_net == '$destination_net')] | .[0]' bridge-deposits.json > claimable-tx.json
cat claimable-tx.json
if [ "$(<claimable-tx.json)" = "null" ]; then
  echo "No deposits found..."
  exit 1
fi

# Use the bridge service to get the merkle proof of our deposit
echo "Getting the merkle proof of our deposit..."
curr_deposit_cnt="$(jq -r '.deposit_cnt' claimable-tx.json)"
curr_network_id="$(jq -r '.network_id' claimable-tx.json)"
curl -s "$bridge_api_url/merkle-proof?deposit_cnt=$curr_deposit_cnt&net_id=$curr_network_id" | jq '.' > proof.json
cat proof.json

# Get our variables organized
in_merkle_proof="$(jq -r -c '.proof.merkle_proof' proof.json | tr -d '"')"
in_rollup_merkle_proof="$(jq -r -c '.proof.rollup_merkle_proof' proof.json | tr -d '"')"
in_global_index="$(jq -r '.global_index' claimable-tx.json)"
in_main_exit_root="$(jq -r '.proof.main_exit_root' proof.json)"
in_rollup_exit_root="$(jq -r '.proof.rollup_exit_root' proof.json)"
in_orig_net="$(jq -r '.orig_net' claimable-tx.json)"
in_orig_addr="$(jq -r '.orig_addr' claimable-tx.json)"
in_dest_net="$(jq -r '.dest_net' claimable-tx.json)"
in_dest_addr="$(jq -r '.dest_addr' claimable-tx.json)"
in_amount="$(jq -r '.amount' claimable-tx.json)"
in_metadata="$(jq -r '.metadata' claimable-tx.json)"

# Generate the call data, this is useful just to examine what the call will look loke
echo "Generating the call data for the bridge claim tx..."
cast calldata "$claim_sig" "$in_merkle_proof" "$in_rollup_merkle_proof" "$in_global_index" "$in_main_exit_root" "$in_rollup_exit_root" "$in_orig_net" "$in_orig_addr" "$in_dest_net" "$in_dest_addr" "$in_amount" "$in_metadata"

# Perform an eth_call to make sure the tx will work
echo "Performing an eth call to make sure the bridge claim tx will work..."
cast call --rpc-url "$l1_rpc_url" "$bridge_addr" "$claim_sig" "$in_merkle_proof" "$in_rollup_merkle_proof" "$in_global_index" "$in_main_exit_root" "$in_rollup_exit_root" "$in_orig_net" "$in_orig_addr" "$in_dest_net" "$in_dest_addr" "$in_amount" "$in_metadata"

# Publish the actual transaction!
echo "Publishing the bridge claim tx..."
cast send --rpc-url "$l1_rpc_url" --private-key "$private_key" "$bridge_addr" "$claim_sig" "$in_merkle_proof" "$in_rollup_merkle_proof" "$in_global_index" "$in_main_exit_root" "$in_rollup_exit_root" "$in_orig_net" "$in_orig_addr" "$in_dest_net" "$in_dest_addr" "$in_amount" "$in_metadata"
