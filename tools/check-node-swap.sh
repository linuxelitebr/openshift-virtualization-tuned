#!/usr/bin/env bash
#
# check-node-swap.sh -- verify swap is the same size on every node in the cluster.
#
# Companion to "OpenShift Virtualization, Tuned. Part 4: Ballooning and Overcommit"
# (linuxelite.com.br). Memory overcommit leans on swap, but the wasp-agent only lets
# Burstable VM pods use it. When swap is provisioned by a MachineConfig that drops a
# swapfile on the node disk -- the only option on a cluster that did not reserve a
# dedicated swap partition at install time -- a node whose disk is too full will SKIP
# swap. A fail-safe provisioner is RIGHT to skip rather than strand the node, but the
# result is heterogeneous: a Burstable VM that swaps and survives on one node will OOM
# on the swapless one. That heterogeneity is the opposite of the determinism you want.
# This reads swap on every node and flags any that differs from the cluster majority.
#
# Usage:  ./check-node-swap.sh          # uses your current oc/kubectl context
#         CLI=kubectl ./check-node-swap.sh
# Needs:  permission to run `oc debug node` on every node. Exits non-zero on a mismatch.
#
set -euo pipefail
CLI="${CLI:-oc}"

nodes=$("$CLI" get nodes -o name | sed 's|node/||')
[ -n "$nodes" ] || { echo "no nodes found (is your context set?)"; exit 1; }

# Read live swap (MiB) off each host; round to the nearest GiB so 7999 and 8192 compare
# sanely. An unreachable node reads 0 and will be flagged, which is the correct outcome.
declare -A GIB
for n in $nodes; do
  mib=$("$CLI" debug node/"$n" -q -- chroot /host free -m 2>/dev/null | awk '/^Swap:/{print $2}')
  GIB["$n"]=$(( (${mib:-0} + 512) / 1024 ))
done

# The expected size is whatever most nodes agree on.
declare -A COUNT
for n in "${!GIB[@]}"; do COUNT["${GIB[$n]}"]=$(( ${COUNT["${GIB[$n]}"]:-0} + 1 )); done
expected=0; best=0
for sz in "${!COUNT[@]}"; do
  [ "${COUNT[$sz]}" -gt "$best" ] && { best=${COUNT[$sz]}; expected=$sz; }
done

printf '%-46s %10s   %s\n' "NODE" "SWAP" "STATUS"
mismatch=0
for n in $(printf '%s\n' "${!GIB[@]}" | sort); do
  if [ "${GIB[$n]}" -eq "$expected" ]; then
    status="ok"
  else
    status="DIFFERS (cluster majority is ${expected} GiB)"
    mismatch=$((mismatch + 1))
  fi
  printf '%-46s %6s GiB   %s\n' "$n" "${GIB[$n]}" "$status"
done

echo
if [ "$expected" -eq 0 ] && [ "$mismatch" -eq 0 ]; then
  echo "No swap is configured on any node. Memory overcommit has nothing to swap to, so"
  echo "Burstable VMs will OOM rather than degrade. Provision swap (ideally a dedicated device)."
  exit 0
elif [ "$mismatch" -eq 0 ]; then
  echo "All ${#GIB[@]} nodes report ${expected} GiB of swap. Consistent and deterministic."
  exit 0
else
  echo "WARNING: ${mismatch} node(s) differ from the ${expected} GiB majority."
  echo "Overcommit will behave non-deterministically: a Burstable VM that swaps on one node"
  echo "may OOM on another. Re-provision the outliers, or move to a dedicated swap device"
  echo "sized identically on every node (a decision best made before the cluster is installed)."
  exit 1
fi
