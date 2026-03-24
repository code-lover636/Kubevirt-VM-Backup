# KubeVirt VM Backup

A Kubernetes CRD and controller that automates **Velero file-system backups of PVCs attached to KubeVirt VMs — without stopping the VM**. The solution also saves the VM manifest and DataVolume (DV) manifests so the entire virtual machine, including its disks, can be fully restored in a different namespace or cluster.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [Option 1 — Raw YAML (single file)](#option-1--raw-yaml-single-file)
  - [Option 2 — Helm Chart](#option-2--helm-chart)
- [Step-by-Step Usage](#step-by-step-usage)
  - [1. Export VM and DataVolume Manifests](#1-export-vm-and-datavolume-manifests)
  - [2. Create a VMPVCBackup CR](#2-create-a-vmpvcbackup-cr)
  - [3. Monitor Backup Progress](#3-monitor-backup-progress)
  - [4. Restore to a New Namespace / Cluster](#4-restore-to-a-new-namespace--cluster)
- [Example CR Files](#example-cr-files)
  - [VMPVCBackup CR](#vmpvcbackup-cr)
  - [Source Resources (DataVolumes + VM)](#source-resources-datavolumes--vm)
  - [Destination Resources (DataVolumes cloning restored PVCs + VM)](#destination-resources-datavolumes-cloning-restored-pvcs--vm)
- [vmpvcbackup.yaml — Detailed Explanation](#vmpvcbackupyaml--detailed-explanation)
  - [Section 1 — CRD](#section-1--crd)
  - [Section 2 — RBAC](#section-2--rbac)
  - [Section 3 — Controller Script (ConfigMap)](#section-3--controller-script-configmap)
  - [Section 4 — Controller Deployment](#section-4--controller-deployment)
- [CR Spec Reference](#cr-spec-reference)
- [CR Status Reference](#cr-status-reference)

---

## How It Works

```
User creates VMPVCBackup CR
          │
          ▼
Controller detects CR  (polls every 20 s)
          │
          ▼
Reader Pod created — mounts every PVC listed in spec.pvcs
  • Linux:   ubuntu:22.04   → /data1, /data2, …
  • Windows: Windows Server → C:/data1, C:/data2, …
          │
          ▼
Controller waits for Reader Pod to reach Running state
          │
          ▼
Velero Backup triggered
  • Scope: pods + PVCs + PVs in the VM namespace (label-scoped to reader pod)
  • File-system backup (no CSI snapshots required)
          │
          ▼
Backup completes → Reader Pod deleted → CR status = Completed
```

In addition to the PVC data, the operator pattern requires you to separately export the **VM manifest** and **DataVolume (DV) manifests** before the backup. When restoring in a new namespace, the DV manifests are adjusted so that each DataVolume clones its data **from the already-restored PVC** (using `source.pvc`) rather than re-downloading or re-creating it from scratch.

---

## Prerequisites

| Component | Version |
|-----------|---------|
| Kubernetes | ≥ 1.24 |
| KubeVirt | ≥ 0.57 |
| CDI (Containerized Data Importer) | ≥ 1.56 |
| Velero | ≥ 1.12, installed in the `velero` namespace |
| Velero file-system backup plugin | enabled (`--use-node-agent`) |
| `kubectl` | configured with cluster-admin access |
| Helm | ≥ 3.10 *(only if using the Helm install path)* |

---

## Installation

### Option 1 — Raw YAML (single file)

Apply the entire stack (CRD + RBAC + ConfigMap + Deployment) with one command:

```bash
kubectl apply -f https://raw.githubusercontent.com/code-lover636/Kubevirt-VM-Backup/main/vmpvcbackup.yaml
```

Or from a local clone:

```bash
git clone https://github.com/code-lover636/Kubevirt-VM-Backup.git
cd Kubevirt-VM-Backup
kubectl apply -f vmpvcbackup.yaml
```

Verify the controller is running:

```bash
kubectl get deployment vmb -n velero
kubectl get pods -n velero -l app=vmb
```

Expected output:

```
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
vmb    1/1     1            1           30s
```

### Option 2 — Helm Chart

```bash
git clone https://github.com/code-lover636/Kubevirt-VM-Backup.git
cd Kubevirt-VM-Backup

# Install with defaults (Velero namespace = velero)
helm install kubevirt-vm-backup ./manifest

# Install with custom values
helm install kubevirt-vm-backup ./manifest \
  --set namespace=velero \
  --set controller.pollInterval=30 \
  --set controller.podReadyTimeout=180
```

Upgrade an existing release:

```bash
helm upgrade kubevirt-vm-backup ./manifest
```

Uninstall:

```bash
helm uninstall kubevirt-vm-backup
kubectl delete crd vmpvcbackups.backup.kubevirt.io
```

---

## Step-by-Step Usage

### 1. Export VM and DataVolume Manifests

Before triggering the backup, export and save the VM and DV manifests. These are stored alongside (or separately from) the Velero backup and are needed during restore.

```bash
# Set your VM namespace
VM_NS="my-vm-namespace"
VM_NAME="my-vm"

# Export the VirtualMachine manifest (strip runtime status)
kubectl get vm "$VM_NAME" -n "$VM_NS" -o yaml \
  | kubectl neat > vm-manifest.yaml

# Export each DataVolume manifest
for dv in $(kubectl get dv -n "$VM_NS" -o jsonpath='{.items[*].metadata.name}'); do
  kubectl get dv "$dv" -n "$VM_NS" -o yaml \
    | kubectl neat > "dv-${dv}.yaml"
done
```

> **Note:** [`kubectl neat`](https://github.com/itaysk/kubectl-neat) removes cluster-managed fields (resourceVersion, uid, etc.). Install it with `kubectl krew install neat`.

Store these YAML files in a version-controlled repository or an object-storage bucket alongside the Velero backup.

---

### 2. Create a VMPVCBackup CR

Create a file named `my-backup.yaml`:

```yaml
apiVersion: backup.kubevirt.io/v1alpha1
kind: VMPVCBackup
metadata:
  name: my-vm-backup
  namespace: my-vm-namespace
spec:
  pvcs:
    - ubuntu-j-dv           # root disk PVC
    - ubuntu-j-datadisk-1   # data disk 1
    - ubuntu-j-datadisk-2   # data disk 2
  backupName: my-vm-backup-20240101
  osType: linux             # linux (default) or windows
```

Apply it:

```bash
kubectl apply -f my-backup.yaml
```

---

### 3. Monitor Backup Progress

```bash
# Short status view (uses additionalPrinterColumns)
kubectl get vmpb -n my-vm-namespace

# Detailed status
kubectl describe vmpvcbackup my-vm-backup -n my-vm-namespace

# Watch the reader pod
kubectl get pods -n my-vm-namespace -l app=vmpvcbackup-reader -w

# Watch the Velero backup
kubectl get backup my-vm-backup-20240101 -n velero -w

# Controller logs
kubectl logs -n velero -l app=vmb -f
```

The CR `.status.phase` transitions through the following states:

| Phase | Meaning |
|-------|---------|
| `Pending` | CR created, not yet processed |
| `CreatingPod` | Controller is creating the reader pod |
| `WaitingForPod` | Waiting for reader pod to reach `Running` |
| `BackingUp` | Velero backup has been triggered |
| `Completed` | Velero backup finished; reader pod deleted |
| `Failed` | An error occurred; check `.status.message` |

---

### 4. Restore to a New Namespace / Cluster

#### 4a. Restore the PVC data with Velero

```bash
velero restore create my-vm-restore \
  --from-backup my-vm-backup-20240101 \
  --namespace-mappings "my-vm-namespace:destination-namespace"
```

Wait for the restore to finish:

```bash
velero restore describe my-vm-restore --details
kubectl get pvc -n destination-namespace
```

#### 4b. Apply DataVolume manifests (clone from restored PVCs)

At the destination the DV manifests must use `source.pvc` so CDI clones the data from the already-restored PVCs rather than re-importing from the original URL. Update each DV manifest:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-j-dv
  namespace: destination-namespace
spec:
  source:
    pvc:
      namespace: destination-namespace   # namespace where Velero restored the PVC
      name: ubuntu-j-dv                  # name of the restored PVC
  storage:
    accessModes:
      - ReadWriteMany
    resources:
      requests:
        storage: 21Gi
```

Apply all destination DV manifests:

```bash
kubectl apply -f destination-resources.yml
```

Wait for all DataVolumes to reach `Succeeded`:

```bash
kubectl get dv -n destination-namespace -w
```

#### 4c. Apply the VM manifest

```bash
# Update the namespace field inside the manifest, then apply
sed 's/namespace: my-vm-namespace/namespace: destination-namespace/' vm-manifest.yaml \
  | kubectl apply -f -
```

Start the VM:

```bash
virtctl start my-vm -n destination-namespace
```

---

## Example CR Files

### VMPVCBackup CR

```yaml
apiVersion: backup.kubevirt.io/v1alpha1
kind: VMPVCBackup
metadata:
  name: ubuntu-j-backup
  namespace: j-vms-2
spec:
  pvcs:
    - ubuntu-j-dv
    - ubuntu-j-datadisk-1
    - ubuntu-j-datadisk-2
  backupName: ubuntu-j-backup-20240101
  veleroNamespace: velero   # optional, defaults to "velero"
  osType: linux             # optional, defaults to "linux"
```

### Source Resources (DataVolumes + VM)

These are the resources running in the **source namespace** (`j-vms-2`).  
See [`examples/source-resources.yml`](examples/source-resources.yml) for the full file.

```yaml
# Root disk DataVolume — created from upstream cloud image
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-j-dv
  namespace: j-vms-2
spec:
  source:
    http:
      url: https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
  pvc:
    accessModes:
      - ReadWriteOnce
    storageClassName: rook-ceph-block
    resources:
      requests:
        storage: 20Gi
---
# Data disk 1 — blank disk
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-j-datadisk-1
  namespace: j-vms-2
spec:
  source:
    blank: {}
  pvc:
    accessModes:
      - ReadWriteOnce
    storageClassName: rook-ceph-block
    resources:
      requests:
        storage: 10Gi
---
# VirtualMachine
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ubuntu-j-vm
  namespace: j-vms-2
spec:
  running: true
  template:
    spec:
      domain:
        cpu:
          cores: 2
        devices:
          disks:
            - disk: { bus: virtio }
              cache: writethrough
              name: rootdisk
            - disk: { bus: virtio }
              name: datadisk-1
        resources:
          requests:
            memory: 4Gi
      volumes:
        - dataVolume:
            name: ubuntu-j-dv
          name: rootdisk
        - dataVolume:
            name: ubuntu-j-datadisk-1
          name: datadisk-1
```

### Destination Resources (DataVolumes cloning restored PVCs + VM)

These are the resources applied in the **destination namespace** (`j-vms-5`) after Velero has restored the raw PVCs.  
See [`examples/destination-resources.yml`](examples/destination-resources.yml) for the full file.

> **Key difference:** `spec.source.pvc` is used instead of `spec.source.http` or `spec.source.blank`. This tells CDI to clone the data from the PVC that Velero already restored, so no data is re-downloaded.

```yaml
# Root disk DataVolume — clones from the Velero-restored PVC
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-j-dv
  namespace: j-vms-5
spec:
  source:
    pvc:
      namespace: j-vms-5       # namespace where Velero restored the PVC
      name: ubuntu-j-dv        # name of the restored PVC
  storage:
    accessModes:
      - ReadWriteMany
    resources:
      requests:
        storage: 21Gi
---
# Data disk 1 — clones from the Velero-restored PVC
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-j-datadisk-1
  namespace: j-vms-5
spec:
  source:
    pvc:
      namespace: j-vms-5
      name: ubuntu-j-datadisk-1
  storage:
    accessModes:
      - ReadWriteMany
    resources:
      requests:
        storage: 21Gi
---
# VirtualMachine — initially stopped to allow DVs to complete
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ubuntu-j-vm
  namespace: j-vms-5
spec:
  running: false
  template:
    spec:
      domain:
        cpu:
          cores: 2
        devices:
          disks:
            - disk: { bus: virtio }
              cache: writethrough
              name: rootdisk
            - disk: { bus: virtio }
              name: datadisk-1
        resources:
          requests:
            memory: 4Gi
      volumes:
        - dataVolume:
            name: ubuntu-j-dv
          name: rootdisk
        - dataVolume:
            name: ubuntu-j-datadisk-1
          name: datadisk-1
```

---

## vmpvcbackup.yaml — Detailed Explanation

The single file `vmpvcbackup.yaml` contains four Kubernetes resource definitions separated by `---`.

### Section 1 — CRD

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: vmpvcbackups.backup.kubevirt.io
```

Registers the `VMPVCBackup` custom resource in the `backup.kubevirt.io` API group.

| Field | Value | Purpose |
|-------|-------|---------|
| `group` | `backup.kubevirt.io` | API group for the new resource |
| `kind` | `VMPVCBackup` | CamelCase name of the resource |
| `plural` / `singular` | `vmpvcbackups` / `vmpvcbackup` | URL paths and CLI names |
| `shortNames` | `vmpb` | Short alias for `kubectl get vmpb` |
| `scope` | `Namespaced` | One CR per namespace (not cluster-wide) |
| `version` | `v1alpha1` | API maturity level |

**Spec fields validated by OpenAPI schema:**

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `pvcs` | `[]string` | ✅ | — | List of PVC names to mount and back up |
| `backupName` | `string` | ✅ | — | Name given to the resulting Velero `Backup` object |
| `veleroNamespace` | `string` | | `velero` | Namespace where Velero is installed |
| `osType` | `linux` \| `windows` | | `linux` | Selects reader pod image and mount path style |

**Status fields written by the controller:**

| Field | Description |
|-------|-------------|
| `phase` | Current lifecycle phase of the backup operation |
| `readerPodName` | Name of the temporary reader pod created |
| `veleroBackupName` | Name of the Velero `Backup` object created |
| `message` | Human-readable description of the current state |

**`additionalPrinterColumns`** make `kubectl get vmpb` show Phase, Pod, Backup, and Age columns without needing `-o wide`.

---

### Section 2 — RBAC

Three resources grant the controller exactly the permissions it needs and nothing more.

```yaml
# ServiceAccount — identity used by the controller pod
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vmb
  namespace: velero
```

```yaml
# ClusterRole — defines allowed API operations
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vmb
rules:
  # Read VMPVCBackup CRs from any namespace
  - apiGroups: [backup.kubevirt.io]
    resources: [vmpvcbackups]
    verbs: [get, list, watch]
  # Write status sub-resource
  - apiGroups: [backup.kubevirt.io]
    resources: [vmpvcbackups/status]
    verbs: [update, patch]
  # Manage reader pods
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, create, delete, watch]
  # Create Velero Backup objects
  - apiGroups: [velero.io]
    resources: [backups]
    verbs: [get, list, create]
```

```yaml
# ClusterRoleBinding — binds the ClusterRole to the ServiceAccount
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vmb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: vmb
subjects:
  - kind: ServiceAccount
    name: vmb
    namespace: velero
```

A `ClusterRole` (rather than a namespaced `Role`) is required because the controller watches `VMPVCBackup` CRs and manages reader pods across **all** namespaces.

---

### Section 3 — Controller Script (ConfigMap)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vmb-script
  namespace: velero
data:
  controller.sh: |
    ...
```

Stores the entire controller logic as a Bash script. The Deployment mounts this ConfigMap and executes it. The script contains the following functions:

#### `patch_status(name, ns, phase, msg)`
Updates the `.status.phase` and `.status.message` fields of a `VMPVCBackup` CR using `kubectl patch --subresource=status`. Errors are suppressed (`|| true`) so a transient API failure does not kill the controller.

#### `build_backup_vols_annotation(pvcs…)`
Produces the value for the `backup.velero.io/backup-volumes` pod annotation, e.g. `disk1,disk2,disk3`. Velero uses this annotation to know which volume mounts to include in the file-system backup.

#### `build_volume_mounts(os_type, pvcs…)` and `build_volumes(pvcs…)`
Dynamically generate the `volumeMounts` and `volumes` YAML blocks for the reader pod. Each PVC is named `disk1`, `disk2`, … and mounted at `/data1`, `/data2`, … (Linux) or `C:/data1`, `C:/data2`, … (Windows).

#### `create_reader_pod(pod_name, ns, os_type, pvcs…)`
Applies a pod manifest via a here-doc to `kubectl apply -f -`. The pod:
- Uses `ubuntu:22.04` (Linux) or `mcr.microsoft.com/windows/servercore:ltsc2022` (Windows)
- Runs `sleep infinity` (Linux) or an equivalent PowerShell loop (Windows) to stay alive during the backup
- Is labelled `vmpvcbackup-cr: <pod_name>` so the Velero backup can select it
- Has `securityContext.privileged: true` on Linux so the block device is accessible

#### `wait_for_pod(pod_name, ns)`
Polls `kubectl get pod … -o jsonpath='{.status.phase}'` every 5 seconds. Returns success when the pod is `Running`, or failure if it reaches `Failed`/`Error` or if `POD_READY_TIMEOUT` (120 s by default) is exceeded.

#### `trigger_velero_backup(backup_name, ns, pod_name)`
Applies a `velero.io/v1 Backup` object that:
- Targets only the VM namespace (`includedNamespaces`)
- Includes only `pods`, `persistentvolumeclaims`, and `persistentvolumes`
- Selects resources by the label `vmpvcbackup-cr: <pod_name>` so only the reader pod and its PVCs are captured
- Uses `defaultVolumesToFsBackup: true` (file-system/restic backup) and disables CSI snapshots

#### `reconcile(name, ns)`
The main per-CR state machine:
1. Read `spec.pvcs`, `spec.osType`, and `spec.backupName` from the CR.
2. Skip if phase is already `Completed` or `Failed`.
3. Create the reader pod if it does not exist → patch phase to `CreatingPod`.
4. Wait for the reader pod to reach `Running` → patch phase to `WaitingForPod`.
5. Trigger the Velero backup if it does not exist → patch phase to `BackingUp`.
6. Check the Velero backup phase and, on `Completed`, delete the reader pod and patch phase to `Completed`; on `Failed`/`PartiallyFailed`, patch phase to `Failed`.

#### Main loop
```bash
while true; do
  # List all VMPVCBackup CRs across all namespaces
  kubectl get vmpvcbackups --all-namespaces …
  # Call reconcile() for each CR
  sleep $POLL_INTERVAL   # default: 20 seconds
done
```

The controller is **level-triggered**: every reconcile pass re-evaluates the full desired state, making it resilient to restarts and transient failures.

---

### Section 4 — Controller Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vmb
  namespace: velero
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vmb
  template:
    spec:
      serviceAccountName: vmb          # uses the RBAC ServiceAccount above
      containers:
        - name: controller
          image: bitnami/kubectl:latest # provides kubectl; no custom image needed
          command: ["/bin/bash", "/scripts/controller.sh"]
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: vmb-script
            defaultMode: 0755          # make controller.sh executable
```

| Design choice | Reason |
|---------------|--------|
| `bitnami/kubectl` image | Ships `kubectl` and `bash`; no custom image to build or maintain |
| `replicas: 1` | Single controller avoids concurrent reconcile races |
| ConfigMap-mounted script | Update logic without rebuilding any container image |
| `velero` namespace | Co-located with Velero so the controller can create `Backup` objects directly |

---

## CR Spec Reference

```yaml
spec:
  pvcs:                   # required — list of PVC names in the same namespace as the CR
    - my-root-disk
    - my-data-disk-1
  backupName: my-backup   # required — name for the Velero Backup object (must be unique)
  veleroNamespace: velero # optional — default: "velero"
  osType: linux           # optional — "linux" (default) or "windows"
```

---

## CR Status Reference

```yaml
status:
  phase: Completed               # Pending | CreatingPod | WaitingForPod | BackingUp | Completed | Failed
  readerPodName: reader-my-backup
  veleroBackupName: my-backup
  message: "Backup my-backup completed successfully"
```

Check status quickly:

```bash
kubectl get vmpb -n <namespace>
kubectl describe vmpvcbackup <name> -n <namespace>
```
