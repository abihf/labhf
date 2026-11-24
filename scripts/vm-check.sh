#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Checks for an installed labhf VM, run inside it as root:
#   ssh -p 2222 abi@localhost sudo bash -s < scripts/vm-check.sh
# Creates a fake LAN client, test pods, a NodePort, NetworkPolicies and a Secret, and starts
# gui.service temporarily. Prints results and fails on a cluster check.
set -uo pipefail
sec() { printf '\n== %s\n' "$*"; }

sec "state"
systemctl is-system-running; systemctl --failed --no-legend --plain | cut -c1-80
bootc status --format=json 2>/dev/null |
    jq -r '.status.booted.image | "booted: \(.image.image) \(.imageDigest)"'
command -v python3 >/dev/null && echo "python3 PRESENT" || echo "no python3"
systemd-cryptenroll /dev/disk/by-partlabel/state | tr '\n' ' '; echo
echo "TPM unlock this boot: $(journalctl -b -u systemd-cryptsetup@state --no-pager | grep -c 'TPM2 token unlocks')"
labhf-pcrlock status 2>&1 | tr "\n" ";"; echo
bootctl status 2>/dev/null | grep -E 'Secure Boot'; cat /sys/kernel/security/lockdown
lsblk -o NAME,SIZE,PARTLABEL,MOUNTPOINTS "/dev/$(lsblk -dno PKNAME /dev/disk/by-partlabel/state)" | head -6

sec "kernel"
tr ' ' '\n' < /proc/cmdline | grep -vE '^composefs' | tr '\n' ' '; echo
sysctl -n kernel.kptr_restrict kernel.dmesg_restrict kernel.unprivileged_bpf_disabled \
    kernel.yama.ptrace_scope fs.suid_dumpable net.ipv4.conf.all.accept_redirects \
    kernel.io_uring_disabled kernel.kexec_load_disabled kernel.sysrq vm.mmap_rnd_bits \
    kernel.ftrace_enabled kernel.perf_event_max_sample_rate | tr '\n' ' '; echo
echo "debug mounts: $(findmnt -rno FSTYPE -t debugfs,tracefs | tr '\n' ' ')(none expected)"
head -c1 /proc/kcore >/dev/null 2>&1 && echo "kcore READABLE" || echo "kcore blocked"
systemctl --failed --no-legend --plain | grep -q systemd-sysctl && echo "systemd-sysctl FAILED"
for m in firewire-core thunderbolt bluetooth sctp udf esp4 l2tp_core nfs sunrpc; do
    modprobe -n -v "$m" 2>&1 | grep -q 'install /bin/false' && printf '%s:blocked ' "$m" || printf '%s:LOADABLE ' "$m"
done; echo
echo "nvidia signer: $(modinfo -F signer nvidia)"

sec "performance"
tr ' ' '\n' < /proc/cmdline | grep -E '^(init_on_|iommu\.strict)' | tr '\n' ' '; echo
sysctl -n net.ipv4.tcp_congestion_control net.core.default_qdisc | tr '\n' ' '; echo
echo "persistenced: $(systemctl is-enabled nvidia-persistenced) $(systemctl is-active nvidia-persistenced); powerd: $(systemctl is-enabled nvidia-powerd)"
udevadm verify /usr/lib/udev/rules.d/6?-labhf-*.rules 2>&1 | grep -E 'Fail|Success' | tr -s ' ' | tr '\n' ' '; echo
grep -H . /sys/devices/system/cpu/cpu0/cpufreq/{scaling_driver,scaling_governor,energy_performance_preference} \
    /sys/block/md*/md/stripe_cache_size /sys/block/sd*/queue/scheduler 2>/dev/null

sec "access"
/usr/sbin/sshd -T 2>/dev/null | grep -iE '^(permitrootlogin|allowusers|passwordauthentication|maxauthtries|allowtcpforwarding) ' | tr '\n' ';'; echo
ls /etc/ssh/authorized_keys.d/ | tr '\n' ' '; echo
passwd -S root | cut -d' ' -f1-2; getent passwd gui | cut -d: -f7
find /usr -xdev -type f -perm /6000 | tr '\n' ' '; echo
ls /etc/sudoers.d/ | tr '\n' ' '; echo
findmnt -no OPTIONS /var/home | cut -c1-40

sec "Kubernetes, CRI-O and SQLite"
(
    set -e
    state=/var/lib/labhf-kubernetes
    export KUBECONFIG=$state/credentials/admin.conf
    cleanup() {
        local status=$?
        if (( status != 0 )); then
            kubectl logs labhf-check --tail=20 || true
        fi
        ip netns del labhf-check 2>/dev/null || true
        ip link del labhf-check 2>/dev/null || true
        kubectl delete service,secret,networkpolicy labhf-check --ignore-not-found >/dev/null || status=1
        kubectl delete pod labhf-check labhf-check-client --grace-period=1 \
            --ignore-not-found --timeout=75s >/dev/null || status=1
        rm -f /home/public/labhf-check || status=1
        exit "$status"
    }
    trap cleanup EXIT
    for unit in labhf-kubernetes.target labhf-kine crio kubelet labhf-kube-router; do
        systemctl is-active "$unit"
    done
    kubectl get --raw /readyz
    kubectl wait --for=condition=Ready node --all --timeout=180s
    kubectl -n kube-system rollout status deployment/coredns --timeout=240s
    test -s "$state/db/state.db"
    test -f "$state/logs/audit.log"
    crio_config=$(crio status config)
    grep -F 'root = "/var/lib/crio/overlay-storage"' <<< "$crio_config" >/dev/null
    grep -F 'overlay.use_composefs=false' <<< "$crio_config" >/dev/null
    test -d /var/lib/crio/overlay-storage/overlay
    test -z "$(find /var/lib/crio/overlay-storage/overlay -name composefs.blob -print -quit)"

    sec "Pod DNS, API, egress and hostPath"
    kubectl run labhf-check --image=docker.io/library/busybox:1.37 --restart=Never \
        --overrides='{"spec":{"volumes":[{"name":"data","hostPath":{"path":"/media/public"}}],"containers":[{"name":"labhf-check","image":"docker.io/library/busybox:1.37","volumeMounts":[{"name":"data","mountPath":"/public"}],"readinessProbe":{"httpGet":{"path":"/","port":8080}},"command":["sh","-ec","date > /public/labhf-check; nslookup kubernetes.default.svc.cluster.local; out=$(wget --no-check-certificate -qO- -T5 https://kubernetes.default.svc 2>&1 || true); case $out in *HTTP/*) ;; *) echo \"$out\" >&2; exit 1;; esac; wget -qO- -T5 http://example.com >/dev/null; mkdir -p /tmp/www; echo ok >/tmp/www/index.html; exec httpd -f -p 8080 -h /tmp/www"]}]}}'
    kubectl wait --for=condition=Ready pod/labhf-check --timeout=180s
    kubectl logs labhf-check
    test -s /home/public/labhf-check
    kubectl expose pod labhf-check --name=labhf-check --type=NodePort --port=8080
    node_port=$(kubectl get service labhf-check -o jsonpath='{.spec.ports[0].nodePort}')
    pod_ip=$(kubectl get pod labhf-check -o jsonpath='{.status.podIP}')
    service_ip=$(kubectl get service labhf-check -o jsonpath='{.spec.clusterIP}')

    sec "Firewall from a fake LAN client"
    probe() { ip netns exec labhf-check timeout 3 bash -c 'echo > "/dev/tcp/$1/$2"' bash "$1" "$2" 2>/dev/null; }
    ip netns add labhf-check
    ip link add labhf-check type veth peer name lanp
    ip link set lanp netns labhf-check
    ip addr add 192.0.2.1/24 dev labhf-check
    ip link set labhf-check up
    ip -n labhf-check addr add 192.0.2.2/24 dev lanp
    ip -n labhf-check link set lanp up
    ip -n labhf-check route add default via 192.0.2.1
    probe 192.0.2.1 22 || { echo 'Expected LAN access to SSH' >&2; exit 1; }
    for _ in {1..30}; do
        probe 192.0.2.1 "$node_port" && break
        sleep 2
    done
    probe 192.0.2.1 "$node_port" || { echo "Expected LAN access to NodePort $node_port" >&2; exit 1; }
    for endpoint in "192.0.2.1:6443" "192.0.2.1:10250" "$pod_ip:8080" "$service_ip:8080"; do
        if probe "${endpoint%:*}" "${endpoint##*:}"; then
            echo "Unexpected LAN access to $endpoint" >&2
            exit 1
        fi
    done

    sec "NetworkPolicy ingress and egress"
    kubectl run labhf-check-client --image=docker.io/library/busybox:1.37 \
        --restart=Never --command -- sleep 600
    kubectl wait --for=condition=Ready pod/labhf-check-client --timeout=180s
    wait_policy() {
        local expected=$1 result
        for _ in {1..12}; do
            result=$(kubectl --request-timeout=8s exec labhf-check-client -- sh -c '
                if wget -q -O /dev/null -T 2 "$1"; then echo allowed; else echo blocked; fi
            ' sh "http://$pod_ip:8080/") || return 1
            [[ $result == "$expected" ]] && return 0
            sleep 2
        done
        echo "Expected traffic to be $expected, last result: $result" >&2
        return 1
    }
    wait_policy allowed
    kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: labhf-check
spec:
  podSelector:
    matchLabels:
      run: labhf-check
  policyTypes: [Ingress]
  ingress: []
YAML
    wait_policy blocked
    kubectl delete networkpolicy labhf-check
    wait_policy allowed
    kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: labhf-check
spec:
  podSelector:
    matchLabels:
      run: labhf-check-client
  policyTypes: [Egress]
  egress: []
YAML
    wait_policy blocked
    kubectl delete networkpolicy labhf-check
    wait_policy allowed

    sec "Secret encryption"
    kubectl create secret generic labhf-check --from-literal=value=LABHFCHECKVALUE
    db=( "$state/db/state.db" )
    [[ ! -f $state/db/state.db-wal ]] || db+=( "$state/db/state.db-wal" )
    if grep -aFq LABHFCHECKVALUE "${db[@]}"; then
        echo 'Kubernetes Secret is visible in SQLite' >&2
        exit 1
    fi
    grep -aF 'k8s:enc:aescbc:v1:labhf:' "${db[@]}" >/dev/null
)
cluster_status=$?
(( cluster_status == 0 )) || exit "$cluster_status"

sec "kiosk (started, not enabled)"
gui_was_active=0
if systemctl is-active --quiet gui; then gui_was_active=1; fi
systemctl is-enabled gui; systemctl start gui
for i in $(seq 1 15); do pgrep -x WPEWebProcess >/dev/null && break; sleep 2; done; sleep 5
echo "gui: $(systemctl is-active gui), restarts $(systemctl show gui -p NRestarts --value)"
for p in $(pgrep -x WPEWebProcess) $(pgrep -x cage); do
    echo "  $(cat /proc/$p/comm): $(grep -oE 'libgallium[^ ]*' /proc/$p/maps | sort -u) NoNewPrivs=$(awk '/NoNewPrivs/{print $2}' /proc/$p/status)"
done
if (( ! gui_was_active )); then systemctl stop gui; fi

sec "SELinux denials this boot"
ausearch --input-logs -m avc -ts boot 2>&1 | grep -c 'avc:' || true
