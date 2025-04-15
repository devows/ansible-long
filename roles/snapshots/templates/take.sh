#!/bin/bash
#

set -xeuo pipefail

BIN_PATH=$(cd "$(dirname "$0")"; pwd -P)

GCP_PROJECT={{ snapshots.gcp_project }}
GCP_SNAPSHOTS_SOURCE_DISK={{ snapshots.gcp_snapshots_source_disk }}
GCP_SNAPSHOTS_ZONE={{ snapshots.gcp_snapshots_zone }}
GCP_SNAPSHOTS_NAME={{ snapshots.gcp_snapshots_name }}
GCP_SNAPSHOTS_STORAGE_LOCATION={{ snapshots.gcp_snapshots_storage_location }}
GCP_DISK_SNAPSHOTS_NAME=disk-${GCP_SNAPSHOTS_NAME}

CHAIN_NAME={{ snapshots.chain_name }}
CHAIN_NODE_RPC={{ snapshots.chain_node_rpc }}
DATA_PATH={{ snapshots.data_path }}
MOUNTED_DEVICE={{ snapshots.mounted_device }}
WORK_SERVER={{ snapshots.work_server }}
SNAPSHOTS_WORKDIR={{ snapshots.snapshots_workdir }}
BUCKET_NAME={{ snapshots.bucket_name }}
GOMPLATE_VERSION={{ snapshots.gomplate_version }}

export SNAPSHOT_INDEX_TITLE="{{ snapshots.website_title }}"

GOMPLATE=${BIN_PATH}/gomplate

install_deps() {
  curl -L -o ${GOMPLATE} https://github.com/hairyhenderson/gomplate/releases/download/${GOMPLATE_VERSION}/gomplate_linux-amd64
  chmod +x ${GOMPLATE}
}

collect_chain_info() {
  export NODE_VERSION=$(curl -sSf -H "Content-Type: application/json" -d '{"id":1, "jsonrpc":"2.0", "method": "system_version"}' "$CHAIN_NODE_RPC" | jq -r '.result')
  export BLOCK_HASH=$(curl -sSf -H "Content-Type: application/json" -d '{"id":1, "jsonrpc":"2.0", "method": "chain_getFinalizedHead"}' "$CHAIN_NODE_RPC" | jq -r '.result')
  export BLOCK_HEIGHT=$(curl -sSf -H "Content-Type: application/json" -d "{\"id\":1, \"jsonrpc\":\"2.0\", \"method\": \"chain_getBlock\", \"params\":[\"${BLOCK_HASH}\"]}" "$CHAIN_NODE_RPC" | jq -r '.result.block.header.number' | xargs printf '%d')

  test -n "$NODE_VERSION"
  test -n "$BLOCK_HASH"
  test -n "$BLOCK_HEIGHT"
}

create_disk_snapshots() {
  gcloud compute snapshots create ${GCP_SNAPSHOTS_NAME} \
    --project=${GCP_PROJECT} \
    --source-disk=${GCP_SNAPSHOTS_SOURCE_DISK} \
    --source-disk-zone=${GCP_SNAPSHOTS_ZONE} \
    --storage-location=${GCP_SNAPSHOTS_STORAGE_LOCATION}
  sleep 10s
}

create_disk_from_snapshots() {
  gcloud compute disks create ${GCP_DISK_SNAPSHOTS_NAME} \
    --project=${GCP_PROJECT} \
    --type=pd-ssd \
    --zone=${GCP_SNAPSHOTS_ZONE} \
    --source-snapshot=projects/${GCP_PROJECT}/global/snapshots/${GCP_SNAPSHOTS_NAME}
  sleep 10s
}

attach_disk() {
  gcloud compute instances attach-disk \
    ${WORK_SERVER} \
    --project=${GCP_PROJECT} \
    --zone=${GCP_SNAPSHOTS_ZONE} \
    --disk=${GCP_DISK_SNAPSHOTS_NAME}
  sleep 10s
}

detach_disk() {
  gcloud compute instances detach-disk \
    ${WORK_SERVER} \
    --project=${GCP_PROJECT} \
    --zone=${GCP_SNAPSHOTS_ZONE} \
    --disk=${GCP_DISK_SNAPSHOTS_NAME}
}

delete_disk() {
  gcloud compute disks delete ${GCP_DISK_SNAPSHOTS_NAME} \
    --project=${GCP_PROJECT} \
    --zone=${GCP_SNAPSHOTS_ZONE} \
    --quiet
}

delete_snapshots() {
  gcloud compute snapshots delete ${GCP_SNAPSHOTS_NAME} \
    --project=${GCP_PROJECT} \
    --quiet
}

take_node_snapshots() {
  mkdir -p ${SNAPSHOTS_WORKDIR}
  mount -o discard,defaults ${MOUNTED_DEVICE} ${SNAPSHOTS_WORKDIR}
  cd ${SNAPSHOTS_WORKDIR}/${DATA_PATH}/
  rm -rf polkadot
  cd chains/${CHAIN_NAME}

  PKG_NAME=${CHAIN_NAME}-$BLOCK_HEIGHT.tar.zst
  tar -I pzstd -cf ${PKG_NAME} db

  gsutil \
    -h "x-goog-meta-node-version:$NODE_VERSION" \
    -h "x-goog-meta-block-hash:$BLOCK_HASH" \
    -h "x-goog-meta-block-height:$BLOCK_HEIGHT" \
    cp ${PKG_NAME} gs://${BUCKET_NAME}/

  sleep 20s

  cd ${BIN_PATH}

  cat ${BIN_PATH}/index.tpl.html | \
    ${BIN_PATH}/gomplate -d "data=https://storage.googleapis.com/storage/v1/b/${BUCKET_NAME}/o?delimiter=%2F" > \
    ${BIN_PATH}/index.html

  gsutil \
    cp ${BIN_PATH}/index.html gs://${BUCKET_NAME}/index.html

  umount ${SNAPSHOTS_WORKDIR}
  rm -rf ${SNAPSHOTS_WORKDIR}
}

clean_resource() {
  delete_snapshots || true
  umount ${SNAPSHOTS_WORKDIR} || true
  rm -rf ${SNAPSHOTS_WORKDIR} || true
  detach_disk || true
  delete_disk || true
}

main() {
  install_deps
  clean_resource
  collect_chain_info
  create_disk_snapshots
  create_disk_from_snapshots
  delete_snapshots
  attach_disk
  # take snapshots
  take_node_snapshots
  detach_disk
  delete_disk
}

main
