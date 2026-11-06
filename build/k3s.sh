#!/usr/bin/bash
# Install the upstream k3s static binary (pinned + checksummed).
set -euxo pipefail

: "${K3S_VERSION:?}" "${K3S_SHA256:?}"

url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}/k3s"
curl -fsSL -o /tmp/k3s "$url"
echo "${K3S_SHA256}  /tmp/k3s" | sha256sum -c -
install -m 0755 /tmp/k3s /usr/bin/k3s

for l in kubectl crictl ctr; do
    ln -sf k3s "/usr/bin/$l"
done

/usr/bin/k3s --version
# Show which SELinux type the policy assigns (should be k3s_exec_t or similar)
matchpathcon /usr/bin/k3s || true
