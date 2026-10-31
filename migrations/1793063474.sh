echo "Stop howdy-compare running user-writable Omarchy code as root"

# Face setup used to wrap howdy-compare in a script that ran
# omarchy-face-auth-signal from the Omarchy tree named in /etc/omarchy.conf,
# as root and before authentication, on every sudo and lock scan. On a linked
# checkout that tree is user-writable, so any program running as the user could
# get root on the next sudo. Its pacman hook ran the same tree as root on every
# howdy-next upgrade. Install now writes a wrapper that only pins compare and
# retires the hook.
compare=/usr/lib/howdy/howdy-compare
hook=/etc/pacman.d/hooks/omarchy-howdy-compare.hook

# Migration state is per-user. Once one account has repaired the machine, the
# next finds neither and exits without a prompt.
if ! grep -Fqs 'omarchy-face-auth-signal' "$compare" && [[ ! -e $hook && ! -L $hook ]]; then
  exit 0
fi

# Install still refuses a compare slot it cannot pin (a missing .real), but
# only after it has retired the hook and replaced the signalling wrapper. Done
# means that hole is closed, not that compare is pinned.
sudo "$OMARCHY_PATH/bin/omarchy-apply-howdy-compare" install || true

if grep -Fqs 'omarchy-face-auth-signal' "$compare" || [[ -e $hook || -L $hook ]]; then
  echo "howdy-compare still runs Omarchy code as root. Run: sudo $OMARCHY_PATH/bin/omarchy-apply-howdy-compare install" >&2
  exit 1
fi
