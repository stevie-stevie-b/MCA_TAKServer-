# MCA TAK Server

Deploys the official TAK Server (Docker release from tak.gov) onto **Oracle Cloud's Always Free tier in Sydney** using an Oracle Resource Manager stack (Terraform). Adapted from Empyrean Defense's AWS CloudFormation guide, [TAK Server on AWS: Zero to Operational](https://empyreandefense.com/insights/tak-server-aws-zero-to-operational/).

> **Status: untested.** Nothing here has been run against a real Oracle account or a real TAK release yet. The shell scripts pass `shellcheck`, but the Terraform has **not** been through `terraform validate`. Expect to fix small things on the first deploy.

## What you get

| Piece | Detail |
|---|---|
| Server | Ampere A1 (ARM), 4 OCPU, 24 GB RAM, 100 GB disk, Ubuntu 24.04. This uses the whole Always Free compute allowance. |
| Network | New VCN and public subnet. SSH (22) and admin UI (8443) open **only** to your IP. Client port 8089 open to `client_cidr` (default: everyone, but every connection needs a client certificate). 8446 closed by default. |
| TAK Server | Official Docker release, database and server containers, set to restart automatically. |
| Certificates | Your own CA, a server certificate for the public IP (or your DNS name), an `admin` certificate, and a random password instead of `atakatak`. |
| Phones | `tak-add-user.sh` makes a per-person certificate and an ATAK/iTAK connection data package. |

## Changes from the Empyrean AWS template

- **Sydney on Oracle** instead of four hard-coded US AWS regions. The Ubuntu image is looked up, not hard-coded.
- **Survives a reboot.** Containers restart automatically, and the database lives in a Docker volume. Oracle keeps the public IP through stop/start.
- **Database password set before the database is created.** The AWS template started the database first, then set the password.
- **Random certificate and database passwords** instead of `atakatak` and `martiuser`.
- **Server certificate matches the address clients use** (IP or DNS name). The AWS template used the name `takserver`.
- **Separate admin and client access.** Admin ports can't be opened to the whole internet.
- **No access to other storage.** The TAK zip comes from a single time-limited link, so the server never gets account-wide read access.
- **Fixes Oracle's host firewall.** Oracle's Ubuntu images block every port except 22 at the host. The stack opens the TAK ports.
- **Clean-up:** no Empyrean product certificate, and Australian certificate fields.

## Costs and Oracle catches

- **Home region must be Sydney.** Always Free compute only runs in your tenancy's home region, chosen at sign-up and fixed after. Pick **Australia East (Sydney)**.
- **Out of capacity.** Free A1 servers are often unavailable. If the apply fails with "Out of host capacity", re-run it later. Retrying at different times of day usually gets there.
- **Idle reclamation.** Oracle reclaims Always Free servers that sit near-idle for 7 days. A quiet TAK Server could qualify. Check Oracle's current Always Free terms for the thresholds. The fix is to **upgrade the account to Pay As You Go**: Always Free resources stay free, and reclamation stops. A card is required.
- **Set a budget alert** after upgrading (Billing → Budgets, e.g. $1 AUD with an email alert), so any accidental paid resource is caught.
- Everything in this stack is sized to fit inside the Always Free limits (4 OCPU / 24 GB A1, 200 GB block storage). Verify against Oracle's current limits before relying on that.

## Deploy

### 1. Before you start

1. **Oracle Cloud account** with Sydney as home region. Upgrade to Pay As You Go and set a budget alert (see above).
2. **TAK Server Docker release** from [tak.gov](https://tak.gov) → Products → TAK Server: the `takserver-docker-X.Y-RELEASE-NN.zip`. Note the SHA-256 checksum shown on tak.gov.
3. **SSH key.** If you don't have one: `ssh-keygen -t ed25519` and use the contents of `~/.ssh/id_ed25519.pub`.
4. **Your public IP** (search "what is my IP"). You'll enter it as `x.x.x.x/32`.

### 2. Put the TAK zip somewhere the server can fetch it (optional)

Skip this to copy the zip up by hand after the server boots (step 5).

1. Oracle console → **Storage → Buckets → Create bucket** (private, defaults are fine).
2. Upload the zip.
3. On the uploaded object: **⋮ → Create Pre-Authenticated Request**. Choose read access to the object, and set expiry to **1–2 days**.
4. Copy the URL. **It is only shown once.**

The link works for anyone who has it until it expires. Delete it (and the bucket) once the server is built.

### 3. Create the stack

1. Download this repo's `oracle` folder (or zip it).
2. Oracle console → **Developer Services → Resource Manager → Stacks → Create stack**.
3. **My configuration**, upload the `oracle` folder or zip, Terraform version 1.5 or later.
4. Fill in the variables:

| Variable | What to enter |
|---|---|
| `ssh_public_key` | Contents of your `.pub` file |
| `admin_cidr` | Your IP with `/32` |
| `client_cidr` | Leave `0.0.0.0/0` unless every device has a fixed IP or is on a VPN |
| `tak_zip_url` | Link from step 2, or blank |
| `server_hostname` | Optional DNS name (e.g. `tak.example.org.au`). Blank uses the IP. |
| `cert_*` | Your state, city and organisation (default NSW / Newcastle / TAK) |

5. **Create**, then **Apply**. Note the outputs: `public_ip`, `ssh_command`, `admin_url`.

If you set `server_hostname`, create a DNS A record pointing it at `public_ip` now.

### 4. Watch the install (10–20 minutes)

```bash
ssh ubuntu@<public_ip> 'sudo tail -f /var/log/tak-setup.log'
```

Wait for **"TAK Server … setup complete"**.

### 5. If you didn't use a link: copy the zip up

```bash
scp takserver-docker-*.zip ubuntu@<public_ip>:/tmp/
ssh ubuntu@<public_ip>
sudo mv /tmp/takserver-docker-*.zip /opt/tak-deploy/takserver.zip
sudo /opt/tak-deploy/tak-setup.sh 2>&1 | sudo tee -a /var/log/tak-setup.log
```

### 6. Log in to the admin UI

```bash
scp ubuntu@<public_ip>:tak-certs/admin.p12 .
ssh ubuntu@<public_ip> 'sudo cat /root/tak-secrets.env'    # CERT_PASS is the certificate password
```

Import `admin.p12` into your browser or OS certificate store using `CERT_PASS`, then open `https://<public_ip>:8443`. Expect a certificate warning the first time, because the server uses your own CA.

### 7. Add phones

```bash
ssh ubuntu@<public_ip>
sudo /opt/tak-deploy/tak-add-user.sh jsmith            # optional 2nd argument: group name
exit
scp ubuntu@<public_ip>:tak-certs/jsmith-<public_ip>.zip .
```

On the device: **ATAK → Import → Local SD** (or iTAK → Servers → + → Upload Server Package), and pick the zip. The device should connect straight away.

**Treat each zip like a password.** It holds that person's certificate and the certificate password. Hand it over in person or by USB where you can, and delete copies afterwards. Don't email them or leave them on shared drives.

## Running it

| Task | How |
|---|---|
| Stop / start | Oracle console → Compute → Instances → Stop / Start. TAK comes back on its own, and the public IP stays the same. |
| Status | `sudo docker ps` and `sudo docker logs takserver` |
| Logs | `/opt/takserver/takserver-docker-*/tak/logs/` |
| Restart TAK | `sudo docker compose -f /opt/takserver/docker-compose.yml restart` |
| Your IP changed | Edit the stack's `admin_cidr` → Apply. This only updates the firewall rule. |
| Back up | Oracle console → Boot volume → Create backup. The Always Free tier includes a few backups. |
| Tear down | Resource Manager → stack → **Destroy**. This deletes the server and all its data. |

**Where things live on the server:** `/opt/takserver/` holds the release, `CoreConfig.xml` and certificates (`tak/certs/files/`). `/root/tak-secrets.env` holds the passwords, and `/etc/tak-deploy.env` holds the setup settings.

### Changing the server address later

Certificates and data packages are tied to the IP or name the server was built with. To move to a DNS name later, you need to:

- make a new server certificate (`makeCert.sh server <name>` in the container),
- point `keystoreFile` in `CoreConfig.xml` at it,
- restart, and
- reissue the data packages.

Setting `server_hostname` from the start avoids this.

## Next steps (from the Empyrean guide's hardening section)

1. **VPN in front of 8089** (WireGuard, Tailscale or ZeroTier). Then set `client_cidr` to the VPN range so nothing faces the internet.
2. **Revocation process.** Know how to revoke a lost phone's certificate before you need to (TAK Server configuration guide, "Certificate revocation").
3. **Off-server logs and alerts.** Oracle's Logging and Monitoring services have free allowances.
4. **Patching.** `sudo apt update && sudo apt upgrade` monthly. Watch tak.gov for new TAK releases.

## Running on your own hardware instead

The scripts in `oracle/scripts/` work on any Ubuntu machine (ARM or x86) with Docker:

```bash
sudo apt install docker.io docker-compose-v2 unzip zip curl openssl
sudo mkdir -p /opt/tak-deploy && sudo cp oracle/scripts/*.sh /opt/tak-deploy/
sudo cp takserver-docker-*.zip /opt/tak-deploy/takserver.zip
# Optional: put SERVER_HOSTNAME=... and CERT_* settings in /etc/tak-deploy.env
sudo /opt/tak-deploy/tak-setup.sh
```

Skip `open-host-firewall.sh` unless the machine uses Oracle's firewall rules. Forward or allow TCP 8089 (and 8443 from admin machines only) on your router or firewall. The scripts assume an `ubuntu` user for the `~/tak-certs` copy. Adjust `CERT_OUT` in both scripts if yours differs.

## Files

```
oracle/
  main.tf                  network, firewall rules, A1 server
  variables.tf             stack inputs
  outputs.tf               IP, SSH and URLs
  cloud-init.yaml.tftpl    first-boot: packages, firewall, run setup
  scripts/
    tak-setup.sh           build images, config, certs, start TAK
    tak-add-user.sh        per-device certificate + data package
    open-host-firewall.sh  open TAK ports in Oracle's host firewall
```
