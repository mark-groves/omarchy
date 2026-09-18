echo "Install Elsewhen, the world clock plugin"

# Elsewhen ships as the elsewhen package rather than in this checkout; pacman
# puts it under /usr/share/omarchy/plugins, where the shell looks next to its
# bundled plugins. A package the mirror does not carry yet fails the migration
# on purpose: nothing before this line has changed anything, and the runner
# retries it on the next update or login rather than quietly leaving the
# machine without the plugin.
omarchy-pkg-add elsewhen

# A shell that already knows the packaged root (dev-linked, or restarted
# since) picks the plugin up here; the one an update runs under predates it
# and is replaced by omarchy-update-restart right after the migrations.
omarchy-shell -q shell rescanPlugins || true

# Before the package, the README had users run
# `omarchy plugin add https://github.com/omacom/elsewhen.git`, which left a
# git clone under ~/.config/omarchy/plugins. The packaged copy now shadows
# it: the shell logs a rejection on every scan, and `omarchy plugin update`
# keeps pulling a checkout nothing loads. A pristine clone of the upstream
# repo is retired the way `omarchy plugin remove` retires one (the repo
# remains upstream). Anything else -- a symlink, a plain directory, local
# changes, a fork, a checkout git cannot read -- is the user's and stays. This
# runs only once the package is in place, so the plugin never leaves a
# machine; its id stays in shell.json either way, which is what keeps it
# enabled. The shell an update runs under predates the packaged root, and it
# watches this directory: dropping the checkout empties the widget's slot in
# that shell until omarchy-update-restart replaces it a few steps later with
# one that finds the package. A one-time gap of a few minutes, during the
# update itself.
upstream_checkout() {
  local dir="$1" origin status
  [[ -d $dir && ! -L $dir && -d $dir/.git ]] || return 1
  origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  origin=${origin,,}
  origin=${origin%/}
  origin=${origin%.git}
  [[ $origin =~ ^([a-z+]+://)?([^/@]+@)?github\.com[/:]omacom/elsewhen$ ]] || return 1
  status=$(git -C "$dir" status --porcelain 2>/dev/null) || return 1
  [[ -z $status ]]
}

checkout="$HOME/.config/omarchy/plugins/omacom.elsewhen"
if [[ -e $checkout || -L $checkout ]]; then
  if upstream_checkout "$checkout"; then
    rm -rf "$checkout"
    echo "Retired the omacom.elsewhen checkout at $checkout in favour of the elsewhen package."
  else
    echo "The elsewhen package takes precedence over $checkout, which is left as it is."
  fi
fi

# The widget sits just before the clock in the center of the default bar,
# which a machine without a shell.json takes on as soon as the shell
# restarts. A customized bar gets the entry written into its file rather than
# placed over IPC: the shell this runs under cannot see a widget its scan
# never reached and would refuse it, whereas the file it hot-reloads carries
# the entry through to the restart. A bar that already carries the widget
# keeps it where the user put it.
source omarchy-shell-config

[[ -s $CONFIG_FILE ]] || exit 0
# A file the shell cannot read is left for its owner to repair.
jq empty "$CONFIG_FILE" 2>/dev/null || exit 0

entry_id='def entry_id: if type == "object" then (.id // "" | tostring) else tostring end;'

if jq -e "$entry_id"'
  any((.bar.layout // {} | .left, .center, .right | arrays)[]; entry_id == "omacom.elsewhen")
' "$CONFIG_FILE" >/dev/null; then
  exit 0
fi

commit "$NORMALIZE | $entry_id"'
  def ids: map(entry_id);
  def insert_at($section; $index):
    .bar.layout[$section] = .bar.layout[$section][:$index] + [{id: "omacom.elsewhen"}] + .bar.layout[$section][$index:];
  . as $config
  | (["left", "center", "right"] | map(select($config.bar.layout[.] | ids | index("omarchy.clock") != null)) | first) as $section
  | if $section != null then
      insert_at($section; .bar.layout[$section] | ids | index("omarchy.clock"))
    else
      insert_at("center"; 0)
    end
'
