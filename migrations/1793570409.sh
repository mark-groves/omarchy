echo "Keep howdy-compare pinned to one CPU across howdy-next upgrades"

# The hook that re-pinned compare after each howdy-next upgrade ran Omarchy
# code as root, so it was retired with nothing in its place: the next upgrade
# restores the unpinned compare, which its own CPU-time cap kills mid-scan on
# many-core machines. Install now also writes a pin hook that runs only
# /usr/bin tools. Every surface runs the same compare, so any face stack
# qualifies.
compare=/usr/lib/howdy/howdy-compare
pin_hook=/etc/pacman.d/hooks/omarchy-howdy-compare-pin.hook

face_anywhere=0
for pam_file in /etc/pam.d/sudo /etc/pam.d/omarchy-lock-face /etc/pam.d/polkit-1; do
  if [[ -f $pam_file ]] && grep -q pam_howdy.so "$pam_file"; then
    face_anywhere=1
  fi
done
(( face_anywhere )) || exit 0

# Migration state is per-user. The hook is the machine-wide state, and it pins
# any vendor compare the next howdy-next install brings, so a second account
# that finds it and no unpinned compare exits without a prompt.
if [[ -f $pin_hook ]] && [[ $(head -c 4 "$compare" 2>/dev/null) != $'\x7fELF' ]]; then
  exit 0
fi

# Install writes the hook before it looks at compare, so a slot it cannot pin
# now (it says why) still gets pinned by the next howdy-next install, and this
# migration does not hold every later update back. Only a missing hook, such
# as a refused sudo prompt, leaves it pending.
sudo "$OMARCHY_PATH/bin/omarchy-apply-howdy-compare" install || true

if [[ ! -f $pin_hook ]]; then
  echo "The howdy-compare pin hook is missing. Run: sudo $OMARCHY_PATH/bin/omarchy-apply-howdy-compare install" >&2
  exit 1
fi
