# Publishing this gem — a complete walkthrough

This is a one-time setup followed by a repeatable release process. If you've
never published a gem before, follow this start-to-finish.

## One-time setup

### 1. Create the RubyGems account

Go to <https://rubygems.org/sign_up> and create an account under an email you
control and can receive mail at. Confirm the address.

### 2. Enable multi-factor authentication

This is **not optional for a wallet-related gem**. Anyone who compromises your
RubyGems account could push a malicious version that steals NWC secrets from
downstream users.

- Go to <https://rubygems.org/multifactor_auth/new>.
- Scan the QR with Authy / 1Password / Google Authenticator / Bitwarden.
- Save the recovery codes somewhere offline.

The gemspec already sets `spec.metadata["rubygems_mfa_required"] = "true"`,
which will force MFA on every push to this gem.

### 3. Create the GitHub repo

- Go to <https://github.com/MegalithicBTC?tab=repositories>, click **New**.
- Name: `nwc-ruby` (match the gem name exactly).
- Description: `Ruby client for Nostr Wallet Connect (NIP-47)`
- Public. MIT license. No README / .gitignore / license (the gem ships those).

### 4. Push the initial code

```sh
cd /path/to/nwc-ruby

git init -b main
git add .
git commit -m "Initial commit: nwc-ruby gem v0.1.0"
git remote add origin git@github.com:MegalithicBTC/nwc-ruby.git
git push -u origin main
```

Verify CI runs green on GitHub Actions before proceeding.

### 5. Sign into RubyGems locally

```sh
gem signin
```

This prompts for your email and password, then for your MFA code. It writes a
credentials file to `~/.gem/credentials` (Unix) or `%USERPROFILE%\.gem\credentials`
(Windows). Lock it down:

```sh
chmod 600 ~/.gem/credentials
```

### 6. Configure trusted publishing (recommended, more secure than API keys)

Instead of storing a RubyGems API key in GitHub Actions, configure RubyGems to
trust pushes from your specific GitHub workflow. This is what the
`.github/workflows/release.yml` in this repo is designed for.

- Go to <https://rubygems.org/profile/oidc/pending_trusted_publishers/new>.
- **Repository owner**: `MegalithicBTC`
- **Repository name**: `nwc-ruby`
- **Workflow filename**: `release.yml`
- **Environment name**: (leave blank)
- **Rubygem name**: `nwc-ruby`

This creates a "pending" trusted publisher that auto-activates the first time
you do a manual push (below). From then on, tagging a version pushes to
RubyGems with no API key in your GitHub secrets.

## First publish (manual)

The first push has to be manual because RubyGems needs to see the gem name
exists before the trusted publisher can claim it.

### 1. Verify everything builds cleanly

```sh
cd /path/to/nwc-ruby

bundle install
bundle exec rspec        # all green
bundle exec rubocop      # no offenses

gem build nwc-ruby.gemspec
# => Successfully built RubyGem
# => Name: nwc-ruby
# => Version: 0.1.0
# => File: nwc-ruby-0.1.0.gem
```

### 2. Do a dry-run install locally

```sh
gem install ./nwc-ruby-0.1.0.gem

ruby -e 'require "nwc_ruby"; puts NwcRuby::VERSION'
# => 0.1.0
```

If anything breaks (missing files, bad requires), fix it now — you cannot yank
and re-push the same version number.

### 3. Push to RubyGems

```sh
gem push nwc-ruby-0.1.0.gem
# Enter your MFA OTP when prompted.
```

Verify: <https://rubygems.org/gems/nwc-ruby>

### 4. Tag and push to GitHub

```sh
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

Also create a release on GitHub (Releases → Draft a new release → pick the
tag) and paste in the CHANGELOG entry for that version.

## Subsequent releases (automated via tag)

Now that `release.yml` is in place and trusted publishing is configured, every
release is just:

1. Update `lib/nwc_ruby/version.rb`:
   ```ruby
   VERSION = "0.2.0"
   ```
2. Add a `## [0.2.0] — YYYY-MM-DD` section to `CHANGELOG.md`.
3. Commit, merge to `main`, wait for CI green.
4. Tag and push:
   ```sh
   git tag -a v0.2.0 -m "Release v0.2.0"
   git push origin v0.2.0
   ```
5. The `release.yml` workflow builds and pushes to RubyGems via OIDC. Watch
   <https://github.com/MegalithicBTC/nwc-ruby/actions>.

## Version numbering

This gem follows [Semantic Versioning](https://semver.org/):

- **0.1.0 → 0.1.1** (patch): bug fixes, no API changes.
- **0.1.0 → 0.2.0** (minor): new features, backward-compatible additions.
- **0.1.0 → 1.0.0** (major): first stable release, or any breaking change
  after 1.0. Until 1.0.0, the 0.x releases imply "API may still shift."

Bump to 1.0.0 when:

- NIP-44 v2 vectors pass in CI on every build.
- You've run the gem against Rizful and Alby Hub successfully for ≥ 30 days
  in production (e.g., in `exrails`).
- Public API is stable and you're ready to commit to backward compatibility.

## Yanking a broken release

If you push a version with a critical bug:

```sh
gem yank nwc-ruby -v 0.1.0
```

This removes it from RubyGems. **You cannot re-push the same version number**
— bump to `0.1.1` and push the fix.

Only yank when the version is actively dangerous. Version numbers are
historically stable: yanks break lockfiles.

## Troubleshooting

**`Errno::ENOENT: No such file or directory @ rb_sysopen`** when `gem push`:
make sure you're running from the directory containing the `.gem` file.

**`403 Forbidden`** on push: your MFA token expired. `gem signin` again.

**`rbsecp256k1` fails to install**: you need `libsecp256k1-dev`. On macOS:
`brew install secp256k1`. On Ubuntu: `apt-get install libsecp256k1-dev`. On
Alpine: `apk add secp256k1-dev`. The CI config already handles this.

**Trusted publisher not activating**: the first manual push has to succeed
before the pending trusted publisher can latch on to the gem. Don't skip the
"First publish (manual)" step.

## After publishing

- Add a shields.io badge to the README: `[![Gem Version](https://badge.fury.io/rb/nwc-ruby.svg)](https://rubygems.org/gems/nwc-ruby)`
- Update `docs.megalithic.me` with a pointer to the gem.
- Write a blog post. The README already links out to rizful.com and getalby.com.
