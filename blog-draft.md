# Closing the runtime security gap between RHACS and Kata Containers

Security teams adopting Kata Containers for workload isolation face a paradox.
The stronger the isolation boundary, the harder it becomes to observe what
happens inside. Red Hat Advanced Cluster Security for Kubernetes (RHACS)
monitors container workloads through eBPF probes attached to the host kernel.
Kata Containers run each pod inside a virtual machine with its own kernel. The
probes cannot cross that boundary, leaving Kata workloads invisible to RHACS
runtime monitoring.

This post shows how to close that gap by running the RHACS Collector inside the
Kata guest VM, with no changes to the guest kernel, QEMU configuration, or
kata-agent.

## How RHACS monitors container runtime activity

RHACS deploys a Collector component as a DaemonSet on every cluster node. The
Collector uses CO-RE BPF (Compile Once, Run Everywhere) programs that attach to
kernel tracepoints. These programs fire whenever a process executes, a network
connection opens, or a file is accessed. The Collector forwards these events to
the RHACS Sensor, which aggregates them and sends them to Central for policy
evaluation, alerting, and forensic analysis.

<!-- diagram: RHACS architecture showing Collector on host kernel,
     Sensor per cluster, Central as management plane -->

This design assumes that every container shares the host kernel. Standard
containers satisfy this assumption. Their processes run directly on the host,
and every syscall passes through the host kernel where the eBPF probes are
waiting.

## Where Kata Containers break the assumption

Kata Containers replace the shared-kernel model with hardware virtualization.
Each pod runs inside a lightweight QEMU virtual machine with a dedicated guest
kernel. The container's syscalls go to the guest kernel, not to the host. The
host kernel sees the QEMU process but has no visibility into what happens
inside the VM.

<!-- diagram: side-by-side showing runc container (syscalls go to host kernel,
     eBPF probes see them) vs Kata VM (syscalls go to guest kernel,
     host eBPF probes see nothing) -->

To measure the impact, we deployed two identical pods on an OpenShift 4.21
cluster running RHACS 4.11. Both pods ran the same commands in a loop:
`whoami`, `id`, `curl`, and `sleep`.

| Pod runtime | Process events captured by RHACS |
|-------------|--------------------------------|
| runc        | 30,000+ (every invocation)     |
| Kata        | 0                              |

The Collector was working correctly. It was monitoring the host kernel as
designed. The guest kernel was simply outside its reach.

## Moving the Collector inside the guest

The RHACS Collector does not depend on running at the host level. At startup,
it loads CO-RE BPF programs against whatever kernel it finds, reads BTF
(BPF Type Format) metadata to adapt to the kernel's data structures, and
attaches to tracepoints. If those tracepoints belong to the guest kernel, the
Collector monitors the guest.

The RHEL 9 guest kernel that ships with OpenShift sandboxed containers already
includes everything the Collector needs:

- BPF subsystem support (`CONFIG_BPF_SYSCALL`, `CONFIG_BPF_JIT`)
- BTF type information at `/sys/kernel/btf/vmlinux`
- Raw syscall tracepoints at `/sys/kernel/tracing/events/raw_syscalls/`

No custom kernel build is necessary.

We added the RHACS Collector as a privileged sidecar container inside the Kata
pod. On startup, it detected the guest kernel's BTF, loaded its CO-RE BPF
programs against the guest kernel tracepoints, and connected to the RHACS
Sensor over standard Kubernetes networking.

<!-- diagram: Kata VM with workload container + collector sidecar,
     collector attaches core_bpf to guest kernel tracepoints,
     connects via gRPC/mTLS over K8s networking to Sensor on host -->

Both internal self-checks passed on the first attempt: the Collector
successfully detected its own process execution event and its own network
connection event through the guest kernel's tracepoints.

## What needed to change

Two adjustments were necessary beyond the standard RHACS installation. Neither
requires changes to the RHACS operator, the Kata runtime, or the guest kernel.

**A NetworkPolicy for cross-namespace access.** The default RHACS deployment
restricts Sensor ingress to pods labeled `app: collector` within the `stackrox`
namespace. A Collector running inside a Kata pod in a different namespace cannot
reach the Sensor. We added a NetworkPolicy that allows any pod with the
`app: collector` label, regardless of namespace, to connect to the Sensor on
its gRPC port.

**TLS certificates in the workload namespace.** The Collector authenticates
to the Sensor using certificates from the RHACS init bundle. These secrets
reside in the `stackrox` namespace. We copied the `collector-tls` secret to
the workload namespace so the sidecar container could mount it.

## The result

| Scenario                    | Processes detected   |
|-----------------------------|----------------------|
| runc container              | All (via host eBPF)  |
| Kata pod without sidecar    | None                 |
| Kata pod with sidecar       | All (via guest eBPF) |

With the Collector sidecar in place, RHACS has the same runtime visibility
into a Kata VM that it has into a standard container.

## How this works alongside OpenShell

OpenShell is Red Hat's secure runtime for AI agent workloads in Kata
Containers. It enforces security policies through Landlock LSM, seccomp
filters, and SELinux at the kernel level.

The RHACS Collector's eBPF probes are read-only. They observe syscalls through
kernel tracepoints without blocking or modifying them. OpenShell's enforcement
mechanisms operate at a different kernel layer. The two do not conflict.

Together they provide defense in depth within a single VM:

- **OpenShell prevents** unauthorized operations before they happen.
- **RHACS detects and reports** what did happen, for auditing and alerting.

## What a production implementation would require

This proof of concept demonstrates that the mechanism works. A production
deployment would need additional engineering:

- **Automatic sidecar injection.** A mutating admission webhook or operator
  would add the Collector container to Kata pod specs automatically, similar to
  how service mesh proxies are injected today.

- **Certificate lifecycle management.** Each in-guest Collector needs TLS
  credentials to authenticate with the Sensor. A production system would
  generate and distribute these certificates automatically rather than copying
  secrets between namespaces.

- **Event attribution in Central.** Today, the Sensor treats all Collectors
  identically. Central would benefit from distinguishing between host-level
  events and guest-level events in its dashboards and alerting workflows.

- **Resource overhead assessment.** Running a Collector sidecar per Kata pod
  is heavier than running a single DaemonSet Collector per node. The CPU and
  memory cost needs measurement under realistic workloads to determine
  acceptable deployment patterns.

## Try it yourself

All manifests and step-by-step instructions are available at:
https://github.com/TODO/acs-kata-ebpf

The demo requires an OpenShift cluster with Kata Containers installed and
cluster-admin access. The full setup takes about 15 minutes.

## Acknowledgments

Thanks to Pradipta Banerjee for the original work on running eBPF programs
inside Kata Containers and to the AccuKnox and KubeArmor teams for
demonstrating in-guest eBPF enforcement with Kata.
