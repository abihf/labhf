#!/usr/bin/bash
# Generate Secure Boot PK/KEK/db and signed .auth enrollment files.
# Runs inside the tools container (see Makefile `keys`), output in ./keys.
#   keys/{PK,KEK,db}.{key,crt}    private keys stay HERE (db.key = CI secret)
#   keys/auth/{PK,KEK,db}.auth    for systemd-boot auto-enroll on the real PC
#   keys/GUID
# INCLUDE_MS_CA=1 (default) adds Microsoft UEFI CA 2011+2023 to db so GPU/NIC
# option ROMs on real hardware keep working. Without them a discrete GPU may
# show no picture at boot.
set -euo pipefail
cd /work/keys

if [[ -e db.key ]]; then
    echo "keys/db.key already exists; refusing to overwrite" >&2
    exit 1
fi

uuidgen --random > GUID
guid=$(cat GUID)
ms_guid=77fa9abd-0359-4d32-bd60-28f4e78f784b

for k in PK KEK db; do
    openssl req -newkey rsa:2048 -nodes -keyout "$k.key" -new -x509 -sha256 \
        -days 3650 -subj "/CN=labhf $k/" -out "$k.crt"
    openssl x509 -outform DER -in "$k.crt" -out "$k.der"
    sbsiglist --owner "$guid" --type x509 --output "$k.esl" "$k.der"
done
chmod 0600 ./*.key

cp db.esl db-full.esl
if [[ ${INCLUDE_MS_CA:-1} == 1 ]]; then
    mkdir -p ms
    curl -fsSL -o ms/uefi-ca-2011.der https://www.microsoft.com/pkiops/certs/MicCorUEFCA2011_2011-06-27.crt
    curl -fsSL -o ms/uefi-ca-2023.der "https://www.microsoft.com/pkiops/certs/microsoft%20uefi%20ca%202023.crt"
    for c in ms/*.der; do
        sbsiglist --owner "$ms_guid" --type x509 --output "${c%.der}.esl" "$c"
        cat "${c%.der}.esl" >> db-full.esl
    done
fi

mkdir -p auth
sbvarsign --key PK.key  --cert PK.crt  --output auth/PK.auth  PK  PK.esl
sbvarsign --key PK.key  --cert PK.crt  --output auth/KEK.auth KEK KEK.esl
sbvarsign --key KEK.key --cert KEK.crt --output auth/db.auth  db  db-full.esl
ls -l . auth
