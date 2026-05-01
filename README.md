# Oracle Cloud Free Tier ARM Instance Launcher

Persistent, rate-limit-safe launcher for **Oracle Cloud Infrastructure (OCI)** free-tier `VM.Standard.A1.Flex` ARM instances. Designed to run periodically until an instance is successfully provisioned — despite OCI's frequent "out of capacity" responses on the free tier.

Runs in **two equally supported modes**:

1. **Local macOS `launchd`** — wakes your Mac on schedule (or just runs while it's awake)
2. **GitHub Actions** — runs in the cloud 24/7, no machine of your own required

You can pick either one, or run both in parallel as redundant pollers — the idempotency check prevents double-provisioning.

## Features

- 🌍 **Multi-account** — one parameterized script handles any number of OCI accounts
- 🕵️ **Account-agnostic identifiers** — committed code uses generic keys (`account-a`, `account-b`); your real account names live only in secrets / gitignored env files
- 🔁 **Idempotent** — exits cleanly when an instance already exists
- 🚦 **Rate-limit aware** — respects HTTP 429 responses
- 🎯 **AD rotation** — cycles through availability domains on each retry
- 🔔 **Notifications** — macOS Notification Center + optional Telegram, with friendly per-account labels
- 🔐 **Secrets-safe** — `.env` files gitignored; CI uses GitHub Environment secrets
- ⚡ **Parallel-safe** — per-account locks, logs, and isolated state

---

## Naming Convention

This repo deliberately uses **anonymized account keys** (`account-a`, `account-b`, `account-c`, …) in all committed files — workflow names, log paths, lock files, and launchd labels. The only place your *real* account identity (region, tenancy, friendly name) appears is:

- Your local `accounts/<key>.env` files — **gitignored**
- GitHub Environment secrets — **encrypted, per-environment**
- Telegram messages you receive — set via `ACCOUNT_LABEL` (e.g. `🌎 Production`, `Production`, `🌎 EU-West`)

Why? So you can safely make the repo public without leaking metadata about your Oracle setup.

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
echo "OCI_API_KEY" >> my-account-api-key.pem    # silences a CLI warning

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

cp accounts/example.env accounts/account-a.env
# edit accounts/account-a.env — paste OCIDs from step A4
# set ACCOUNT_LABEL to whatever you want to see in Telegram (e.g. "🇩🇪 EU Frankfurt")
```

Run it once manually to test:

```bash
./oracle-launch.sh account-a
```

### A6. Schedule via launchd

```bash
# Install: launches at minutes :00 and :30 of each hour
./scripts/install-launchd.sh install account-a 0 30

# Verify
./scripts/install-launchd.sh status

# Watch logs
tail -f ~/Library/Logs/oracle-account-a-launch.log

# Uninstall
./scripts/install-launchd.sh uninstall account-a
```

For multiple accounts, **stagger the minutes** so they don't all fire at once:

```bash
./scripts/install-launchd.sh install account-a 0 30   # :00, :30
./scripts/install-launchd.sh install account-b 15 45  # :15, :45
```

> The reverse-domain prefix defaults to `com.local`. Override with the optional 5th argument or set `LAUNCHD_REVERSE_DOMAIN`:
> `./scripts/install-launchd.sh install account-a 0 30 com.mycompany`

---

## Mode B — GitHub Actions (cloud)

Runs every 30 minutes in GitHub's runners — true 24/7 coverage, no local machine required.

### B1. Fork or use this repo

```bash
gh repo create oracle-cloud-launcher --private --source=. --push
```

The included `.github/workflows/oracle-account-a.yml` and `oracle-account-b.yml` are templates. Each one is bound to a **GitHub Environment** of the same name (`account_a`, `account_b`). You configure secrets per environment, not per workflow.

### B2. Create GitHub Environments

In **Settings → Environments → New environment**, create:

- `account_a`
- `account_b` (and so on, one per OCI account you want to poll)

Or via CLI:

```bash
gh api repos/<owner>/<repo>/environments/account_a --method PUT
gh api repos/<owner>/<repo>/environments/account_b --method PUT
```

### B3. Configure secrets per environment

In each environment's secret list, add the same set (so workflows can use `${{ secrets.OCI_USER }}` regardless of which account they're for):

| Secret | What goes in it |
|--------|-----------------|
| `OCI_USER` | User OCID for this account |
| `OCI_FINGERPRINT` | API key fingerprint |
| `OCI_TENANCY` | Tenancy OCID |
| `OCI_REGION` | e.g. `eu-frankfurt-1` |
| `OCI_KEY_PEM` | **Full** content of the `.pem` private key file |
| `COMPARTMENT_OCID` | Usually same as tenancy OCID for free tier |
| `SUBNET_OCID` | Subnet OCID |
| `IMAGE_OCID` | Boot image OCID |
| `AD_NAMES` | Space-separated AD names |
| `INSTANCE_NAME` | Display name of the launched instance |
| `ACCOUNT_LABEL` | Friendly label for notifications (e.g. `🇩🇪 EU Frankfurt`) |

### B4. Repository-level secrets (shared across all environments)

| Secret | What goes in it |
|--------|-----------------|
| `SSH_PUBLIC_KEY` | Content of `~/.ssh/id_rsa.pub` |
| `TELEGRAM_BOT_TOKEN` | Bot token (optional) |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID (optional) |

Set them with `gh`:

```bash
# Per-environment
gh secret set OCI_USER --env account_a --body "ocid1.user.oc1..xxxx"
gh secret set OCI_KEY_PEM --env account_a < ~/.oci/account-a-api-key.pem

# Repository-level
gh secret set SSH_PUBLIC_KEY < ~/.ssh/id_rsa.pub
```

### B5. Trigger the workflow

The workflows run on cron, but you can trigger immediately from the **Actions tab → Oracle Account A Launcher → Run workflow**.

### B6. Schedule

Cron expressions are in `.github/workflows/oracle-account-*.yml`:

- `account-a`: `0,30 * * * *` (every hour at :00 and :30)
- `account-b`: `15,45 * * * *` (every hour at :15 and :45)

> ⚠️ GitHub Actions cron can be delayed several minutes during peak load — this is documented behavior. For tight schedules, use launchd instead.

---

## Adding a New Account

### For launchd (Mode A)

1. `cp accounts/example.env accounts/account-c.env` (pick the next free letter)
2. Fill in the OCIDs and friendly `ACCOUNT_LABEL`
3. `./scripts/install-launchd.sh install account-c <minute_a> <minute_b>`

### For GitHub Actions (Mode B)

1. Create a new environment: `gh api repos/<owner>/<repo>/environments/account_c --method PUT`
2. Add all the per-environment secrets to it
3. Copy `.github/workflows/oracle-account-a.yml` → `oracle-account-c.yml`
4. Inside the new file, change three things:
   - `name: Oracle Account C Launcher`
   - `cron:` to a non-overlapping minute pair (e.g. `'5,35 * * * *'`)
   - `concurrency.group: oracle-account-c`
   - `environment: account_c`
   - `env.ACCOUNT_KEY: account-c`

---

## Repository Layout

```
.
├── oracle-launch.sh                      # Generic launcher (takes account name as arg)
├── accounts/
│   ├── example.env                       # Template — copy this
│   └── (your <account-key>.env files)    # Gitignored
├── templates/
│   └── launchd.plist.template            # Used by install-launchd.sh
├── scripts/
│   └── install-launchd.sh                # Installs/uninstalls launchd jobs
├── .github/
│   ├── dependabot.yml                    # Auto-updates GitHub Actions versions
│   └── workflows/
│       ├── oracle-account-a.yml          # Template workflow for account "a"
│       └── oracle-account-b.yml          # Template workflow for account "b"
├── CHANGELOG.md
├── LICENSE                               # MIT
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
5. If all retries exhausted → log, notify "out of capacity", exit 0

### Notifications you'll receive

| Outcome | Telegram message |
|---------|------------------|
| Already exists | `🖥️ <LABEL>: Instance already exists (RUNNING)` |
| Created | `🖥️ <LABEL>: ✅ Instance created and PROVISIONING! (<AD>)` |
| Out of capacity (full run) | `🖥️ <LABEL>: ⏱️ Out of capacity — all N AD(s) exhausted` |
| Rate limited | `🖥️ <LABEL>: 🚦 Rate limited - will try next run` |
| Network timeout | `🖥️ <LABEL>: 🌐 Connection timeout - will try next run` |
| Auth error | `🖥️ <LABEL>: ❌ Auth error - check your OCI config` |

`<LABEL>` is the `ACCOUNT_LABEL` you set in the env file or environment secret.

---

## Once an Instance Is Provisioned

The idempotency check fires on every subsequent run, so you'll just keep getting `Instance already exists` notifications. To stop polling that account:

```bash
# launchd
./scripts/install-launchd.sh uninstall <account-key>

# GitHub Actions: edit .github/workflows/oracle-<account-key>.yml
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
