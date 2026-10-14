#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

if (( EUID != 0 )); then
  if unshare --user --map-root-user true 2>/dev/null; then
    exec unshare --user --map-root-user bash "$0"
  fi
  skip "no unprivileged user namespace; skipping factory accessory trust cleanup"
  exit 0
fi

require_command systemctl

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

awk '
  /^[a-z_]+\(\) \{/ { copying = 1 }
  copying { print }
  /^}/ { copying = 0 }
' "$ROOT/bin/omarchy-system-factory-reset" >"$test_tmp/functions"

cat >"$test_tmp/reset" <<'SH'
#!/bin/bash
set -euo pipefail
source "$1/functions"
TOP_MNT="$2"
NEXT_NAME=@omarchy-reset-next
PROVISIONING_DIR=/var/lib/omarchy/provisioning
LOG_FILE="$TOP_MNT/reset.log"

log() { printf '%s\n' "$1" >>"$LOG_FILE"; }
fail() { log "$1"; exit 1; }

btrfs() {
  if [[ $1 == "subvolume" && $2 == "snapshot" ]]; then
    mkdir -p "$4"
    cp -a "$3/." "$4/"
  elif [[ $1 == "property" ]]; then
    printf '%s\n' "$6" >"$4/read-only"
  else
    return 1
  fi
}
systemd-id128() { printf '%032d\n' 1; }
install_provisioning_units() { :; }
encrypted_install() { return 1; }
rebuild_next_boot() { touch "$TOP_MNT/rebuilt"; }

stage_full_reset
SH

make_accounts() {
  local factory=$1
  mkdir -p "$factory/etc" "$factory/home/seller" \
    "$factory/usr/bin" "$factory/usr/share/omarchy/install/provisioning" \
    "$factory/var/lib/omarchy/provisioning/packages"
  touch "$factory/home/seller/private-file" \
    "$factory/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service" \
    "$factory/var/lib/omarchy/provisioning/packages/node-v0.tar.gz"
  printf '#!/bin/bash\n' >"$factory/usr/bin/omarchy-provision-owner"
  chmod +x "$factory/usr/bin/omarchy-provision-owner"
  printf 'true\n' >"$factory/read-only"
  cat >"$factory/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/:/usr/bin/nologin
seller:x:1000:1000:Seller:/home/seller:/bin/bash
EOF
  printf 'root:original-root-hash:20000:0:99999:7:::\ndaemon:*:20000:0:99999:7:::\nseller:original-user-hash:20000:0:99999:7:::\n' >"$factory/etc/shadow"
  printf 'root:x:0:\ndaemon:x:1:\nseller:x:1000:\nwheel:x:998:seller\n' >"$factory/etc/group"
  printf 'root:!::\ndaemon:!::\nseller:!::\nwheel:!::seller\n' >"$factory/etc/gshadow"
  printf 'USERGROUPS_ENAB yes\n' >"$factory/etc/login.defs"
  printf 'seller:100000:65536\n' >"$factory/etc/subuid"
  printf 'seller:100000:65536\n' >"$factory/etc/subgid"
  chmod 600 "$factory/etc/"{shadow,gshadow}
  local file
  for file in passwd shadow group gshadow subuid subgid; do
    cp "$factory/etc/$file" "$factory/etc/$file-"
  done
}

plant_trust() {
  local factory=$1
  mkdir -p "$factory/etc/usbguard/IPCAccessControl.d" \
    "$factory/etc/systemd/system/multi-user.target.wants" \
    "$factory/usr/lib/systemd/system" \
    "$factory/etc/omarchy" \
    "$factory/var/lib/omarchy/thunderbolt-authorization" \
    "$factory/var/lib/boltd/devices" "$factory/var/lib/boltd/keys" "$factory/var/lib/boltd/domains"
  printf '[Unit]\nDescription=USBGuard\n[Service]\nExecStart=/usr/bin/usbguard-daemon\n[Install]\nWantedBy=multi-user.target\n' \
    >"$factory/usr/lib/systemd/system/usbguard.service"
  ln -s /usr/lib/systemd/system/usbguard.service \
    "$factory/etc/systemd/system/multi-user.target.wants/usbguard.service"
  printf 'allow id 1d6b:0002\n' >"$factory/etc/usbguard/rules.conf"
  printf '[Unit]\nDescription=Thunderbolt authorization\n[Service]\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' \
    >"$factory/usr/lib/systemd/system/omarchy-thunderbolt-authorization.service"
  ln -s /usr/lib/systemd/system/omarchy-thunderbolt-authorization.service \
    "$factory/etc/systemd/system/multi-user.target.wants/omarchy-thunderbolt-authorization.service"
  printf 'enabled\n' >"$factory/etc/omarchy/thunderbolt-authorization.enabled"
  printf 'pending\n' >"$factory/etc/omarchy/thunderbolt-authorization.pending"
  printf '{"trusted":{"seller-dock":true}}\n' >"$factory/var/lib/omarchy/thunderbolt-authorization/policy.json"
  printf 'enrolled\n' >"$factory/var/lib/boltd/devices/seller-dock"
  printf 'key\n' >"$factory/var/lib/boltd/keys/seller-dock"
  printf 'domain\n' >"$factory/var/lib/boltd/domains/controller"
  printf '[config]\nAuthMode = disabled\nSomeOther = keep\n' >"$factory/var/lib/boltd/boltd.conf"
}

assert_trust_cleared() {
  local root=$1 label=$2
  [[ ! -L $root/etc/systemd/system/multi-user.target.wants/usbguard.service && ! -e $root/etc/systemd/system/multi-user.target.wants/usbguard.service ]] ||
    fail "$label still enables USBGuard"
  [[ $(cat "$root/etc/usbguard/rules.conf") == "allow id 1d6b:0002" ]] ||
    fail "$label drops the USBGuard rules file"
  [[ ! -L $root/etc/systemd/system/multi-user.target.wants/omarchy-thunderbolt-authorization.service && ! -e $root/etc/systemd/system/multi-user.target.wants/omarchy-thunderbolt-authorization.service ]] ||
    fail "$label still enables Thunderbolt authorization"
  [[ ! -e $root/etc/omarchy/thunderbolt-authorization.enabled && ! -e $root/etc/omarchy/thunderbolt-authorization.pending ]] ||
    fail "$label keeps Thunderbolt authorization markers"
  [[ ! -e $root/var/lib/omarchy/thunderbolt-authorization ]] ||
    fail "$label keeps the Thunderbolt authorization journal"
  [[ ! -e $root/var/lib/boltd/devices && ! -e $root/var/lib/boltd/keys && ! -e $root/var/lib/boltd/domains ]] ||
    fail "$label keeps Bolt enrollments"
  [[ $(awk -F= '/^[[:space:]]*AuthMode[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2 }' "$root/var/lib/boltd/boltd.conf") == "enabled" ]] ||
    fail "$label leaves Bolt authorizing stored devices"
  grep -qx 'SomeOther = keep' "$root/var/lib/boltd/boltd.conf" ||
    fail "$label rewrites unrelated Bolt settings"
}

top="$test_tmp/trusted"
mkdir -p "$top/@"
touch "$top/@/old-system"
make_accounts "$top/@factory"
plant_trust "$top/@factory"
bash "$test_tmp/reset" "$test_tmp" "$top" || fail "reset stages a snapshot that carries accessory trust"
assert_trust_cleared "$top/@" "the booted factory system"
assert_trust_cleared "$top/@factory" "the retained factory baseline"
[[ $(cat "$top/@factory/read-only") == "true" ]] || fail "baseline returns to read-only"
[[ ! -e $top/@/home/seller && -f $top/rebuilt ]] || fail "reset finishes account cleanup and boot rebuild"
pass "reset clears inherited USBGuard and Bolt trust in both roots"

rm -f "$top/rebuilt"
bash "$test_tmp/reset" "$test_tmp" "$top" || fail "reset can be repeated after accessory trust is gone"
assert_trust_cleared "$top/@" "a second booted factory system"
assert_trust_cleared "$top/@factory" "a second factory baseline"
pass "repeated reset leaves accessory trust cleared"

clean="$test_tmp/clean"
mkdir -p "$clean/@"
touch "$clean/@/old-system"
make_accounts "$clean/@factory"
bash "$test_tmp/reset" "$test_tmp" "$clean" || fail "reset stages a snapshot with no accessory trust"
[[ ! -e $clean/@/var/lib/boltd && ! -e $clean/@factory/var/lib/boltd ]] ||
  fail "reset invents a Bolt store the snapshot never had"
[[ ! -e $clean/@/usr/lib/systemd/system/usbguard.service ]] ||
  fail "reset invents a USBGuard unit the snapshot never had"
pass "reset leaves a snapshot without accessory trust untouched"

outside="$test_tmp/outside/devices"
mkdir -p "$outside"
printf 'keep\n' >"$outside/seller-dock"
linked="$test_tmp/linked"
mkdir -p "$linked/@"
touch "$linked/@/old-system"
make_accounts "$linked/@factory"
plant_trust "$linked/@factory"
rm -rf "$linked/@factory/var/lib/boltd"
ln -s "$test_tmp/outside" "$linked/@factory/var/lib/boltd"
if bash "$test_tmp/reset" "$test_tmp" "$linked"; then
  fail "reset accepted a Bolt store that points outside the snapshot"
fi
[[ -f $outside/seller-dock && $(cat "$outside/seller-dock") == "keep" ]] ||
  fail "reset follows a linked Bolt store and deletes the outside enrollment"
[[ -f $linked/@/old-system && ! -e $linked/rebuilt ]] ||
  fail "a linked Bolt store still activates the reset"
[[ $(cat "$linked/@factory/read-only") == "true" ]] ||
  fail "a linked Bolt store leaves the baseline writable"
pass "reset refuses a linked Bolt store before activation"
