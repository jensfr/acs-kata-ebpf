#!/bin/bash
# Demo script for asciinema recording
# Simulates typing with readable pacing

export KUBECONFIG=/Users/jfreiman/kubeconfig.virtlab725

TYPE_DELAY=0.04
PAUSE_SHORT=2
PAUSE_MEDIUM=4
PAUSE_LONG=6

type_cmd() {
    echo ""
    echo -ne "\033[1;32m$ \033[0m"
    for (( i=0; i<${#1}; i++ )); do
        echo -n "${1:$i:1}"
        sleep $TYPE_DELAY
    done
    echo ""
    sleep 0.5
}

pause() {
    sleep "$1"
}

header() {
    echo ""
    echo -e "\033[1;36m━━━ $1 ━━━\033[0m"
    sleep "$PAUSE_MEDIUM"
}

# ─────────────────────────────────────────────────
header "RHACS eBPF Inside Kata Containers"
echo ""
echo "RHACS monitors containers via eBPF probes on the host kernel."
echo "Kata Containers run workloads in VMs with their own kernel."
echo "Can RHACS see inside a Kata VM?"
pause $PAUSE_LONG

# ─────────────────────────────────────────────────
header "Step 1: Verify test pods are running"

type_cmd "oc get pods -n rhacs-demo"
oc get pods -n rhacs-demo 2>/dev/null | grep -E "NAME|test-runc|test-kata |kata-with-collector"
pause $PAUSE_MEDIUM

# ─────────────────────────────────────────────────
header "Step 2: Check what RHACS sees in the runc container"

COLLECTOR=$(oc get pods -n stackrox -l app=collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
RUNC_CID=$(oc get pod test-runc -n rhacs-demo -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | sed 's|cri-o://||' | cut -c1-12)

type_cmd "oc logs \$COLLECTOR -c collector -n stackrox | grep \$RUNC_CID | tail -8"
oc logs $COLLECTOR -c collector -n stackrox 2>/dev/null | grep "$RUNC_CID" | grep "ProcessSignalFormatter.cpp:192" | tail -8 | sed 's/\[DEBUG.*192) //' | sed 's/\[DEBUG.*256) //'
pause $PAUSE_LONG

echo ""
echo -e "\033[1;33m→ RHACS sees whoami, id, curl, sleep — every process.\033[0m"
pause $PAUSE_MEDIUM

# ─────────────────────────────────────────────────
header "Step 3: Check what RHACS sees in the Kata container (no sidecar)"

KATA_CID=$(oc get pod test-kata -n rhacs-demo -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | sed 's|cri-o://||' | cut -c1-12)

type_cmd "oc logs \$COLLECTOR -c collector -n stackrox | grep \$KATA_CID | wc -l"
COUNT=$(oc logs $COLLECTOR -c collector -n stackrox 2>/dev/null | grep -c "$KATA_CID")
echo "$COUNT"
pause $PAUSE_MEDIUM

echo ""
echo -e "\033[1;31m→ Zero events. RHACS cannot see inside the Kata VM.\033[0m"
pause $PAUSE_LONG

# ─────────────────────────────────────────────────
header "Step 4: The fix — collector sidecar inside the Kata VM"

echo "A second RHACS collector runs as a privileged sidecar"
echo "inside the Kata pod. It attaches core_bpf probes to the"
echo "guest kernel and sends events to the RHACS sensor."
pause $PAUSE_LONG

type_cmd "oc logs kata-with-collector -c collector -n rhacs-demo | grep -E 'Sensor|core_bpf|self-check|Driver'"
oc logs kata-with-collector -c collector -n rhacs-demo 2>/dev/null | grep -E "Connected to Sensor|core_bpf|Found self-check|Driver loaded" | sed 's/\[INFO.*\] //'
pause $PAUSE_LONG

echo ""
echo -e "\033[1;32m→ core_bpf loaded in the guest kernel. Both self-checks passed.\033[0m"
pause $PAUSE_MEDIUM

# ─────────────────────────────────────────────────
header "Step 5: Guest kernel traces from the Kata VM"

type_cmd "oc logs kata-with-collector -c collector -n rhacs-demo | grep ProcessSignalFormatter | tail -12"
oc logs kata-with-collector -c collector -n rhacs-demo 2>/dev/null | grep "ProcessSignalFormatter.cpp:192" | tail -12 | sed 's/\[DEBUG.*192) //'
pause $PAUSE_LONG

echo ""
echo -e "\033[1;32m→ RHACS now sees every process inside the Kata VM.\033[0m"
pause $PAUSE_MEDIUM

# ─────────────────────────────────────────────────
header "Summary"
echo ""
echo "  runc container:              ✓ All processes visible (host eBPF)"
echo "  Kata pod, no sidecar:        ✗ Zero events"
echo "  Kata pod, collector sidecar:  ✓ All processes visible (guest eBPF)"
echo ""
echo "No custom kernel. No QEMU changes. No kata-agent patches."
echo ""
pause $PAUSE_LONG
