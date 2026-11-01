# Build the lazy shims for Omarchy's default tools and the account dispatchers,
# both declared by /etc/mise/conf.d, without resolving versions over the network.
# Cursor stays off this list: its installer is the official tarball, not a mise tool.
MISE_OFFLINE=true mise reshim --system
MISE_OFFLINE=true mise reshim
