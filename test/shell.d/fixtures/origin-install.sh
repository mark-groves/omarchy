#!/bin/sh
CHANNEL="${ORIGIN_INSTALL_CHANNEL:-${CO_INSTALL_CHANNEL:-stable}}"
case "$CHANNEL" in
latest)
  version="2026.09.10-22-25-12-9621f10"
  case "$platform" in
  linux-arm64)
    url="https://downloads.cursor.com/co/2026.09.10-22-25-12-9621f10/linux-arm64/co.tar.gz"
    sha="e272ee203d135a74732767146645b2f7833ea53199128b73b60ef1926422347d"
    ;;
  linux-x64)
    url="https://downloads.cursor.com/co/2026.09.10-22-25-12-9621f10/linux-x64/co.tar.gz"
    sha="fee4589559a4f21fba9593171101065b5bee4a44e030debc52acdf8f5f04c934"
    ;;
  esac
  ;;
stable)
  version="2026.09.08-22-50-39-8f6b2f8"
  case "$platform" in
  linux-arm64)
    url="https://downloads.cursor.com/co/2026.09.08-22-50-39-8f6b2f8/linux-arm64/co.tar.gz"
    sha="1ac0ea8d265af3a9d592f939f9a2f88fa706d8a874aa4db6413dcc1af15e786f"
    ;;
  linux-x64)
    url="https://downloads.cursor.com/co/2026.09.08-22-50-39-8f6b2f8/linux-x64/co.tar.gz"
    sha="044950b64be360a9837084689b3cc579ecc091c02389494968b988b5e9c3ced7"
    ;;
  esac
  ;;
esac
