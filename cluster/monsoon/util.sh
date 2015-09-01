#!/bin/bash

# Copyright 2014 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Create a temp dir that'll be deleted at the end of this bash session.
#
# Vars set:
#   KUBE_TEMP
function ensure-temp-dir {
  if [[ -z ${KUBE_TEMP-} ]]; then
    KUBE_TEMP=$(TMPDIR=$CONFIG_ROOT/tmp mktemp -d -t kubernetes.XXXXXX)
    trap 'rm -rf "${KUBE_TEMP}"' EXIT
  fi
}

# A library of helper functions that each provider hosting Kubernetes must implement to use cluster/kube-*.sh scripts.
KUBE_ROOT=$(dirname "${BASH_SOURCE}")/../..
CONFIG_ROOT=${CONFIG_ROOT:-/Users/d038720/Code/monsoon/monsoon-kube}
ensure-temp-dir
source "${KUBE_ROOT}/cluster/monsoon/${KUBE_CONFIG_FILE-"config-default.sh"}"
source "${KUBE_ROOT}/cluster/common.sh"

# Must ensure that the following ENV vars are set
function detect-master {
	echo "KUBE_MASTER_IP: $KUBE_MASTER_IP"
	echo "KUBE_MASTER: $KUBE_MASTER"
}

# Get minion names if they are not static.
function detect-minion-names {
  echo "MINION_NAMES: ${MINION_NAMES[*]}"
}

# Get minion IP addresses and store in KUBE_MINION_IP_ADDRESSES[]
function detect-minions {
	echo "KUBE_MINION_IP_ADDRESSES=[]"
}

# Verify prereqs on host machine
function verify-prereqs {
  if ! $AWS_CMD ec2 describe-instances > /dev/null ; then
    echo "You need to have a working AWS CLI, please fix and retry."
    exit 1
  fi

  if ! $JQ_CMD --version ; then
    echo "You need to have the jq tool installed, please fix and retry."
    exit 1
  fi
}


# Instantiate a kubernetes cluster
function kube-up {
  get-tokens
  start-master
  start-minions
}

# Delete a kubernetes cluster
function kube-down {
	echo "TODO"
}

# Update a kubernetes cluster
function kube-push {
	echo "TODO"
}

# Prepare update a kubernetes component
function prepare-push {
	echo "TODO"
}

# Update a kubernetes master
function push-master {
	echo "TODO"
}

# Update a kubernetes node
function push-node {
	echo "TODO"
}

# Execute prior to running tests to build a release if required for env
function test-build-release {
	echo "TODO"
}

# Execute prior to running tests to initialize required structure
function test-setup {
	echo "TODO"
}

# Execute after running tests to perform any required clean-up
function test-teardown {
	echo "TODO"
}

# Set the {KUBE_USER} and {KUBE_PASSWORD} environment values required to interact with provider
function get-password {
	echo "TODO"
}


######################################## Helpers

function get-tokens() {
  KUBELET_TOKEN=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)
  KUBE_PROXY_TOKEN=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)
}

function start-master() {
  echo "Starting Master"
  
  ( 
    export TIER
    export REGION
    export DOMAIN
    export KUBERNETES_VERSION 
    source $CONFIG_ROOT/cloud-config/config/default
    erb $CONFIG_ROOT/cloud-config/templates/master.yaml.erb
  ) > "${KUBE_TEMP}/master.yaml"

  MASTER_ID=$(
    $AWS_CMD ec2 run-instances \
      --image-id $IMAGE_ID \
      --instance-type $MASTER_SIZE \
      --block-device-mappings "[{\"DeviceName\":\"/dev/sdb\",\"Ebs\":{\"VolumeSize\":${MASTER_VOLUME_ETCD_SIZE}}}]" \
      --user-data file:/$KUBE_TEMP/master.yaml | jq -r ".Instances[] .InstanceId"
  ) 

  echo "Tagging $MASTER_ID as $MASTER_NAME"
  $AWS_CMD ec2 create-tags --resources $MASTER_ID --tags Key=name,Value=$MASTER_NAME

  echo "Waiting for $MASTER_ID to be ready"
  wait-for-instance-running $MASTER_ID

  KUBE_MASTER=${MASTER_NAME}
  KUBE_MASTER_IP=$(get_instance_public_ip $MASTER_ID)
  KUBE_SERVER="http://${KUBE_MASTER_IP}:8080"

  echo "Waiting for cluster initialization."
  echo
  echo "  This will continually check to see if the API for kubernetes is reachable."
  echo "  This might loop forever if there was some uncaught error during start"
  echo "  up."
  echo

  until (curl --noproxy ${KUBE_MASTER_IP} --max-time 5 --fail --silent ${KUBE_SERVER}/healthz); do
    printf "."
    sleep 2
  done
  echo
}

function start-minions() {
  ( 
    export TIER
    export REGION
    export DOMAIN
    export KUBERNETES_VERSION 
    source $CONFIG_ROOT/cloud-config/config/default
    erb $CONFIG_ROOT/cloud-config/templates/node.yaml.erb
  ) > "${KUBE_TEMP}/node.yaml"

  MINION_IDS=()
  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    echo "Starting Minion (${MINION_NAMES[$i]})"

    minion_id=$(
      $AWS_CMD ec2 run-instances \
        --image-id $IMAGE_ID \
        --instance-type $MINION_SIZE \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sdb\",\"Ebs\":{\"VolumeSize\":${MINION_VOLUME_DOCKER_SIZE}}}]" \
        --user-data file:/$KUBE_TEMP/node.yaml | jq -r ".Instances[] .InstanceId"
    )

    echo "Tagging $minion_id as ${MINION_NAMES[$i]}"
    $AWS_CMD ec2 create-tags --resources $minion_id --tags Key=name,Value=${MINION_NAMES[$i]}

    MINION_IDS[$i]=$minion_id
  done
}

function get_instance_public_ip {
  local id=$1
  $AWS_CMD ec2 describe-instances --instance-ids $id | jq -r ".Reservations[] .Instances[] .PublicIpAddress"
}

# Wait for instance to be in running state
function wait-for-instance-running {
  instance_id=$1
  while true; do
    instance_state=$($AWS_CMD ec2 describe-instances --instance-ids ${instance_id} | jq -r ".Reservations[] .Instances[] .State .Name")
    if [[ "$instance_state" == "running" ]]; then
      break
    else
      printf "."
      sleep 2
    fi
  done
  echo
}
