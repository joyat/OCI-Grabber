# oci-a1-grabber

**Grab Oracle Cloud A1.Flex Free Tier VMs automatically.**

Oracle's Always Free tier offers an incredibly generous ARM VM (up to 4 OCPUs, 24 GB RAM) — but getting one is nearly impossible in popular regions due to perpetual "Out of host capacity" errors. This tool retries instance creation across all availability domains until a slot opens up.

## Why this tool?

There are several OCI retry scripts on GitHub (shout-out to [hitrov/oci-arm-host-capacity](https://github.com/hitrov/oci-arm-host-capacity), [isac322/get_oracle_a1](https://github.com/isac322/get_oracle_a1), and [mohankumarpaluru/oracle-freetier-instance-creation](https://github.com/mohankumarpaluru/oracle-freetier-instance-creation)). This one was born from a real multi-day attempt to get an ARM instance in Frankfurt and addresses gaps we found in existing tools:

| Feature | oci-a1-grabber | hitrov (PHP) | isac322 (Python) |
|---|---|---|---|
| Pre-flight checks (auth, subnet, image, SSH, duplicates) | ✅ | ❌ | ❌ |
| Auto-heals deprecated images | ✅ | ❌ | ✅ |
| Error classification (capacity vs config vs rate-limit) | ✅ | ❌ | ❌ |
| Rate limit detection + auto-backoff | ✅ | ❌ | ❌ |
| `--no-retry` flag (7s calls instead of 90s+) | ✅ | N/A | N/A |
| Rotates through multiple sizes (4/24 → 2/12 → 1/6) | ✅ | ❌ | ✅ |
| Auto-discovers all availability domains | ✅ | ❌ | ✅ |
| Periodic auth re-validation | ✅ | ❌ | ❌ |
| Log rotation | ✅ | ❌ | N/A |
| macOS notification + voice alert | ✅ | ❌ | ❌ |
| Telegram notifications | ✅ | ❌ | ❌ |
| Interactive setup wizard | ✅ | ❌ | ❌ |
| Zero dependencies (just bash + OCI CLI) | ✅ | PHP + Composer | Python + Docker |

## Quick start

### 1. Install OCI CLI

```bash
# macOS
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

# Linux
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

Then configure it:

```bash
oci setup config
```

You'll need your Tenancy OCID, User OCID, and to upload the generated API key to Oracle Console → Profile → API Keys.

### 2. Install oci-a1-grabber

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/oci-a1-grabber/main/oci-a1-grabber.sh -o ~/bin/oci-a1-grabber
chmod +x ~/bin/oci-a1-grabber
```

Or clone the repo:

```bash
git clone https://github.com/YOUR_USERNAME/oci-a1-grabber.git
cd oci-a1-grabber
chmod +x oci-a1-grabber.sh
ln -s "$(pwd)/oci-a1-grabber.sh" ~/bin/oci-a1-grabber
```

### 3. Run setup

```bash
oci-a1-grabber setup
```

The interactive wizard walks you through configuring your tenancy, subnet, image, SSH key, and notification preferences. Config is saved to `~/.oci-a1-grabber.conf`.

### 4. Start grabbing

```bash
# Run in background (recommended)
oci-a1-grabber --background

# Or run in foreground
oci-a1-grabber
```

### 5. Monitor

```bash
# Check status
oci-a1-grabber status

# Tail the log
tail -f ~/oci-a1-grabber.log

# Stop
oci-a1-grabber stop
```

### 6. Connect

When a VM is grabbed, you'll get a macOS notification (with voice!) and the connection details are saved:

```bash
~/oci-connect.sh
```

## How it works

```
┌─────────────┐
│  Pre-flight  │  Validates auth, subnet, image, SSH key
│   checks     │  Auto-heals deprecated images
└──────┬───────┘  Detects existing instances
       │
       ▼
┌─────────────┐
│  Retry loop  │  Rotates: 4/24GB → 2/12GB → 1/6GB
│              │  Tries all availability domains
│  ~60-90s     │  Uses --no-retry for fast 7s API calls
│  per cycle   │  Random jitter to avoid rate limits
└──────┬───────┘
       │
       ├── Capacity error → retry (expected)
       ├── Rate limited → back off 120s
       ├── Config error → stop after 3 consecutive
       └── Success → notify + save SSH command
```

## Configuration

The config file (`~/.oci-a1-grabber.conf`) is created by the setup wizard. You can also edit it directly:

```bash
# Required
TENANCY="ocid1.tenancy.oc1..aaaa..."
SUBNET="ocid1.subnet.oc1..aaaa..."
IMAGE=""                              # Auto-detected if empty
SSH_KEY="~/.ssh/id_ed25519.pub"

# Instance config
DISPLAY_NAME="a1-free"
OCPUS="4"                            # Max free: 4
MEMORY="24"                           # Max free: 24

# Retry timing
WAIT_MIN="60"                         # Min seconds between attempts
WAIT_MAX="90"                         # Max seconds between attempts

# Features
TRY_MULTIPLE_SIZES="true"            # Rotate 4/24 → 2/12 → 1/6
NO_RETRY_FLAG="true"                  # Fast API calls (recommended)

# Notifications
NOTIFY_MACOS="true"
NOTIFY_TELEGRAM="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
```

## CLI flags

All config values can be overridden via CLI:

```bash
oci-a1-grabber \
  --tenancy "ocid1.tenancy.oc1..aaaa..." \
  --subnet "ocid1.subnet.oc1..aaaa..." \
  --ssh-key ~/.ssh/id_rsa.pub \
  --ocpus 2 \
  --memory 12 \
  --wait-min 45 \
  --wait-max 75 \
  --background
```

## The `--no-retry` trick

By default, when OCI returns a 500 "Out of host capacity" error, the CLI retries internally up to 7 times with exponential backoff. This means each API call takes **90-120 seconds** before returning failure.

Adding `--no-retry` disables this, so each call fails fast in **~7 seconds**. This is a **15x speedup** — your script cycles through all ADs in under 30 seconds instead of 6+ minutes. Capacity slots get snatched within seconds of opening, so speed matters.

This tool enables `--no-retry` by default. Disable it with `NO_RETRY_FLAG="false"` in config if you experience issues.

## Tips for getting an instance

1. **Avoid Frankfurt, London, Amsterdam** — most competitive regions
2. **Best EU regions**: Marseille, Madrid, Milan, Stockholm
3. **Best overall**: US East (Ashburn), US West (Phoenix) — most capacity
4. **Best times**: 2-7 AM in the region's timezone
5. **Keep your machine awake**: `caffeinate -i &` on macOS
6. **Be patient**: Can take hours to days. Some people report weeks in Frankfurt.
7. **Consider PAYG**: Upgrading to Pay As You Go often gives instant access. You still won't be charged for Always Free resources.

## After you get the instance

The instance is resizable (stop → edit shape → start), so if you grabbed a 1/6, you can upgrade to 4/24 later when more capacity is available.

Useful next steps:

```bash
# SSH in
~/oci-connect.sh

# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Install Tailscale (private access)
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

## FAQ

**Q: Is this legal?**
This tool uses Oracle's public OCI CLI/API — the same tooling Oracle provides and documents for automation. Multiple similar tools with thousands of stars have been on GitHub for 4+ years without takedowns. Oracle's rate limiting is their mechanism for controlling usage; this tool respects rate limits.

**Q: Will Oracle ban my account?**
No reports of account bans specifically for retry scripts. Oracle's TOS has broad language about service abuse, but automated instance creation via the official API is a standard use case.

**Q: Why not just upgrade to Pay As You Go?**
PAYG gives instant access and you won't be charged for Always Free resources. But some users prefer the safety of pure Free Tier (impossible to get charged). This tool is for them.

**Q: Can I run this on Oracle Cloud Shell?**
You can, but Cloud Shell has session timeouts (~20 min idle, max few hours). Running on your local machine is more reliable.

**Q: How long does it typically take?**
Varies wildly by region: minutes in less popular regions, hours to days in popular ones, potentially weeks in Frankfurt.

## Requirements

- **OCI CLI** (any recent version)
- **Bash** 4.0+
- **macOS** or **Linux** (macOS gets voice + notification alerts)
- An Oracle Cloud account with an API signing key configured

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Inspired by and built upon the work of:
- [hitrov/oci-arm-host-capacity](https://github.com/hitrov/oci-arm-host-capacity) — the original PHP retry script
- [isac322/get_oracle_a1](https://github.com/isac322/get_oracle_a1) — Python version with incremental upgrade
- [mohankumarpaluru/oracle-freetier-instance-creation](https://github.com/mohankumarpaluru/oracle-freetier-instance-creation) — Cloud Shell approach

## Disclaimer

This tool is not affiliated with, endorsed by, or sponsored by Oracle Corporation. Use at your own risk and review Oracle's [Terms of Service](https://www.oracle.com/legal/terms.html) and [Free Tier FAQ](https://www.oracle.com/cloud/free/faq/) before use.
