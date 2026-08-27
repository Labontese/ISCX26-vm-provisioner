# new-vm.sh — Proxmox Ubuntu VM provisioner

Interactive script that clones a cloud-init Ubuntu template into a fully
configured VM: static IP, a user with your SSH key already trusted, an
optional "lab type" package set, and optional Tailscale / Cloudflare Tunnel
integration. Run it, answer a few prompts, get a ready-to-SSH-into VM.

It has no hard dependency on any particular router or DNS setup — it finds a
free IP with a simple ping sweep by default. If you run pfSense/OPNsense (or
anything else with an API), there's an optional hook to wire up automatic
DHCP reservations too, but the script works fine without it.

## Prerequisites

1. **Proxmox VE**, run the script directly on the host (`ssh root@your-host`).
2. **At least one cloud-init-enabled Ubuntu template.** If you don't have one
   yet:
   ```bash
   # Example: Ubuntu 24.04 cloud image as template 9000
   wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
   qm create 9000 --name ubuntu-2404-cloudinit --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
   qm importdisk 9000 noble-server-cloudimg-amd64.img local-lvm
   qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
   qm set 9000 --ide2 local-lvm:cloudinit
   qm set 9000 --boot c --bootdisk scsi0
   qm set 9000 --serial0 socket --vga serial0
   qm template 9000
   ```
   Repeat per Ubuntu version you want available, then point `TEMPLATE_n_ID`
   in the config block at the IDs you used.
3. **A storage pool and bridge** already set up (`local-lvm` and `vmbr0` are
   Proxmox's defaults — change them in the config if yours differ).
4. **Your own SSH public key** in `/root/.ssh/authorized_keys` on the Proxmox
   host. The script copies every key listed there into each new VM's
   `cloud-init` config, so whatever's authorized for root on the host becomes
   authorized on every VM it creates.

Everything else (Tailscale, Cloudflare Tunnel, router integration) is
optional — skip a section below if you don't need it.

## Setup

1. Copy `new-vm.sh` to your Proxmox host and `chmod +x` it.
2. Open it and edit the **CONFIGURATION** block near the top:

   | Variable | What to set it to |
   |---|---|
   | `TARGET_STORAGE` | Your storage pool name (`pvesm status` to list them) |
   | `BRIDGE` | Your Linux bridge (`ip link` to list them) |
   | `DNS_SERVER` | DNS server new VMs should use |
   | `TEMPLATE_n_ID` / `TEMPLATE_n_LABEL` | The template IDs from the prerequisite step |
   | `IFACE_PREFIX` / `IFACE_GW` | One entry per subnet/VLAN you want to offer — `[name]="192.168.1"` and `[name]="192.168.1.1"` |
   | `IP_SCAN_RANGE_START` / `_END` | The range the ping sweep checks for a free address |

3. That's it for a minimal setup — run it:
   ```bash
   bash new-vm.sh
   ```

## Optional: Tailscale

Create a **reusable** auth key at
https://login.tailscale.com/admin/settings/keys and save it as plain text at
the path in `TAILSCALE_AUTHKEY_FILE` (default `/root/.tailscale-authkey`).
If that file doesn't exist, the script silently skips Tailscale — nothing
else to configure.

## Optional: Cloudflare Tunnel exposure

Only relevant if you want the script to offer "expose this VM publicly"
at the end. Create a file at the path in `CF_SECRETS_FILE` (default
`/root/.vm-secrets`) containing:

```bash
CF_DOMAIN=example.com
CF_ACCOUNT_ID=your-account-id
CF_TUNNEL_ID=your-tunnel-id
CF_ZONE_ID=your-zone-id
CF_API_TOKEN=your-api-token
```

The API token needs **Cloudflare Tunnel: Edit** and **DNS: Edit** permission
for the zone — a token with only *Read* access will fail silently on the
write step (the script will print Cloudflare's actual error message if this
happens, so you'll know exactly what's missing).

If `CF_SECRETS_FILE` doesn't exist or doesn't set `CF_API_TOKEN`, the whole
Cloudflare section is skipped and never prompted for.

## Optional: router integration for IP assignment

By default the script finds a free IP with a plain ping sweep
(`IP_SCAN_RANGE_START` to `IP_SCAN_RANGE_END`) — good enough for most home
labs, but it can occasionally suggest an address that's reserved-but-quiet
(e.g. a powered-off device).

If you want something more accurate, set `PFSENSE_HOST` and implement two
tiny endpoints on your router that the script expects:

- `find-next-ip.php <interface> <subnet-prefix>` → prints a free IP and exits
- `add-dhcp-reservation.php <interface> <mac> <ip> <hostname>` → registers
  the reservation

These aren't included since every router setup differs — pfSense/OPNsense
both also expose REST APIs you could call directly instead of writing PHP.
Leave `PFSENSE_HOST` blank to ignore this entirely; the ping sweep is used
and DHCP reservation is silently skipped.

## Security notes

- The VM's password is **only ever stored as a SHA-512 hash** inside the
  cloud-init `user-data` — the script deliberately does **not** use Proxmox's
  `qm set --cipassword`, which stores the password in cleartext in the VM's
  config file (`qm config <vmid>`). If you're adapting this script further,
  keep it that way.
- SSH access to new VMs is key-based from the moment they boot (copied from
  the host's `authorized_keys`) — there's no need to ever type the password
  over SSH, only via the Proxmox console if something goes wrong with
  cloud-init.
- Consider disabling password authentication over SSH entirely on the
  resulting VMs once you've confirmed key-based login works
  (`PasswordAuthentication no` in `/etc/ssh/sshd_config`).

## What each numbered step does

| Step | Action |
|---|---|
| 1–2 | Pick Ubuntu version + target subnet |
| 3 | Find a free IP (ping sweep or router API) |
| 4 | Ask for VM name, user, password, size, lab type |
| 5 | Auto-pick a free VMID starting from 200 |
| 6–9 | Clone the template, resize the disk, attach the bridge, enable snippet storage |
| 10–12 | Write cloud-init `user-data` + `network-data`, attach both to the VM |
| 13 | Optional DHCP reservation on your router |
| 14 | Snapshot named `clean` — `qm rollback <vmid> clean` undoes everything |
| 15 | Boot the VM |
| 16 | Optional Cloudflare Tunnel exposure |

## Troubleshooting

- **"Template N doesn't exist"** — the `TEMPLATE_n_ID` values don't match a
  real template on this host. Run `qm list` to see what's actually there.
- **Ping sweep finds nothing free** — widen `IP_SCAN_RANGE_START`/`_END`, or
  your subnet really is full.
- **Cloudflare step prints an error message** — that's deliberate; the
  script surfaces Cloudflare's own error text instead of hiding it, so read
  it (usually a permissions issue with the token).
- **New VM unreachable over SSH right after boot** — cloud-init can take
  10–30 seconds after the VM reports "started." Give it a moment.
