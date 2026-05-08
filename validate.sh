#!/usr/bin/env bash
#
# validate.sh
# Pre-flight checks on user-data before building a USB. Catches the most
# common errors locally so you don't find them at install time.

set -euo pipefail

cd "$(dirname "$0")"

ERRORS=0

echo "Checking files exist ..."
for f in user-data meta-data; do
  if [[ -f "$f" ]]; then
    echo "  ✓ $f"
  else
    echo "  ✗ $f missing"
    ERRORS=$((ERRORS+1))
  fi
done

echo
echo "Checking user-data YAML syntax ..."
if python3 -c "import yaml; yaml.safe_load(open('user-data'))" 2>/dev/null; then
  echo "  ✓ valid YAML"
else
  echo "  ✗ user-data has YAML syntax errors:"
  python3 -c "import yaml; yaml.safe_load(open('user-data'))" 2>&1 | sed 's/^/      /'
  ERRORS=$((ERRORS+1))
fi

echo
echo "Checking password hash ..."
if grep -q 'REPLACE_ME_WITH_REAL_HASH' user-data; then
  echo "  ✗ placeholder password hash still present"
  echo "    Generate one with:  mkpasswd -m sha-512"
  echo "    Then replace REPLACE_ME_WITH_REAL_HASH... in user-data."
  ERRORS=$((ERRORS+1))
elif grep -qE 'password:\s*"\$6\$[^"]{20,}' user-data; then
  echo "  ✓ looks like a real SHA-512 crypt hash"
else
  echo "  ⚠  password line doesn't match expected \$6\$... format"
  echo "    Make sure it's a SHA-512 hash from: mkpasswd -m sha-512"
fi

echo
if [[ $ERRORS -eq 0 ]]; then
  echo "All checks passed. Safe to run ./build-usb.sh"
  exit 0
else
  echo "$ERRORS error(s) — fix before building."
  exit 1
fi
