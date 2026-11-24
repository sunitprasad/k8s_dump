<div align="center">

# ☸ Kubernetes Backup Console

**A clean, keyboard-driven Kubernetes YAML backup utility — built entirely with Bash.**

Discover native resources and CRDs automatically · Export **one YAML per object** · Browse cluster resources · Monitor backup progress

<img width="79" height="20" alt="image" src="https://github.com/user-attachments/assets/54da745e-ae2f-4b42-8be1-1b2429db46e7" /> <img width="139" height="20" alt="image" src="https://github.com/user-attachments/assets/8cd74f31-f1bb-4620-9d4a-705f30857740" /> <img width="128" height="20" alt="image" src="https://github.com/user-attachments/assets/685eda26-897b-4a9d-9d05-dc026999e080" /> <img width="104" height="20" alt="image" src="https://github.com/user-attachments/assets/96242bae-de3d-4fd6-96fa-2356c7417dae" />




</div>


## Preview

### Cluster dashboard

View Kubernetes connectivity, selected context, kubeconfig, namespace/CRD counts, and output location.

<img width="1200" height="720" alt="image" src="https://github.com/user-attachments/assets/02038547-7872-46fd-9488-91bed3b43e91" />

### Resource browser

Navigate the API resource inventory using arrow keys or `j`/`k`. The inventory includes discovered API resources exposed by Kubernetes.

<img width="1200" height="720" alt="image" src="https://github.com/user-attachments/assets/5d53e681-cf3c-4769-849a-e00d21de69b5" />


### Backup progress and logs

Launch a backup from the TUI and inspect the latest output. Progress counts **completed API resource types**, while the engine saves **individual objects**.

<img width="1200" height="720" alt="image" src="https://github.com/user-attachments/assets/70f4856e-b39d-43b3-9c58-80d1a0f66f4d" />

## Highlights

- **Bash-only interface:** no Go, Python, Node.js, `dialog`, or `whiptail` required.
- **One YAML per object:** easy to browse, compare, inspect, and selectively prepare for restoration.
- **Automatic resource discovery:** lists available Kubernetes API resource types, including CRD definitions and custom-resource instances where accessible.
- **All namespaces plus cluster-scoped resources:** exports objects visible to the configured Kubernetes credentials.
- **Bring your own kubeconfig:** use the default `kubectl` configuration or supply a YAML file and context.
- **Interactive controls:** dashboard, resource browser, context picker, backup launcher, recent logs.
- **Verbose CLI backup engine:** per-object export messages, per-resource-type progress, logs, index, and summary.
- **Read-only Kubernetes actions:** the scripts do not change the configured current context or mutate cluster objects.

## Requirements

| Dependency | Purpose |
|---|---|
| Linux terminal with ANSI/alternate-screen support | Interactive TUI |
| Bash 4+ | Both scripts |
| `kubectl` | Kubernetes access and YAML exports |
| `tput` / terminfo | Terminal dimensions for the TUI |
| Standard utilities (`sort`, `wc`, `tail`, `sed`, `tr`, `date`, etc.) | Script operation |

`jq` is **not required**. Your Kubernetes account needs adequate read/list permissions for the resources you want to back up. Cluster-wide coverage typically requires broad RBAC access.

## Quick start

Keep both scripts in the same directory:

```text
k8s-backup-console/
├── README.md
├── k8s_backup_tui.sh
├── k8s_full_backup.sh
└── screenshots/
    ├── dashboard.png
    ├── resources.png
    └── backup.png
```

Make the scripts executable:

```bash
chmod +x k8s_backup_tui.sh k8s_full_backup.sh
```

### Option A — Interactive TUI (default kubeconfig)

```bash
./k8s_backup_tui.sh
```

Uses the normal `kubectl` configuration (including `KUBECONFIG`, when set). Default backup parent directory: `./k8s-backups`.

### Option B — Interactive TUI (specific kubeconfig YAML)

```bash
./k8s_backup_tui.sh --kubeconfig ./production.yaml
```

Choose a context and output folder when launching:

```bash
./k8s_backup_tui.sh \
  --kubeconfig ./production.yaml \
  --context production \
  --output ./my-backups
```

Or start the TUI normally and press **`f`** to enter the kubeconfig YAML path interactively. The path input is visible while you type.

### Option C — Direct CLI backup (no TUI)

```bash
./k8s_full_backup.sh
```

With explicit options:

```bash
./k8s_full_backup.sh \
  --kubeconfig ./production.yaml \
  --context production \
  --output ./my-backups \
  --timeout 120s
```

The CLI creates a new timestamped directory under the selected output parent. No arguments are required.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `1` | Dashboard |
| `2` | API resources |
| `3` or `c` | Kubernetes contexts |
| `4` | Backup / logs |
| `j`, `k`, `↑`, `↓` | Navigate lists |
| `Enter` | Select highlighted context when on the Contexts screen |
| `f` | Set or change kubeconfig YAML path |
| `o` | Set backup output parent directory |
| `b` | Start backup |
| `r` | Refresh cluster information |
| `l` | Display TUI session log path |
| `q` | Quit the TUI |

> **Tip:** Run the TUI in a terminal at least **77 columns × 22 rows**. A wider terminal gives the resource and log panels more room.

## Backup output

Every object is exported into its own YAML file. Cluster-scoped objects and namespaced objects have separate trees.

```text
k8s-backups/
└── production_20261124T054000Z/
    ├── namespaces/
    │   ├── default/
    │   │   ├── deployments.apps/
    │   │   │   ├── api.yaml
    │   │   │   └── frontend.yaml
    │   │   ├── services/
    │   │   │   └── backend-api.yaml
    │   │   └── secrets/
    │   │       └── app-config.yaml
    │   ├── monitoring/
    │   │   └── servicemonitors.monitoring.coreos.com/
    │   │       └── prometheus.yaml
    │   └── argocd/
    │       └── applications.argoproj.io/
    │           └── platform.yaml
    ├── cluster-scoped/
    │   ├── namespaces/
    │   │   └── default.yaml
    │   ├── nodes/
    │   │   └── worker-01.yaml
    │   └── customresourcedefinitions.apiextensions.k8s.io/
    │       └── applications.argoproj.io.yaml
    ├── metadata/
    │   ├── context.txt
    │   ├── index.tsv
    │   ├── summary.txt
    │   ├── crd-list.txt
    │   ├── cluster-resource-types.txt
    │   └── namespaced-resource-types.txt
    └── logs/
        ├── backup.log
        └── errors.log
```

The tree above is an **example**. Actual subdirectories and YAML names depend on the objects in your cluster.

### Backup records

| File | Contents |
|---|---|
| `metadata/index.tsv` | One row per attempted object export: scope, namespace, type, name, status, bytes, and file path |
| `metadata/summary.txt` | Export counts, failures, CRD count, elapsed time, and limitations |
| `metadata/crd-list.txt` | CRD inventory visible to your credentials |
| `logs/backup.log` | Verbose execution messages |
| `logs/errors.log` | API discovery/list/export errors and warnings |

## What is backed up?

| Included when discoverable and permitted | Excluded |
|---|---|
| Deployments, StatefulSets, DaemonSets, Pods, Jobs, CronJobs | PVC **contents** (disk data) |
| Services, Ingresses, NetworkPolicies | etcd database snapshots |
| ConfigMaps and Secrets | Files stored only on individual nodes |
| PVC **API objects**, PVs, StorageClasses | External databases, S3/MinIO bucket content, external services |
| Namespaces, RBAC, ServiceAccounts | Resources the identity cannot discover, list, or read |
| CRD definitions and custom-resource instances | A verified, directly restorable disaster-recovery snapshot |

The engine queries listable resource types with `kubectl api-resources`, lists individual objects, then runs `kubectl get <type> <name> -o yaml` to save **one object per file**. Some virtual or ephemeral API endpoints can fail or be inappropriate for restoration; consult the logs and index.

## How progress works

- CLI progress increments after each **resource type** finishes processing, whether successful or failed.
- Individual objects are logged as they are exported.
- TUI progress is derived from the CLI backup log.
- A resource type containing many objects can take much longer than a small resource type. Progress is **not** a measure of bytes transferred or individual objects completed.
- On completed runs, check `metadata/summary.txt` and `metadata/index.tsv`; a displayed 100% does **not** necessarily mean a successful, complete backup.

## Security and operational notes

> [!CAUTION]
> **Exported Secrets may contain live credentials.** Treat the output folder as sensitive, restrict access, encrypt it at rest, and do not commit backups to Git or upload them to public repositories.

- The backup process is **read-only against the cluster**. It does not delete, patch, or apply objects.
- Explicit kubeconfig/context flags are passed to `kubectl` rather than updating your default context.
- The backup engine exits nonzero when export failures or tracked discovery/metadata warnings occur. Verify the generated summary and error log.
- Kubernetes YAML exports include server-managed fields such as `status`, UIDs, and resource versions. **Do not blindly `kubectl apply` the entire backup**. Restoration requires normalization, dependency ordering, and environment-specific validation.
- Permissions, API availability, resource changes during export, and Kubernetes API pagination can affect coverage or consistency. This is **not an atomic snapshot**.
- The engine does **not** copy your kubeconfig into the backup directory.
- Quitting the TUI does not intentionally cancel an already-started backup process; use the generated logs and directories to verify the result.

## Troubleshooting

**The TUI cannot connect to the cluster.** Check `kubectl --kubeconfig ./production.yaml get namespaces`, context selection, VPN/network access, certificate validity, and RBAC.

**The terminal seems too small.** Resize to at least 77 × 22 and run again.

**The kubeconfig file is not accepted.** Check that the file exists, is readable, and is an actual Kubernetes kubeconfig (not a Deployment/Service resource YAML). Alternatively launch with `--kubeconfig /absolute/path/to/file.yaml`.

**Some resources fail.** Review `logs/errors.log`, `metadata/index.tsv`, and `metadata/summary.txt`. Missing permissions or unavailable API groups are common causes.

**The progress bar pauses for a while.** A single resource type may contain many objects, and each object is retrieved separately. This is expected.

**I want a full disaster recovery backup.** Combine this YAML inventory with application-consistent database backups, CSI volume snapshots or volume backups, and any required etcd backup strategy.

## Current limitations / roadmap

This is an early, Bash-only TUI—not a complete k9s replacement. Potential future improvements include search/filter, sortable resources, namespace filters, backup history, object-level progress, resumable exports, manifest verification, and a safe selective-restore workflow.

---

<div align="center"><sub>Designed for practical Kubernetes configuration inventory and backup. Validate results before relying on them for recovery.</sub></div>
