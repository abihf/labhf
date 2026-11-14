#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Checks for an installed labhf VM, run inside it as root:
#   ssh -p 2222 abi@localhost sudo bash -s < scripts/vm-check.sh
# Read-mostly. Temporarily creates a network namespace (fake LAN client), a
# test pod and a k8s secret, and starts gui.service without enabling it; all
# are removed again. Prints results; it does not judge them all.
set -uo pipefail
sec() { printf '\n== %s\n' "$*"; }

sec "state"
systemctl is-system-running; systemctl --failed --no-legend --plain | cut -c1-80
bootc status --format=json 2>/dev/null | python3 -c 'import json,sys
s=json.load(sys.stdin)["status"]; b=s["booted"]["image"]
print("booted:", b["image"]["image"], b["imageDigest"])'
systemd-cryptenroll /dev/disk/by-partlabel/state | tr '\n' ' '; echo
echo "TPM unlock this boot: $(journalctl -b -u systemd-cryptsetup@state --no-pager | grep -c 'TPM2 token unlocks')"
bootctl status 2>/dev/null | grep -E 'Secure Boot'; cat /sys/kernel/security/lockdown
lsblk -o NAME,SIZE,PARTLABEL,MOUNTPOINTS "/dev/$(lsblk -dno PKNAME /dev/disk/by-partlabel/state)" | head -6

sec "kernel"
tr ' ' '\n' < /proc/cmdline | grep -vE '^composefs' | tr '\n' ' '; echo
sysctl -n kernel.kptr_restrict kernel.dmesg_restrict kernel.unprivileged_bpf_disabled \
    kernel.yama.ptrace_scope fs.suid_dumpable net.ipv4.conf.all.accept_redirects | tr '\n' ' '; echo
for m in firewire-core thunderbolt bluetooth sctp udf; do
    modprobe -n -v "$m" 2>&1 | grep -q 'install /bin/false' && printf '%s:blocked ' "$m" || printf '%s:LOADABLE ' "$m"
done; echo
echo "nvidia signer: $(modinfo -F signer nvidia)"

sec "access"
/usr/sbin/sshd -T 2>/dev/null | grep -iE '^(permitrootlogin|allowusers|passwordauthentication|maxauthtries|allowtcpforwarding) ' | tr '\n' ';'; echo
ls /etc/ssh/authorized_keys.d/ | tr '\n' ' '; echo
passwd -S root | cut -d' ' -f1-2; getent passwd gui | cut -d: -f7
find /usr -xdev -type f -perm /6000 | tr '\n' ' '; echo
ls /etc/sudoers.d/ | tr '\n' ' '; echo
findmnt -no OPTIONS /var/home | cut -c1-40

sec "k3s"
for i in $(seq 1 60); do kubectl get --raw /readyz >/dev/null 2>&1 && break; sleep 3; done
kubectl wait --for=condition=Ready node --all --timeout=180s
k3s secrets-encrypt status 2>&1 | head -1
ls /var/lib/rancher/k3s/server/logs/audit.log
# a fresh cluster creates Traefik's pods a few minutes in: wait for them to exist
for i in $(seq 1 60); do
    [[ -n $(kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o name 2>/dev/null) ]] && break; sleep 5
done
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=traefik -n kube-system --timeout=240s >/dev/null && echo traefik-ready
kubectl wait --for=condition=Ready pod -l svccontroller.k3s.cattle.io/svcname=traefik -n kube-system --timeout=120s >/dev/null && echo svclb-ready
sleep 10

sec "firewall (fake LAN client in a netns)"
probe() { ip netns exec lan timeout 3 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null && echo open || echo closed; }
ip netns del lan 2>/dev/null; ip link del lanv 2>/dev/null
ip netns add lan; ip link add lanv type veth peer name lanp; ip link set lanp netns lan
ip addr add 192.0.2.1/24 dev lanv; ip link set lanv up
ip netns exec lan ip addr add 192.0.2.2/24 dev lanp; ip netns exec lan ip link set lanp up
ip netns exec lan ip route add default via 192.0.2.1; sleep 1
tp=$(kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}')
for p in 22 6443 10250 80 443; do printf 'host:%s %s  ' "$p" "$(probe 192.0.2.1 "$p")"; done; echo
echo "pod $tp:8000 $(probe "$tp" 8000)  svc 10.43.0.10:53 $(probe 10.43.0.10 53)"
ok=0; for i in $(seq 1 40); do ip netns exec lan timeout 1 bash -c "echo > /dev/tcp/192.0.2.1/22" 2>/dev/null && ok=$((ok+1)); done
echo "ssh rate limit: $ok of 40 new connections accepted"
ip netns del lan; ip link del lanv 2>/dev/null

sec "pods"
kubectl delete pod labhf-check --ignore-not-found --wait >/dev/null 2>&1
kubectl run labhf-check --restart=Never --image=docker.io/library/busybox:1.37 \
  --overrides='{"spec":{"volumes":[{"name":"p","hostPath":{"path":"/media/public"}}],"containers":[{"name":"labhf-check","image":"docker.io/library/busybox:1.37","volumeMounts":[{"name":"p","mountPath":"/public"}],"command":["sh","-c","date > /public/labhf-check && echo public-write-ok; nslookup kubernetes.default.svc.cluster.local >/dev/null && echo cluster-dns-ok; wget -qO- -T5 http://example.com >/dev/null && echo egress-ok; o=$(wget -qO- -T5 http://kubernetes.default.svc:443/ 2>&1); case $o in *HTTP/*) echo api-ok;; *) echo api-FAIL;; esac; true"]}]}}' >/dev/null 2>&1
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/labhf-check --timeout=180s >/dev/null && kubectl logs labhf-check
kubectl delete pod labhf-check --wait=false >/dev/null; rm -f /home/public/labhf-check
kubectl create secret generic labhf-check --from-literal=k=LABHFCHECKVALUE >/dev/null
echo "secret in plaintext in the db: $(strings /var/lib/rancher/k3s/server/db/state.db 2>/dev/null | grep -c LABHFCHECKVALUE)"
kubectl delete secret labhf-check >/dev/null

sec "kiosk (started, not enabled)"
systemctl is-enabled gui; systemctl start gui
for i in $(seq 1 15); do pgrep -x WPEWebProcess >/dev/null && break; sleep 2; done; sleep 5
echo "gui: $(systemctl is-active gui), restarts $(systemctl show gui -p NRestarts --value)"
for p in $(pgrep -x WPEWebProcess) $(pgrep -x cage); do
    echo "  $(cat /proc/$p/comm): $(grep -oE 'libgallium[^ ]*' /proc/$p/maps | sort -u) NoNewPrivs=$(awk '/NoNewPrivs/{print $2}' /proc/$p/status)"
done
systemctl stop gui

sec "SELinux denials this boot"
ausearch --input-logs -m avc -ts boot 2>&1 | grep -c 'avc:' || true
