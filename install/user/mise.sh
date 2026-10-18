# Build the lazy shims for Omarchy's default tools and the account dispatchers,
# both declared by /etc/mise/conf.d. Cursor stays off this list: its installer
# is the official tarball, not a mise tool.
mise reshim --system
mise reshim
