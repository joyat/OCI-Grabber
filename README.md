# OCI Grabber

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Shell: Bash](https://img.shields.io/badge/shell-bash%204%2B-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)

> Oracle gives away a **4-OCPU / 24 GB RAM ARM VM — permanently, for free**. The catch: everyone wants one, and availability is brutal. OCI Grabber keeps hammering the API until a slot opens up, then notifies you the moment it lands.

---

## Why this tool?

Several OCI retry scripts exist (shout-out to [hitrov/oci-arm-host-capacity](https://github.com/hitrov/oci-arm-host-capacity), [isac322/get_oracle_a1](https://github.com/isac322/get_oracle_a1), and [mohankumarpaluru/oracle-freetier-instance-creation](https://github.com/mohankumarpaluru/oracle-freetier-instance-creation)). This one was born from a real multi-day fight to get an ARM instance in Frankfurt. Here's how it stacks up:

| Feature | OCI Grabber | hitrov (PHP) | isac322 (Python) |
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

---

## Tips for getting an instance

Worth reading before you start — these make a real difference:

1. **Avoid Frankfurt, London, Amsterdam** — the most contested regions by far
2. **Best EU alternatives**: Marseille, Madrid, Milan, Stockholm
3. **Best overall**: US East (Ashburn) and US West (Phoenix) have the most capacity
4. **Best times**: 2–7 AM in the target region's local timezone
5. **Keep your machine awake**: run `caffeinate -i &` on macOS before starting
6. **Consider PAYG**: upgrading to Pay As You Go often gives near-instant access. You still won't be charged for Always Free resources.
7. **Be patient**: less popular regions can resolve in minutes; Frankfurt can take weeks.

---

## Quick start

### 1. Install OCI CLI

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

Then configure it:

```bash
oci setup config
```

You'll need your Tenancy OCID, User OCID, and an API key uploaded to Oracle Console → Profile → API Keys.

### 2. Install OCI Grabber

**Option A — direct download:**

```bash
curl -fsSL https://raw.githubusercontent.com/joyat/OCI-Grabber/main/oci-a1-grabber.sh -o ~/bin/oci-a1-grabber
chmod +x ~/bin/oci-a1-grabber
```

**Option B — clone:**

```bash
git clone https://github.com/joyat/OCI-Grabber.git
cd OCI-Grabber
chmod +x oci-a1-grabber.sh
ln -s "$(pwd)/oci-a1-grabber.sh" ~/bin/oci-a1-grabber
```

### 3. Run setup

```bash
oci-a1-grabber setup
```

The interactive wizard walks you through tenancy, subnet, image, SSH key, and notification preferences. Config is saved to `~/.oci-a1-grabber.conf`.

### 4. Start grabbing

```bash
# Recommended: run in the background
oci-a1-grabber --background

# Or watch it live
oci-a1-grabber
```

### 5. Monitor

```bash
oci-a1-grabber status   # check if it's running
tail -f ~/oci-a1-grabber.log  # live log
oci-a1-grabber stop     # stop it
```

### 6. Connect

When a VM is grabbed, you'll get a macOS notification (with voice!) and the connection command is saved:

```bash
~/oci-connect.sh
```

---

## How it works

```
┌─────────────┐
│  Pre-flight  │  Validates auth, subnet, image, SSH key
│   checks     │  Auto-heals deprecated images
└──────┬───────┘  Detects existing instances
       │
       ▼
┌─────────────┐
│  Retry loop  │  Rotates: 4 OCPU/24GB → 2/12GB → 1/6GB
│              │  Tries every availability domain
│  ~7–90s      │  Uses --no-retry for fast API calls
│  per cycle   │  Random jitter to avoid rate limits
└──────┬───────┘
       │
       ├── Capacity error  →  retry (expected, keep going)
       ├── Rate limited    →  back off 120s automatically
       ├── Config error    →  stop after 3 consecutive failures
       └── Success         →  notify + save SSH command
```

---

## The `--no-retry` trick

By default, when OCI returns a 500 "Out of host capacity" error, the CLI retries internally up to 7 times with exponential backoff — meaning each failed API call takes **90–120 seconds** before returning.

Adding `--no-retry` makes each call fail fast in **~7 seconds** — a **15x speedup**. Your script cycles through all availability domains in under 30 seconds instead of 6+ minutes. Since capacity slots vanish almost instantly, speed is everything.

OCI Grabber enables `--no-retry` by default. You can disable it with `NO_RETRY_FLAG="false"` in your config if needed.

---

## Configuration

The config file at `~/.oci-a1-grabber.conf` is created by the setup wizard. You can also edit it directly:

```bash
# Required
TENANCY="ocid1.tenancy.oc1..aaaa..."
SUBNET="ocid1.subnet.oc1..aaaa..."
IMAGE=""                              # Auto-detected if empty
SSH_KEY="~/.ssh/id_ed25519.pub"

# Instance
DISPLAY_NAME="a1-free"
OCPUS="4"                             # Max free tier: 4
MEMORY="24"                           # Max free tier: 24 GB

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

---

## CLI flags

All config values can be overridden at runtime:

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

---

## After you get the instance

The instance is resizable — so if you only grabbed a 1/6, you can stop it, edit the shape, and upgrade to 4/24 later when capacity allows.

```bash
# SSH in
~/oci-connect.sh

# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Install Tailscale (private network access)
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

---

## FAQ

**Is this legal?**
This tool uses Oracle's public OCI CLI — the same tooling Oracle provides and documents for automation. Multiple similar tools with thousands of stars have been on GitHub for years without issues. Oracle's rate limiting is their mechanism for controlling usage; this tool respects it.

**Will Oracle ban my account?**
There are no known account bans for running retry scripts via the official API. Automated instance creation through the OCI CLI is a standard, documented use case.

**Why not just upgrade to Pay As You Go?**
PAYG usually gives near-instant access, and you won't be charged for Always Free resources. But some users want the certainty of pure Free Tier. This tool is for them.

**Can I run this on Oracle Cloud Shell?**
Technically yes, but Cloud Shell has a ~20-minute idle timeout and a max session length of a few hours. Running on your own machine is far more reliable.

**How long does it take?**
Varies by region. Less popular regions can resolve in minutes. Frankfurt can take weeks.

---

## Requirements

- **OCI CLI** — any recent version
- **Bash** 4.0+
- **macOS** or **Linux** (macOS gets voice + system notification alerts)
- An Oracle Cloud account with an API signing key configured

---

## Acknowledgments

Inspired by and built on the work of:
- [hitrov/oci-arm-host-capacity](https://github.com/hitrov/oci-arm-host-capacity) — the original PHP retry script
- [isac322/get_oracle_a1](https://github.com/isac322/get_oracle_a1) — Python version with incremental size upgrade
- [mohankumarpaluru/oracle-freetier-instance-creation](https://github.com/mohankumarpaluru/oracle-freetier-instance-creation) — Cloud Shell approach

---

## License

MIT — see [LICENSE](LICENSE).

---

*Not affiliated with, endorsed by, or sponsored by Oracle Corporation. Use at your own risk and review Oracle's [Terms of Service](https://www.oracle.com/legal/terms.html) and [Free Tier FAQ](https://www.oracle.com/cloud/free/faq/) before use.*
