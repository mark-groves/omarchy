echo "Pin howdy-compare to one CPU on hosts that already use face"

# Face setup now pins howdy-compare and installs a pacman hook that keeps the
# pin across howdy-next upgrades. Hosts that enabled face before this change
# still run compare unpinned, or through an earlier hand-written wrapper that
# drops root under sudo, until Setup Face runs again. Apply the pin for them.
sudo_pam=/etc/pam.d/sudo
compare=/usr/lib/howdy/howdy-compare
hook=/etc/pacman.d/hooks/omarchy-howdy-compare.hook

[[ -f $sudo_pam ]] && grep -q pam_howdy.so "$sudo_pam" || exit 0
[[ -e $compare ]] || exit 0

# Migration state is per-user. The -p wrapper and the hook are the machine-wide
# state, so a second account finds the pin in place and exits without a prompt.
if [[ -f $hook ]] && [[ $(head -n1 "$compare") == "#!/bin/bash -p" ]]; then
  exit 0
fi

sudo "$OMARCHY_PATH/bin/omarchy-apply-howdy-compare" install
