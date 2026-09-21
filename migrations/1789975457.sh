echo "Quiet OpenCV face-scan warnings and show the face card for sudo"

# howdy-compare prints DNN graph-engine WARN lines on every scan, and terminal
# sudo has no FaceChrome surface. The compare wrapper now sets
# OPENCV_LOG_LEVEL=ERROR and signals the host overlay. Hosts that already
# pinned compare still run the old exec wrapper until Setup Face runs again.
sudo_pam=/etc/pam.d/sudo
lock_pam=/etc/pam.d/omarchy-lock-face
polkit_pam=/etc/pam.d/polkit-1
compare=/usr/lib/howdy/howdy-compare

face_anywhere=0
for pam_file in "$sudo_pam" "$lock_pam" "$polkit_pam"; do
  if [[ -f $pam_file ]] && grep -q pam_howdy.so "$pam_file"; then
    face_anywhere=1
  fi
done
(( face_anywhere )) || exit 0
[[ -e $compare ]] || exit 0

# Migration state is per-user. The wrapper is machine-wide, so a second
# account finds the new pin and exits without a prompt.
if [[ -f $compare ]] && grep -Fq 'OPENCV_LOG_LEVEL=ERROR' "$compare" && grep -Fq 'omarchy-face-auth-signal' "$compare"; then
  exit 0
fi

sudo "$OMARCHY_PATH/bin/omarchy-apply-howdy-compare" install
