echo "Fire the IR emitter before every face scan on hosts that already use face"

# Face setup now installs an emitter helper and writes a gate, emitter, module
# triple around pam_howdy.so. Hosts that enabled face before this change keep
# the old pair and scan an unlit camera until Setup Face runs again. Re-run the
# setup for them; it is idempotent on every file it writes.
sudo_pam=/etc/pam.d/sudo
lock_pam=/etc/pam.d/omarchy-lock-face
polkit_pam=/etc/pam.d/polkit-1
emitter_helper=/usr/local/bin/omarchy-hw-ir-emitter
howdy_module=/usr/lib/security/pam_howdy.so

face_configured=0
for pam_file in "$sudo_pam" "$lock_pam" "$polkit_pam"; do
  if [[ -f $pam_file ]] && grep -q pam_howdy.so "$pam_file"; then
    face_configured=1
  fi
done
(( face_configured )) || exit 0

# Setup Face needs the Howdy module. A host that removed howdy-next but kept the
# PAM lines has nothing to light, and a failing setup would block the queue.
[[ -f $howdy_module ]] || exit 0

# Migration state is per-user. The emitter line in the sudo stack and the helper
# on disk are the machine-wide state, so a second account finds the repair done
# and exits without a password prompt.
if [[ -x $emitter_helper ]] && grep -q omarchy-hw-ir-emitter "$sudo_pam" 2>/dev/null; then
  exit 0
fi

sudo "$OMARCHY_PATH/bin/omarchy-setup-security-face"
