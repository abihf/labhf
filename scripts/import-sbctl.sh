#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Use an existing sbctl key set instead of `make keys` (tools container).
#
# Inputs (in ./keys, git-ignored):
#   sbctl-keys.tgz          tar of /var/lib/sbctl/{GUID,keys/} from the machine
#   sbctl-efivars/*.esl     its enrolled PK/KEK/db variables, without the 4-byte
#                           attribute header (world-readable in efivars)
# Output: the same layout gen-keys.sh writes, so the build, CI and the VM use
# it unchanged:
#   keys/{PK,KEK,db}.{key,crt,der,esl}, keys/GUID
#   keys/db-full.esl        = the enrolled db (our cert + sbctl's option ROM
#                             hashes from the TPM event log; no Microsoft CAs)
#   keys/auth/*.auth        re-enroll exactly what is enrolled now
# Keys found in ./keys before are moved to keys/replaced-<date>/, not deleted.
set -euo pipefail
cd /work/keys

[[ -f sbctl-keys.tgz ]] || { echo "keys/sbctl-keys.tgz missing" >&2; exit 1; }
for v in PK KEK db; do
    [[ -s sbctl-efivars/$v.esl ]] || { echo "keys/sbctl-efivars/$v.esl missing" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(umask 077; tar -C "$work" -xzf sbctl-keys.tgz)
guid=$(tr -d '[:space:]' < "$work/GUID")

# every key must match its certificate, and the certificate what is enrolled
for k in PK KEK db; do
    key=$work/keys/$k/$k.key crt=$work/keys/$k/$k.pem
    [[ $(openssl pkey -in "$key" -pubout | sha256sum) == $(openssl x509 -in "$crt" -noout -pubkey | sha256sum) ]] \
        || { echo "$k.key does not match $k.pem" >&2; exit 1; }
    openssl x509 -in "$crt" -outform DER -out "$work/$k.der"
    sbsiglist --owner "$guid" --type x509 --output "$work/$k.esl" "$work/$k.der"
    n=$(stat -c %s "$work/$k.esl")
    # PK/KEK: the whole variable; db: its first signature list (hashes follow)
    if [[ $k == db ]]; then
        cmp -s -n "$n" "$work/$k.esl" sbctl-efivars/db.esl
    else
        cmp -s "$work/$k.esl" "sbctl-efivars/$k.esl"
    fi || { echo "$k.pem is not what the firmware has enrolled" >&2; exit 1; }
    echo "$k: $(openssl x509 -in "$crt" -noout -subject) matches the enrolled $k"
done

if [[ -e db.key ]]; then
    if cmp -s db.key "$work/keys/db/db.key"; then
        echo "keys/db.key is already the sbctl db key"
    else
        old=replaced-$(date +%Y%m%d-%H%M%S)
        mkdir -m 0700 "$old"
        mv -v ./*.key ./*.crt ./*.der ./*.esl GUID auth "$old"/ 2>/dev/null || true
        [[ -d ms ]] && mv -v ms "$old"/
    fi
fi

for k in PK KEK db; do
    install -m 0600 "$work/keys/$k/$k.key" "$k.key"
    install -m 0644 "$work/keys/$k/$k.pem" "$k.crt"
    install -m 0644 "$work/$k.der" "$work/$k.esl" .
done
printf '%s\n' "$guid" > GUID
cp sbctl-efivars/db.esl db-full.esl

mkdir -p auth
sbvarsign --key PK.key  --cert PK.crt  --output auth/PK.auth  PK  PK.esl
sbvarsign --key PK.key  --cert PK.crt  --output auth/KEK.auth KEK KEK.esl
sbvarsign --key KEK.key --cert KEK.crt --output auth/db.auth  db  db-full.esl
ls -l . auth
