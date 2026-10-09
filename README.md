# SSH gateway proxy: cloud side

This branch contains the remote Linux-side setup for the SSH reverse proxy.
It configures login shells to use a loopback HTTP/HTTPS proxy created by the
Windows-side `local` branch.

## Files

- `remote-setup.sh`: loads the private proxy environment from `.profile` and
  `.bashrc`.
- `proxy.env.example`: documents the proxy variables written by the local
  installer. Replace the placeholder credentials before manual use.
- `codex-config.example.toml`: minimal Codex model-provider configuration.

## Install

The recommended installation method is running `GatewayProxy.ps1 -Action
Install` from the `local` branch. It generates a unique proxy password,
transfers the environment securely, and invokes `remote-setup.sh`.

For manual installation, create
`~/.config/ssh-gateway-proxy/proxy.env` with mode `600`, then run:

```bash
bash remote-setup.sh
```

Never commit a real proxy password, Codex `auth.json`, or API key.

