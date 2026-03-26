# Project Reference for Claude

## Overview
Ansible playbooks for ShowDropGo production infrastructure: a Mac Mini Unity Intercom server (HMO location) and a Vultr cloud VM relay. All devices connected via Tailscale VPN.

## Project Structure
```
showdropgo-infra/
├── ansible.cfg                              # roles_path, inventory, vault
├── CLAUDE.md                                # This file
├── inventory/
│   ├── hosts.yml                            # Host definitions
│   ├── group_vars/
│   │   ├── all/
│   │   │   ├── vars.yml                     # SSH keys, Cloudflare zone, tailscale_auth_key
│   │   │   └── vault.yml                    # ENCRYPTED: vault_cloudflare_api_token
│   │   ├── cloud_vms/
│   │   │   └── vars.yml                     # Tailscale defaults for cloud VMs
│   │   └── macos_hosts/
│   │       └── vars.yml                     # macOS group defaults
│   └── host_vars/
│       └── showdropgo-unityserver-macmini/
│           └── vars.yml                     # tailscale_ip, local_ip
├── playbooks/
│   ├── showdropgo-unityserver-macmini.yml   # Mac Mini full setup
│   ├── vultr.yml                            # Vultr VM setup
│   └── dns.yml                              # Cloudflare DNS management
└── roles/
    ├── base-cloud/                          # SSH hardening for cloud VMs
    ├── cloudflare-dns/                      # Cloudflare DNS record management
    ├── showdropgo-macos-apps/               # App installs (Homebrew + PKG)
    ├── tailscale/                           # Tailscale for Linux (Vultr)
    ├── tailscale-macos/                     # Tailscale for macOS (LaunchDaemon)
    ├── unity-local-relay/                   # Mac Mini local UDP/TCP relay (socat + Python)
    └── unity-relay/                         # Vultr iptables DNAT rules
```

## AI Assistant Guidelines

### Safety Rules
- **NEVER** decrypt, display, or modify vault files (`vault.yml`). These contain API tokens and auth keys.
- **NEVER** commit `.vault_pass` or any file containing plaintext secrets.
- **NEVER** modify `ansible.cfg` vault_password_file path without explicit request.

### Conventions
- Ansible runs from this directory: `cd /Users/robertstephen/showdropgo-infra`
- Ansible binary: `/Users/robertstephen/Library/Python/3.9/bin/ansible-playbook`
- All remote connections use Tailscale IPs (100.x.x.x) as `ansible_host`
- SSH key: `~/.ssh/id_ed25519` — always pass `--ssh-extra-args="-o IdentitiesOnly=yes"`
- `become: true` tasks require `--ask-become-pass` (no passwordless sudo configured)
- Tags match role names: `--tags relay`, `--tags tailscale`, etc.
- `launchctl load/unload` is deprecated on macOS 15 — use `bootstrap system` / `bootout system`

## Hosts

### macOS Hosts (macos_hosts group)
- **showdropgo-unityserver-macmini**: Mac Mini M1 at HMO
  - Tailscale IP: `100.98.252.10` (ansible_host)
  - Local LAN IP: `192.168.25.166`
  - User: `showdropgo-unity-01`
  - SSH key: `~/.ssh/id_ed25519`
  - Purpose: Runs Unity Intercom Server

### Cloud VMs (cloud_vms group)
- **vultr**: Debian 12 on Vultr
  - Tailscale IP: `100.110.89.127` (ansible_host)
  - Public IP: `45.32.202.94`
  - DNS: `unity.showdropgo.io → 45.32.202.94`
  - User: `root`
  - Purpose: Unity Intercom public relay
  - **Vultr Firewall Group** (`unity-relay`): TCP/UDP 20101, UDP 41641

## Playbooks

| Playbook | Target | Roles | Purpose |
|----------|--------|-------|---------|
| `showdropgo-unityserver-macmini.yml` | Mac Mini | tailscale-macos, showdropgo-macos-apps, unity-local-relay | Full Mac Mini setup |
| `vultr.yml` | Vultr | base-cloud, tailscale, unity-relay | SSH hardening + Tailscale + port forwarding |
| `dns.yml` | localhost | cloudflare-dns | Manage Cloudflare DNS records |

### Running Playbooks
```bash
# Standard run
/Users/robertstephen/Library/Python/3.9/bin/ansible-playbook playbooks/showdropgo-unityserver-macmini.yml \
  --ssh-extra-args="-o IdentitiesOnly=yes" --ask-become-pass

# Specific role only
/Users/robertstephen/Library/Python/3.9/bin/ansible-playbook playbooks/showdropgo-unityserver-macmini.yml \
  --tags relay --ssh-extra-args="-o IdentitiesOnly=yes" --ask-become-pass

# First-time via local IP (before Tailscale)
/Users/robertstephen/Library/Python/3.9/bin/ansible-playbook playbooks/showdropgo-unityserver-macmini.yml \
  -e "ansible_host=192.168.25.166" --ask-pass --ask-become-pass
```

## Unity Intercom Relay Architecture

Phone clients connect to `unity.showdropgo.io:20101`. Traffic flows:

```
Phone → Vultr:20101 (public) → DNAT → Mac Mini:20199 (Tailscale) → relay → Unity Intercom:20101 (LAN)
```

### Why the relay exists
Unity Intercom's UDP discovery only responds to RFC 1918 source IPs. Traffic arriving from Tailscale (100.x.x.x) is silently ignored. The local relay re-sources packets from the Mac Mini's LAN IP (`192.168.25.166`), making them appear local.

### Vultr side (`unity-relay` role)
- iptables DNAT: TCP/UDP `*:20101 → 100.98.252.10:20199`
- MASQUERADE on POSTROUTING for return traffic
- `unity_relay_target_port: 20199` in `hosts.yml` overrides the default

### Mac Mini side (`unity-local-relay` role)
- **TCP relay**: socat listening on `0.0.0.0:20199`, forwarding to `127.0.0.1:20101` (Unity TCP listens on all interfaces)
- **UDP relay**: Python script (`/usr/local/bin/unity-udp-relay.py`) with:
  - Listens on `0.0.0.0:20199` — no Tailscale IP dependency at startup
  - Dynamic LAN IP detection via `route -n get default` + `ipconfig getifaddr <iface>`
  - Outgoing socket bound to detected LAN IP — Unity only responds to RFC 1918 sources
  - Network change polling every 15s — detects subnet changes, clears sessions to rebind
  - Session tracking per client — required for keepalive continuity
  - Background listener thread per session — handles Unity proactive keepalives
  - 60s session timeout with cleanup loop
- Both run as macOS LaunchDaemons under `/Library/LaunchDaemons/`
- Logs: `/var/log/unity-relay-tcp.log`, `/var/log/unity-relay-udp.log`
- **Portable**: survives reboots, ISP changes, and moves to new subnets without reconfiguration

### Key variables
| Variable | Where set | Value |
|----------|-----------|-------|
| `unity_relay_target_ip` | `hosts.yml` (vultr) | `100.98.252.10` |
| `unity_relay_target_port` | `hosts.yml` (vultr) | `20199` |
| `unity_relay_ports` | `hosts.yml` (vultr) | `[20101]` |
| `unity_local_relay_listen_port` | `unity-local-relay/defaults` | `20199` |
| `unity_local_relay_target_port` | `unity-local-relay/defaults` | `20101` |
| `tailscale_ip` | `host_vars/showdropgo-unityserver-macmini` | `100.98.252.10` |
| `local_ip` | `host_vars/showdropgo-unityserver-macmini` | `192.168.25.166` |

## Roles

### base-cloud
- Sets hostname, deploys SSH keys from `admin_ssh_keys`
- Hardens SSH: disables password auth, configures root login policy
- Variables: `ssh_password_auth` (default: false), `ssh_permit_root_login` (default: prohibit-password), `cloud_ssh_user` (default: root)

### tailscale
- Installs Tailscale on Linux (Vultr) via official install script
- Interactive auth: displays login URL and waits

### tailscale-macos
- Installs Tailscale via Homebrew, deploys LaunchDaemon
- Uses `launchctl bootstrap system` (not deprecated `load`)
- Interactive or auth-key based authentication

### showdropgo-macos-apps
- Homebrew formulae: `cloudflared`
- Homebrew casks: `google-chrome`, `sonobus`, `amphetamine`, `loopback`
- PKG installers (place in `roles/showdropgo-macos-apps/files/`):
  - `unity-intercom.pkg`, `dante-virtual-soundcard.pkg`, `dante-via.pkg`

### unity-relay
- iptables DNAT for port forwarding on Vultr
- Installs `iptables-persistent`, enables IP forwarding

### unity-local-relay
- Installs socat via Homebrew
- Deploys Python UDP relay script to `/usr/local/bin/unity-udp-relay.py`
- Deploys LaunchDaemons for TCP (socat) and UDP (Python)
- Uses `launchctl bootstrap/bootout system` for service management

### cloudflare-dns
- Manages DNS records via Cloudflare API
- Uses `cloudflare_api_token` (from vault), `cloudflare_zone_id`, `cloudflare_zone`

## Mac Mini Bootstrap (fresh macOS install)

Before running Ansible:
1. Create user `showdropgo-unity-01` as Administrator
2. Enable SSH: System Settings → General → Sharing → Remote Login → On
3. Accept SSH fingerprint: `ssh-keyscan -H <local-ip> >> ~/.ssh/known_hosts`
4. Install Xcode CLT: `xcode-select --install`
5. Install Homebrew: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
6. Run Ansible with local IP: add `-e "ansible_host=192.168.25.166" --ask-pass`

## Troubleshooting

### SSH "Too many authentication failures"
Pass `--ssh-extra-args="-o IdentitiesOnly=yes"` to force use of the specified key only.

### LaunchDaemon service not starting (macOS 15)
Use `launchctl bootstrap system <plist>` instead of `launchctl load`. Check status with `launchctl print system/<label>`.

### UDP relay not working
- Confirm Python script is running as root: `launchctl print system/com.showdropgo.unity-relay-udp`
- Check detected LAN IP in logs: `tail /var/log/unity-relay-udp.log`
- Check Unity Intercom UDP binding: `sudo lsof -nP -iUDP:20101`
- Unity's UDP only responds to RFC 1918 sources — relay dynamically detects and binds to LAN IP

### UDP relay cycling / clients dropping
- Check logs for "Network change detected" — if firing too often, LAN may be unstable
- Check for "Could not bind outgoing socket" — LAN IP may have changed between session create and sendto
- Sessions are cleared on IP change; clients reconnect automatically within one poll cycle (15s)

### Vultr iptables rules
- Check: `iptables -t nat -L PREROUTING -n --line-numbers`
- Stale rules from old deploys may conflict — the `unity-relay` role clears managed ports before re-adding
- "Connection refused" when testing from Vultr to its own public IP is expected (hairpin NAT) — test from an external host

### Mac Mini moved to a new network
No action required. The UDP relay detects the new LAN IP within 15 seconds and all new sessions use the updated source IP. `local_ip` in `host_vars` is reference documentation only — it is not used by the relay at runtime.
