# Setup

> **🤖 If you're an LLM agent / setting up in a fresh sandbox or CI: this is
> the file to follow.** Don't improvise — `apt` ships Elixir 1.14 / OTP 25,
> and asdf's erlang plugin compiles OTP from source (minutes on a single core).
> Install precompiled binaries from builds.hex.pm as below.

Pyex needs Elixir `~> 1.19` on OTP 28.

For **local dev** with an existing toolchain, the repo pins exact versions in
`.tool-versions` (use `asdf` or `mise`) — nothing else to do.

For a **cold environment** (fresh sandbox, CI runner, new container) where
`mix` is not on `PATH`, install precompiled binaries. On Ubuntu 24.04 / amd64:

```bash
OTP=28.5.0.1 EX=1.19.5-otp-28 ROOT="$HOME/beam"   # bump patch versions as needed
mkdir -p "$ROOT"/{otp,elixir} && cd "$ROOT"
curl -fsSL -o otp.tar.gz "https://builds.hex.pm/builds/otp/amd64/ubuntu-24.04/OTP-${OTP}.tar.gz"
curl -fsSL -o elixir.zip "https://builds.hex.pm/builds/elixir/v${EX}.zip"
tar xf otp.tar.gz -C otp --strip-components=1
unzip -q elixir.zip -d elixir
( cd otp && ./Install -minimal "$(pwd)" >/dev/null )   # bakes the abs path into the release
```

Then export these in **every** shell — each shell is fresh, so the exports
don't persist; re-apply them or write them to an env file you `source`:

```bash
export PATH="$HOME/beam/otp/bin:$HOME/beam/elixir/bin:$PATH"
export ELIXIR_ERL_OPTIONS="+fnu"                            # precompiled OTP defaults to latin1; silences the locale warning
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt  # precompiled OTP can't find the OS CA store; without this, Hex TLS fails with unknown_ca
```

Finally:

```bash
mix local.hex --force && mix local.rebar --force
mix deps.get && mix compile
```

`MIX_ENV=prod` skips the dev/test deps (ex_doc, dialyxir, benchee, bandit)
when you only need to run code, not test it.

## The four traps this recipe handles

These cost an uninformed setup real time, so they're baked in above:

1. The arch directory is `amd64`, not `x86_64`, in the builds.hex.pm OTP URL.
2. The OTP tarball is a kerl-style release — `./Install -minimal "$(pwd)"`
   bakes its absolute path in, or `erl` can't resolve its own root.
3. Precompiled OTP can't find the OS CA store, so Hex TLS to repo.hex.pm
   fails with `unknown_ca` — `HEX_CACERTS_PATH` fixes it.
4. Precompiled OTP defaults to a latin1 locale; `+fnu` silences the warning.
