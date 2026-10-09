#!/usr/bin/env bash
set -euo pipefail

env_file="$HOME/.config/ssh-gateway-proxy/proxy.env"
source_line='[ -r "$HOME/.config/ssh-gateway-proxy/proxy.env" ] && . "$HOME/.config/ssh-gateway-proxy/proxy.env"'

for profile in "$HOME/.profile" "$HOME/.bashrc"; do
    touch "$profile"
    if ! grep -qxF "$source_line" "$profile"; then
        printf '\n%s\n' "$source_line" >> "$profile"
    fi
done

chmod 600 "$env_file"
printf 'Remote proxy environment ready.\n'
