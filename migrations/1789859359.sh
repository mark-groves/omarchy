echo "Fire the IR emitter before every face scan on hosts that already use face"

# Face setup now installs an emitter helper and writes a gate, emitter, module
# triple around pam_howdy.so. Hosts that enabled face before this change keep
# the old pair and scan an unlit camera until each stack is rewritten. Upgrade
# only the surfaces that already carry face; a surface without pam_howdy.so
# stays as the user left it.
sudo_pam=/etc/pam.d/sudo
lock_pam=/etc/pam.d/omarchy-lock-face
polkit_pam=/etc/pam.d/polkit-1
emitter_helper=/usr/local/bin/omarchy-hw-ir-emitter
howdy_module=/usr/lib/security/pam_howdy.so

has_face() {
  [[ -f $1 ]] && grep -q pam_howdy.so "$1"
}

lacks_emitter() {
  ! grep -q omarchy-hw-ir-emitter "$1"
}

face_anywhere=0
for pam_file in "$sudo_pam" "$lock_pam" "$polkit_pam"; do
  if has_face "$pam_file"; then
    face_anywhere=1
  fi
done
(( face_anywhere )) || exit 0

# A host that removed howdy-next but kept the PAM lines has nothing to light.
[[ -f $howdy_module ]] || exit 0

# Migration state is per-user. The files themselves are the machine-wide state,
# so a second account finds every surface done and exits without a prompt.
pending=0
[[ -x $emitter_helper ]] || pending=1
for pam_file in "$sudo_pam" "$lock_pam" "$polkit_pam"; do
  if has_face "$pam_file" && lacks_emitter "$pam_file"; then
    pending=1
  fi
done
(( pending )) || exit 0

# PAM runs the helper by absolute path on every surface, and the polkit helper's
# sandbox hides /home, so the copy lives outside the checkout. Rename a fresh
# copy over the path rather than writing in place.
if [[ ! -x $emitter_helper ]]; then
  echo "  Installing the IR emitter helper..."
  sudo mkdir -p "$(dirname "$emitter_helper")"
  stage=$(sudo mktemp "$emitter_helper.new.XXXXXX")
  sudo install -T -m 755 "$OMARCHY_PATH/bin/omarchy-hw-ir-emitter" "$stage"
  sudo mv -Tf "$stage" "$emitter_helper"
fi

if has_face "$sudo_pam" && lacks_emitter "$sudo_pam"; then
  echo "  Upgrading the sudo face stack..."
  sudo "$OMARCHY_PATH/bin/omarchy-pam-pair-add" "$sudo_pam" pam_howdy.so
fi

if has_face "$polkit_pam" && lacks_emitter "$polkit_pam"; then
  echo "  Upgrading the polkit face stack..."
  sudo "$OMARCHY_PATH/bin/omarchy-apply-polkit-pam"
fi

# The same file Setup Face writes. A test holds the two copies together.
if has_face "$lock_pam" && lacks_emitter "$lock_pam"; then
  echo "  Upgrading the lock screen face stack..."
  stage=$(sudo mktemp "$lock_pam.new.XXXXXX")
  sudo tee "$stage" >/dev/null <<'EOF'
#%PAM-1.0
auth       optional                    pam_exec.so quiet /usr/local/bin/omarchy-hw-ir-emitter
auth       required                    pam_howdy.so
account    include                     system-local-login
EOF
  sudo chmod 644 "$stage"
  sudo mv -Tf "$stage" "$lock_pam"
fi
