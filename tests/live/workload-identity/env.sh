#!/usr/bin/env bash
# Shared settings for run.sh and edge-cases.sh. Source this file; do not run it.
# shellcheck shell=bash

if [ -f "$HERE/../.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$HERE/../.env"
  set +a
fi

: "${TF_VAR_node_ip:?Set TF_VAR_node_ip in tests/live/.env}"
: "${TF_VAR_object_storage_id:?Set TF_VAR_object_storage_id in tests/live/.env}"
: "${TF_VAR_talos_schematic_id:?Set TF_VAR_talos_schematic_id in tests/live/.env}"

export TF_DATA_DIR="${TF_DATA_DIR:-$HOME/.cache/terraform-contabo-kubernetes/wi-live}"
export TF_IN_AUTOMATION=1
WORK="$TF_DATA_DIR/work"
export TF_VAR_work_dir="$WORK"
# The state must not live at $TF_DATA_DIR/terraform.tfstate, because Terraform
# keeps its backend settings in that file.
# shellcheck disable=SC2034 # run.sh uses STATE_FILE.
STATE_FILE="$WORK/terraform.tfstate"
mkdir -p "$WORK/extra-patches"

# Extra control plane patches, for example from tests/live/examples/run.sh.
# Every script that plans or applies must pass the same list. Otherwise the
# plan removes the patches from the cluster.
TF_VAR_extra_control_plane_patch_files=$(find "$WORK/extra-patches" -name "*.yaml" | sort | jq -R . | jq -sc .)
export TF_VAR_extra_control_plane_patch_files
