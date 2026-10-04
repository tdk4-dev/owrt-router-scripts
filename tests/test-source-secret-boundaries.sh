#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

if git ls-files | grep -E '(^|/)(id_(rsa|ed25519)|[^/]*\.sec|\.env($|\.)|credentials?($|\.))'; then
  printf 'tracked secret-shaped filename detected\n' >&2
  exit 1
fi
private_key_pattern='BEGIN (RSA |EC |OPENSSH )?PRIVATE'
private_key_pattern="${private_key_pattern} KEY|untrusted comment:.*secret"
private_key_pattern="${private_key_pattern} key"
if git grep -I -n -E -- "$private_key_pattern"; then
  printf 'tracked private-key material detected\n' >&2
  exit 1
fi
if git grep -I -n -E -- '(^|[^A-Za-z0-9])(ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|sk-[A-Za-z0-9]{40,})([^A-Za-z0-9]|$)'; then
  printf 'tracked token-shaped material detected\n' >&2
  exit 1
fi

printf 'Tracked-source secret boundary scan passed\n'
