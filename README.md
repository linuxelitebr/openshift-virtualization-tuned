# OpenShift Virtualization, Tuned: reproducible artifacts

Artifacts behind **Part 3 (Hugepages and Memory)** of the *OpenShift Virtualization, Tuned*
series on [Linux Elite](https://linuxelite.com.br). Reproduce both halves on your own
cluster: the **bill** hugepages charge up front, and the **4.7x payoff** they buy.

The benchmark is two identical Fedora VMs on one node, same vCPUs and guest size, differing
only in `spec.domain.memory.hugepages`. Each compiles a ~30-line C pointer-chase at boot
(it defeats the prefetcher, so every access pays the full translation cost) and runs it
inside the guest over the qemu-guest-agent.

## What's measured

On the nested vSphere lab from the article:

| memory backing            | ns / access | throughput      |
|---------------------------|-------------|-----------------|
| ordinary 4 KiB (baseline) | ~1014 ns    | ~1.0 M-access/s |
| **hugepage-backed (1 GiB)** | **~215 ns** | **~4.6 M-access/s** |

**4.7x faster**, and the win lives in the host's nested page tables (EPT), invisible from
inside the guest where `HugePages_Total` is `0`. Page size is second-order: 1 GiB (~215 ns)
and 2 MiB (~206 ns) tied within run-to-run noise.

> The absolute latencies carry a nested-lab tax, so your nanoseconds will differ. The
> **ratio** is the portable result. Run it and read your own.

## Layout

```
bench/pointer-chase.c             the microbenchmark (Sattolo cycle, dependent loads)
manifests/vm-baseline.yaml        6 GiB guest, ordinary 4 KiB pages
manifests/vm-hugepages-1gi.yaml   6 GiB guest, 1 GiB hugepages
manifests/vm-hugepages-2mi.yaml   6 GiB guest, 2 MiB hugepages
manifests/vm-1536Mi-1Gi.yaml      invalid on purpose (not a multiple of the page size)
manifests/vm-512Mi-1Gi.yaml       invalid on purpose (smaller than one page)
manifests/filler-pods.yaml        4 GiB filler pods, to show the reserved pool's cost
tools/guest-exec.py               run a command inside a VM via the qemu-guest-agent
```

Each VM manifest is self-contained: cloud-init installs `gcc` and compiles
`bench/pointer-chase.c` to `/usr/local/bin/pc` at boot.

## Prerequisites

- OpenShift Virtualization or upstream KubeVirt, reachable with `oc`/`kubectl`.
- A `vm-tuning-lab` namespace (or edit the `namespace:` field).
- A hugepage pool reserved on at least one node (see below). A VM requesting hugepages
  stays `Pending` until a node advertises the matching `hugepages-<size>` resource.

## Reserving the pool

Hugepages are reserved at boot via kernel args, so toggling the pool reboots the node. For
12 GiB of 1 GiB pages plus 6 GiB of 2 MiB pages:

```
default_hugepagesz=1G hugepagesz=1G hugepages=12 hugepagesz=2M hugepages=3072
```

On self-managed OpenShift these args go in a `MachineConfig` (or `Tuned`/`KubeletConfig`)
targeting the worker pool. On HyperShift they ride in a `ConfigMap` the **NodePool**
references on the management cluster; those are mirrored immutable, so swap the reference
rather than editing in place. Either way, applying it rolls and reboots the pool.

Confirm the pool before applying any VM:

```console
$ oc get node <node> -o jsonpath='1Gi={.status.allocatable.hugepages-1Gi} 2Mi={.status.allocatable.hugepages-2Mi}{"\n"}'
1Gi=12Gi 2Mi=6Gi
```

A hugepage VM (like a `dedicatedCpuPlacement` one) can only live-migrate to a node with the
matching free pages, and during a full-pool roll there usually is not one, so its
PodDisruptionBudget blocks the drain a reboot needs. Stop such VMs before a node change.

## Running the test

Apply a baseline and a hugepage VM on the same node (edit the `nodeSelector`), wait for
cloud-init to finish compiling, then run the chase inside each guest:

```console
$ oc apply -f manifests/vm-baseline.yaml
$ oc apply -f manifests/vm-hugepages-1gi.yaml
$ python3 tools/guest-exec.py "/usr/local/bin/pc" virt-launcher-vm-hugepages-1gi-xxxxx vm-tuning-lab_vm-hugepages-1gi
~215 ns/access
```

`guest-exec.py` takes the command, the running `virt-launcher` pod, and the libvirt domain
(`<namespace>_<vm-name>`). Run it a few times per VM and compare the median; swap in
`vm-hugepages-2mi.yaml` for the page-size comparison.

## The bill

Guest memory must be a whole multiple of the page size and at least one page. The webhook
rejects the rest on a server-side dry-run, before anything is created:

```console
$ oc apply --dry-run=server -f manifests/vm-1536Mi-1Gi.yaml
The request is invalid: ... '1536Mi' is not a multiple of the page size '1Gi'

$ oc apply --dry-run=server -f manifests/vm-512Mi-1Gi.yaml
The request is invalid: ... must be equal to or larger than page size '1Gi'
```

A reserved pool is gone whether a VM touches it or not, and a busy node cannot borrow it
back. Fill a node with ordinary memory and the bill shows up as failed scheduling:

```console
$ oc apply -f manifests/filler-pods.yaml
$ oc get pods -l app=filler -n vm-tuning-lab
   2 Running
  10 Pending
```

The ten `Pending` pods are rejected with `Insufficient memory` while the reserved hugepages
sit idle beside them. A plain hugepage VM is no better off: with no CPU/memory limits
matching their requests it lands in `Burstable` QoS, not `Guaranteed`, because the
`hugepages-<size>` request never enters the QoS calculation.

## Seeing the pool in use

`/proc/meminfo` reports only the default page size, which trips people up; read `/sys` for
the per-size truth, reserved and free:

```console
$ cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
12
$ cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages
6
```

From the Kubernetes side, the launcher pod requests `hugepages-<size>` equal to the guest
size, and the node's `allocatable.hugepages-<size>` shrinks by that while the VM runs.

## License

Provided as-is for educational use, no warranty.
