#!/usr/bin/env bash
# Starts Talos Linux from memory on a Contabo instance that runs a temporary
# Ubuntu system. The terraform-contabo-kubernetes module copies this script to
# the instance and runs it over SSH as root.
#
#   install-talos.sh <Image Factory address of the node>
#
# The address looks like https://factory.talos.dev/image/<schematic>/<version>.
# The script downloads the Talos kernel and initramfs of the schematic, loads
# them with kexec and starts Talos 5 seconds after the SSH session ends. Talos
# then runs from memory in maintenance mode and does not touch the disk. When
# the module sends the configuration, Talos installs itself on the disk
# (UnattendedInstallConfig) and restarts from the disk.
#
# Lessons from the live tests on Contabo (2026-11-07): an earlier version wrote
# the Talos disk image over the disk of the running Ubuntu system. The old
# kernel kept writing into the new partitions, and the old system crashed at
# random after the write, because its programs were gone from the disk.
set -euo pipefail

main() {
  local base=$1

  if ! command -v kexec >/dev/null 2>&1; then
    echo "Installing kexec-tools ..."
    # cloud-init and the automatic updates use apt during the first minutes.
    cloud-init status --wait >/dev/null 2>&1 || true
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
    apt-get -o DPkg::Lock::Timeout=600 update -qq >/dev/null
    apt-get -o DPkg::Lock::Timeout=600 install -y -qq kexec-tools >/dev/null
  fi

  local dir=/dev/shm/talos
  mkdir -p "$dir"
  echo "Downloading the Talos kernel and initramfs from $base ..."
  curl -fsSL --retry 5 --retry-delay 10 -o "$dir/vmlinuz" "$base/kernel-amd64"
  curl -fsSL --retry 5 --retry-delay 10 -o "$dir/initramfs.xz" "$base/initramfs-amd64.xz"
  local cmdline
  cmdline=$(curl -fsSL --retry 5 --retry-delay 10 "$base/cmdline-metal-amd64")
  # The kernel arguments of the schematic hold the network settings, because
  # Contabo has no DHCP.
  case " $cmdline" in
    *" ip="*) ;;
    *)
      echo "The kernel arguments of the schematic have no network settings (ip=): $cmdline" >&2
      exit 1
      ;;
  esac

  kexec -l "$dir/vmlinuz" --initrd="$dir/initramfs.xz" --command-line="$cmdline"
  # systemd starts Talos after the SSH session has ended, so Terraform gets a
  # clean exit status.
  systemd-run --quiet --on-active=5 --timer-property=AccuracySec=100ms /usr/bin/systemctl kexec
  echo "Talos starts from memory in about 5 seconds. Kernel arguments: $cmdline"
}

main "$@"
