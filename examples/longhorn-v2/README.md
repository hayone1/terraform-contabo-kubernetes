# Longhorn with the V2 Data Engine

This example builds a cluster with one control plane node and three storage workers. The workers run the V2 Data Engine of [Longhorn](https://longhorn.io) next to the default engine. Use the example when your workloads need fast block storage, for example databases.

The V2 Data Engine uses SPDK, a storage engine that talks to the disk directly instead of through a file system. 
> **Warning:** Longhorn calls the V2 Data Engine a technical preview. A new Longhorn version can change or break the engine. Keep backups of v2 volumes, and keep data that you cannot lose on the default engine.

## What the example creates

- One control plane node and three workers. The control plane node runs no workloads.
- A disk layout on every worker with three parts. Talos keeps 50 GiB for itself (container images, logs and pod data). The V2 Data Engine gets a raw partition of `v2_size`, a part of the disk without a file system. The default engine of Longhorn gets the rest of the disk.
- 2 GiB of hugepages and the kernel modules of the V2 Data Engine on every worker. Hugepages are large blocks of memory that SPDK reserves for itself.
- Two storage classes. The storage class `longhorn` uses the default engine and stays the default storage class. The storage class `longhorn-v2` uses the V2 Data Engine.

## What you need

1. Everything that the [module README](../../README.md#what-you-need) lists.
2. Products for the workers with enough disk space. A VDS S (`V8`) has 180 GB: 50 GiB for Talos, 80 GiB for the V2 Data Engine and about 37 GiB for the default engine.

## Steps

1. Copy `terraform.tfvars.example` to `terraform.tfvars`, and set the products.
2. Run `terraform init` and `terraform apply`. The first apply takes 15 to 30 minutes.
3. Save the kubeconfig:

   ```bash
   terraform output -raw kubeconfig > kubeconfig
   export KUBECONFIG=$PWD/kubeconfig
   ```

4. Check that Longhorn found the raw partition on every worker. Every worker shows a disk of the type `block`:

   ```bash
   kubectl -n longhorn-system get nodes.longhorn.io -o custom-columns='NODE:.metadata.name,DISKS:.status.diskStatus.*.diskType'
   ```

5. Create a volume with the V2 Data Engine:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: fast-data
   spec:
     accessModes: ["ReadWriteOnce"]
     storageClassName: longhorn-v2
     resources:
       requests:
         storage: 10Gi
   ```

## Costs

The V2 Data Engine keeps 2 CPU cores of every worker busy, because SPDK asks the disk for new work all the time (polling) instead of waiting for a signal from the disk (an interrupt). A dedicated server (VDS) has its own cores. On a VPS, the cores are shared with other customers, so set `interrupt_mode = true` there. In interrupt mode, SPDK waits for work, which costs some speed. In the live test on a Cloud VPS 6, the engine used about 2 cores per node in the default mode and about 0.1 core in interrupt mode. Longhorn changes the interrupt mode only while no v2 volume is attached, so stop the pods with v2 volumes before you change `interrupt_mode`. The module warns during the plan when a storage node is not a VDS and interrupt mode is off.

## Known problems

- Talos creates the raw partition only with the first configuration of a node. To turn the V2 Data Engine on for a running cluster, install the workers again (raise their reinstall generation). A running node without the partition keeps working, but Longhorn has no V2 disk on that node. Longhorn still runs the engine there with its busy cores, so set the label `node.longhorn.io/disable-v2-data-engine=true` on such a node.
- Longhorn adds the disks of a node from the node annotation `node.longhorn.io/default-disks-config` only when the node has no Longhorn disks yet. A new installation through the module removes the old Longhorn node first, so the new node gets both disks.
- A volume of the V2 Data Engine needs as many workers with a V2 disk as it has replicas. The storage class `longhorn-v2` uses the replica count of the module, 3 by default.
