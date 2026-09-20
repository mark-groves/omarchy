echo "Pin howdy-compare to one CPU on hosts that already use face"

# Face setup now pins howdy-compare and installs a pacman hook that keeps the
# pin across howdy-next upgrades. Hosts that enabled face before this change
# still run compare unpinned, or through an earlier hand-written wrapper that
# drops root under sudo, until Setup Face runs again. Apply the pin for them.
# Every surface runs the same compare, so any face stack qualifies; the pin
# itself touches no PAM file.
sudo_pam=/etc/pam.d/sudo
lock_pam=/etc/pam.d/omarchy-lock-face
polkit_pam=/etc/pam.d/polkit-1
compare=/usr/lib/howdy/howdy-compare
hook=/etc/pacman.d/hooks/omarchy-howdy-compare.hook

face_anywhere=0
for pam_file in "$sudo_pam" "$lock_pam" "$polkit_pam"; do
  if [[ -f $pam_file ]] && grep -q pam_howdy.so "$pam_file"; then
    face_anywhere=1
  fi
done
(( face_anywhere )) || exit 0
[[ -e $compare ]] || exit 0

# Migration state is per-user. The -p wrapper and the hook are the machine-wide
# state, so a second account finds the pin in place and exits without a prompt.
if [[ -f $hook ]] && [[ $(head -n1 "$compare") == "#!/bin/bash -p" ]]; then
  exit 0
fi

sudo "$OMARCHY_PATH/bin/omarchy-apply-howdy-compare" install
