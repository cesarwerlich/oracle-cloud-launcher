# Oracle Cloud Free Tier ARM Instance Launcher

Persistent, rate-limit-safe launcher for **Oracle Cloud Infrastructure (OCI)** free-tier `VM.Standard.A1.Flex` ARM instances. Designed to run periodically until an instance is successfully provisioned — despite OCI's frequent "out of capacity" responses on the free tier.

Runs in **two equally supported modes**:

1. **Local macOS `launchd`** — wakes your Mac on schedule (or just runs while it's awake)
2. **GitHub Actions** — runs in the cloud 24/7, no machine of your own required

You can pick either one, or run both in parallel as redundant pollers — the idempotency check prevents double-provisioning.

## Features

- 🌍 **Multi-account** — one parameterized script handles any number of OCI accounts
- 🔁 **Idempotent** — exits cleanly when an instance already exists
- 🚦 **Rate-limit aware** — respects HTTP 429 responses
- 🎯 **AD rotation** — cycles through availability domains on each retry
- 🔔 **Notifications** — macOS Notification Center + optional Telegram, account-prefixed
- 🔐 **Secrets-safe** — `.env` files gitignored; CI uses GitHub Secrets
- ⚡ **Parallel-safe** — per-account locks, logs, and isolated state

---

## Quick Start

### Prerequisites (both modes)

- An OCI Free Tier account (with a VCN + subnet already created)
- An SSH public key
- Optional: a Telegram bot for notifications ([@BotFather](https://t.me/BotFather) → `/newbot`)

### Choose Your Path

| Mode | Best for | Setup time |
|------|----------|-----------|
| **macOS launchd** | You always have your Mac on, want quick local setup | ~10 min |
| **GitHub Actions** | You want true 24/7 unattended polling | ~15 min |
| **Both (redundant)** | Maximum coverage | ~20 min |

---

## Mode A — macOS `launchd` (local)

Runs your Mac as a poller. Note: launchd does **not** fire while the Mac is asleep. It will run a missed slot once on wake, but for true 24/7 coverage use Mode B.

### A1. Install dependencies

```bash
brew install jq
brew install --cask oracle-cli   # or: pip install oci-cli
```

### A2. Set up OCI API key

```bash
cd ~/.oci
openssl genrsa -out my-account-api-key.pem 2048
chmod 600 my-account-api-key.pem
openssl rsa -pubout -in my-account-api-key.pem -out my-account-api-key_public.pem
echo "OCI_API_KEY" >> my-account-api-key.pem    # silences a warning

# Print the fingerprint (you'll need it in OCI Console + ~/.oci/config):
openssl rsa -pubout -outform DER -in my-account-api-key.pem 2>/dev/null \
  | openssl md5 -c | awk '{print $2}'

# Print the public key — paste into OCI Console:
cat my-account-api-key_public.pem
```

In **OCI Console → Identity → Domains → Default → Users → [your user] → API Keys → Add API Key**, choose **Paste Public Key** and paste the contents above. Confirm the displayed fingerprint matches.

### A3. Add a profile to `~/.oci/config`

```ini
[DEFAULT]
user=ocid1.user.oc1..xxxxxxxxxxxxxxxxxx
fingerprint=<from step A2>
key_file=/Users/<you>/.oci/my-account-api-key.pem
tenancy=ocid1.tenancy.oc1..xxxxxxxxxxxxxxxxxx
region=eu-frankfurt-1
```

Verify: `oci iam region list`.

### A4. Discover OCIDs

Replace `$TENANCY` with your tenancy OCID:

```bash
TENANCY="ocid1.tenancy.oc1..xxxxxxxxxxxxxxxxxx"

# Availability Domains
oci iam availability-domain list --compartment-id "$TENANCY" --query 'data[*].name'

# Subnet OCID
oci network subnet list --compartment-id "$TENANCY" \
  --query 'data[*].{name:"display-name",id:id}'

# Latest Ubuntu ARM image
oci compute image list --compartment-id "$TENANCY" \
  --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
  --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --sort-order DESC \
  --limit 1 --query 'data[*].{name:"display-name",id:id}'
```

### A5. Configure the account

```bash
git clone https://github.com/cesarwerlich/oracle-cloud-launcher.git
cd oracle-cloud-launcher

cp accounts/example.env accounts/myacct.env
# edit accounts/myacct.env with the OCIDs from step A4
```

Run it once manually to test:

```bash
./oracle-launch.sh myacct
```

### A6. Schedule via launchd

```bash
# Install: launches at minutes :00 and :30 of each hour
./scripts/install-launchd.sh install myacct 0 30

# Verify
./scripts/install-launchd.sh status

# Watch logs
tail -f ~/Library/Logs/oracle-myacct-launch.log

# Uninstall
./scripts/install-launchd.sh uninstall myacct
```

For multiple accounts, **stagger the minutes** so they don't all fire at once:

```bash
./scripts/install-launchd.sh install acct1 0 30   # :00, :30
./scripts/install-launchd.sh install acct2 15 45  # :15, :45
```

> The reverse-domain prefix defaults to `com.local`. Override with the optional 5th argument or set `LAUNCHD_REVERSE_DOMAIN`:
> `./scripts/install-launchd.sh install myacct 0 30 com.mycompany`

---

## Mode B — GitHub Actions (cloud)

Runs every 30 minutes in GitHub's runners — true 24/7 coverage, no local machine required.

### B1. Fork or use this repo

```bash
gh repo create oracle-cloud-launcher --private --source=. --push
```

(The included `.github/workflows/oracle-gmx.yml` and `oracle-cdw.yml` are tailored for two example accounts. Duplicate one and rename for each account you want to run.)

### B2. Configure GitHub Secrets

Per account (replace `<ACCT>` with `GMX`, `CDW`, etc.):

| Secret | What goes in it |
|--------|-----------------|
| `<ACCT>_OCI_USER` | User OCID |
| `<ACCT>_OCI_FINGERPRINT` | API key fingerprint |
| `<ACCT>_OCI_TENANCY` | Tenancy OCID |
| `<ACCT>_OCI_REGION` | e.g. `eu-frankfurt-1` |
| `<ACCT>_OCI_KEY_PEM` | **Full** content of the `.pem` private key file |
| `<ACCT>_COMPARTMENT_OCID` | Usually same as tenancy OCID for free tier |
| `<ACCT>_SUBNET_OCID` | Subnet OCID |
| `<ACCT>_IMAGE_OCID` | Boot image OCID |
| `<ACCT>_AD_NAMES` | Space-separated AD names |

Shared:

| Secret | What goes in it |
|--------|-----------------|
| `SSH_PUBLIC_KEY` | Content of `~/.ssh/id_rsa.pub` |
| `TELEGRAM_BOT_TOKEN` | Bot token (optional) |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID (optional) |

Optional repo variables (not secrets):

| Variable | Default | Purpose |
|----------|---------|---------|
| `<ACCT>_INSTANCE_NAME` | `oracle-<acct>-vm-arm-01` | Display name of the launched instance |

Set them with `gh`:

```bash
gh secret set GMX_OCI_USER --body "ocid1.user.oc1..xxxx"
gh secret set GMX_OCI_KEY_PEM < ~/.oci/oracle-gmx-oci-api-key.pem
# ... etc
```

### B3. Trigger the workflow

The workflows run on cron, but you can trigger immediately from the **Actions tab → Oracle GMX Launcher → Run workflow**.

### B4. Schedule

Cron expressions are in `.github/workflows/oracle-*.yml`:

- GMX: `0,30 * * * *` (every hour at :00 and :30)
- CDW: `15,45 * * * *` (every hour at :15 and :45)

> ⚠️ GitHub Actions cron can be delayed several minutes during peak load — this is documented behavior. For tight schedules, use launchd instead.

---

## Adding a New Account

### For launchd (Mode A)

1. Create `accounts/<acct>.env` from `accounts/example.env`
2. Run `./scripts/install-launchd.sh install <acct> <minute_a> <minute_b>`

### For GitHub Actions (Mode B)

1. Copy `.github/workflows/oracle-gmx.yml` → `oracle-<acct>.yml`
2. Replace `gmx` / `GMX` references with your account name
3. Pick non-overlapping cron minutes
4. Add the `<ACCT>_*` secrets via `gh secret set`

---

## Repository Layout

```
.
├── oracle-launch.sh                 # Generic launcher (takes account name as arg)
├── accounts/
│   ├── example.env                  # Template — copy this
│   └── (your <acct>.env files)      # Gitignored
├── templates/
│   └── launchd.plist.template       # Used by install-launchd.sh
├── scripts/
│   └── install-launchd.sh           # Installs/uninstalls launchd jobs
├── .github/workflows/
│   ├── oracle-gmx.yml               # Example workflow for one account
│   └── oracle-cdw.yml               # Example workflow for another account
├── CHANGELOG.md
├── LICENSE                          # MIT
└── README.md
```

---

## Behavior Reference

### What happens on each run

1. Acquire per-account lock (skip if another run for the same account is in flight)
2. Validate dependencies (`oci`, `jq`, `curl`) and required env vars
3. Check whether an instance with the configured name already exists → exit early if so
4. Loop up to `MAX_RETRIES` times:
   - Try to launch in `AD[(attempt-1) % len(ADs)]`
   - On `Out of capacity` → log and try next AD
   - On `429 TooManyRequests` → log, notify, exit (next scheduled run will retry)
   - On connection timeout → log, notify, exit
   - On auth error → log, notify, exit (fatal)
   - On success → log, notify, exit
5. If all retries exhausted → log, notify "out of capacity"

### Notifications you'll receive

| Outcome | Telegram message |
|---------|------------------|
| Already exists | `🖥️ <LABEL>: Instance already exists (RUNNING)` |
| Created | `🖥️ <LABEL>: ✅ Instance created and PROVISIONING! (<AD>)` |
| Out of capacity (full run) | `🖥️ <LABEL>: ⏱️ Out of capacity — all N AD(s) exhausted` |
| Rate limited | `🖥️ <LABEL>: 🚦 Rate limited - will try next run` |
| Network timeout | `🖥️ <LABEL>: 🌐 Connection timeout - will try next run` |
| Auth error | `🖥️ <LABEL>: ❌ Auth error - check your OCI config` |

---

## Once an Instance Is Provisioned

The idempotency check fires on every subsequent run, so you'll just keep getting `Instance already exists` notifications. To stop polling that account:

```bash
# launchd
./scripts/install-launchd.sh uninstall <acct>

# GitHub Actions: edit .github/workflows/oracle-<acct>.yml
# and remove the `schedule:` block (or delete the file)
```

---

## Versioning & Releases

This project uses [Semantic Versioning](https://semver.org/). See [CHANGELOG.md](./CHANGELOG.md) for the release history.

To cut a release:

```bash
# Update CHANGELOG.md, move [Unreleased] entries under a new [vX.Y.Z]
git add CHANGELOG.md && git commit -m "release: vX.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin main --tags
gh release create vX.Y.Z --notes-file CHANGELOG.md
```

---

## Contributing

Issues and PRs welcome. Please:

1. Run shellcheck on any modified `.sh` files: `shellcheck oracle-launch.sh`
2. Update `CHANGELOG.md` under `[Unreleased]`
3. Don't commit any `.env` files or `.pem` keys — `.gitignore` should already prevent this, but double-check `git status` before committing

---

## License

MIT — see [LICENSE](./LICENSE).
