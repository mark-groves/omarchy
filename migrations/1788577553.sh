echo "Skip the upstream Cursor CLI mise wrapper"

# This fork installs Cursor Agent from Cursor's official Linux tarball
# (omarchy-install-cursor-agent) when it is chosen as the default agent.
# The mise wrapper would sit on PATH and look installed while still being a
# stub, so we do not write one here.
