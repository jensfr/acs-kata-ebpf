# ACS eBPF Inside Kata Containers

RHACS can't see inside Kata VMs. This repo shows how to fix that.

## Why RHACS Goes Blind With Kata

RHACS monitors containers by attaching eBPF probes to the host kernel. Every
syscall a container makes passes through that kernel, so the probes see
everything: process execution, network connections, file access.

Kata Containers break this model. Each pod runs inside a lightweight VM with
its own kernel. The host kernel never sees the guest's syscalls. From RHACS's
perspective, a Kata pod is a black box.

We verified this on an OpenShift 4.21 cluster running RHACS 4.11. Two pods
ran the same commands (`whoami`, `curl`, `id`). The host collector captured
30,000+ events from the runc pod and exactly zero from the Kata pod.

## The Fix: A Collector Sidecar Inside the VM

The RHACS collector doesn't care which kernel it runs against. Add it as a
privileged sidecar inside the Kata pod, and it attaches core_bpf probes to
the guest kernel instead of the host kernel. It connects back to the RHACS
sensor over ordinary Kubernetes networking.

No custom kernel. No QEMU changes. No kata-agent patches. The RHEL 9 guest
kernel already ships with full eBPF and BTF support.

```
Host
 +-- RHACS Sensor <----- gRPC/mTLS ----------+
 |                                            |
 +-- Kata VM                                  |
      +-- workload container                  |
      |     whoami, curl, id, ...             |
      |                                       |
      +-- collector sidecar (privileged)      |
            core_bpf --> guest kernel ---------+
```

## Results

| Scenario                     | Processes Detected |
|------------------------------|--------------------|
| runc container               | All (host eBPF)    |
| Kata pod, no sidecar         | None               |
| Kata pod, collector sidecar  | All (guest eBPF)   |

## Reproducing This

You need an OpenShift cluster with Kata installed and cluster-admin access.

### 1. Install RHACS

```bash
oc apply -f manifests/01-rhacs-operator.yaml
oc get csv -n rhacs-operator -w          # wait for Succeeded
```

**On clusters without a default StorageClass** (bare-metal, single-node),
create hostPath PVs first:

```bash
oc debug node/$(oc get nodes -o jsonpath='{.items[0].metadata.name}') \
  -- chroot /host sh -c '
  mkdir -p /opt/stackrox-data /opt/central-db-data
  chown 4000:4000 /opt/stackrox-data
  chown 70:70 /opt/central-db-data
  chcon -R -t container_file_t /opt/stackrox-data /opt/central-db-data'

cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: stackrox-db-pv
spec:
  capacity: { storage: 100Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  hostPath: { path: /opt/stackrox-data, type: DirectoryOrCreate }
  claimRef: { namespace: stackrox, name: stackrox-db }
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: central-db-pv
spec:
  capacity: { storage: 128Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  hostPath: { path: /opt/central-db-data, type: DirectoryOrCreate }
  claimRef: { namespace: stackrox, name: central-db }
EOF
```

Then deploy Central:

```bash
oc apply -f manifests/02-central.yaml
oc wait --for=condition=Deployed central/stackrox-central-services \
  -n stackrox --timeout=300s
```

### 2. Generate the Init Bundle

The init bundle gives secured cluster components the TLS certs they need to
talk to Central.

```bash
ADMIN_PASSWORD=$(oc get secret central-htpasswd -n stackrox \
  -o jsonpath='{.data.password}' | base64 -d)

oc port-forward svc/central -n stackrox 18443:443 &
sleep 5

curl -sk -u "admin:$ADMIN_PASSWORD" \
  "https://localhost:18443/v1/cluster-init/init-bundles" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"name": "init-bundle"}' | \
  python3 -c 'import json,sys,base64; open("init-bundle.yaml","w").write(
    base64.b64decode(json.load(sys.stdin)["kubectlBundle"]).decode())'

kill %1
oc apply -f init-bundle.yaml -n stackrox
```

### 3. Deploy SecuredCluster

Edit `clusterName` in `manifests/03-secured-cluster.yaml`, then:

```bash
oc apply -f manifests/03-secured-cluster.yaml
oc wait --for=condition=Deployed securedcluster/stackrox-secured-cluster-services \
  -n stackrox --timeout=300s
```

### 4. Show the Monitoring Gap

```bash
oc new-project rhacs-demo
oc apply -f manifests/05-demo-runc-pod.yaml
oc apply -f manifests/06-demo-kata-no-collector.yaml
sleep 60

COLLECTOR=$(oc get pods -n stackrox -l app=collector \
  -o jsonpath='{.items[0].metadata.name}')

RUNC_CID=$(oc get pod test-runc -n rhacs-demo \
  -o jsonpath='{.status.containerStatuses[0].containerID}' | \
  sed 's|cri-o://||' | cut -c1-12)
KATA_CID=$(oc get pod test-kata -n rhacs-demo \
  -o jsonpath='{.status.containerStatuses[0].containerID}' | \
  sed 's|cri-o://||' | cut -c1-12)

echo "runc events:"
oc logs $COLLECTOR -c collector -n stackrox | grep "$RUNC_CID" | tail -3
echo "kata events:"
oc logs $COLLECTOR -c collector -n stackrox | grep -c "$KATA_CID"
```

### 5. Fix It With an In-Guest Collector

Two things the default RHACS install doesn't handle:

1. The sensor's NetworkPolicy blocks connections from outside the `stackrox`
   namespace. Open it for pods labeled `app: collector` in any namespace.
2. The collector sidecar needs the TLS certs from the init bundle.

```bash
oc apply -f manifests/04-networkpolicy-kata-collector.yaml

oc get secret collector-tls -n stackrox -o json | \
  python3 -c 'import json,sys; s=json.load(sys.stdin);
    s["metadata"]={"name":"collector-tls","namespace":"rhacs-demo"};
    json.dump(s,sys.stdout)' | oc apply -f -

oc apply -f manifests/07-demo-kata-with-collector.yaml
```

Verify:

```bash
oc logs kata-with-collector -c collector -n rhacs-demo --tail=10
```

You should see:

```
Connected to Sensor?       true
  core_bpf (available)
Driver loaded into kernel: core_bpf
Found self-check process event.
Found self-check connection event.
```

Both self-checks pass. The collector is monitoring the guest kernel.

## What This Means for OpenShell

The eBPF probes are read-only. They attach to kernel tracepoints and observe
syscalls; they don't block or modify them. OpenShell enforces policy through
Landlock, seccomp, and SELinux. The two operate at different layers and don't
conflict.

- **OpenShell** prevents unauthorized operations.
- **RHACS collector** reports what happened.

They are complementary, not competing.

## What Would Need to Change for Production

This demo proves the mechanism works. Shipping it would require:

- **Sidecar injection** via a mutating webhook or operator, so users don't
  manually add the collector container to every Kata pod spec.
- **Certificate handling** so each in-guest collector gets proper TLS certs
  without copying secrets across namespaces by hand.
- **Sensor/Central awareness** that these events come from a guest VM. Today
  the sensor treats all collectors identically.
- **Resource budgeting.** One collector per pod is heavier than one DaemonSet
  per node. The overhead needs measurement.

## References

- [eBPF in Kata Containers (Pradipta's gist)](https://gist.github.com/PiyushRaj927/5eb49595a82d9ca5313ae11e16593b71)
- [RHACS 4.11 Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11)
- [StackRox Collector Source](https://github.com/stackrox/collector)
