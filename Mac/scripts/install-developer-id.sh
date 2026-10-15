#!/bin/zsh
# Installs the newest "Developer ID Application" certificate into the login keychain, fetched with
# the App Store Connect API (it pairs with the private key already there — see docs/RELEASING.md,
# "Developer ID"). Apple lets only the Account Holder *create* the certificate, on
# developer.apple.com; reading it back works with any team API key.
#
#   Mac/scripts/install-developer-id.sh
#
# The key: ASC_KEY_ID / ASC_ISSUER / ASC_KEY_PATH, or SameerOS's (~/.config/sameeros/asc-check.sh
# and ~/.appstoreconnect/private_keys). Never prints the key or a token.
set -euo pipefail
PY=${PY:-/usr/local/bin/python3}
CER=$(mktemp -t devid).cer
"$PY" - "$CER" <<'PYEOF'
import base64, json, os, pathlib, re, ssl, sys, time, urllib.request
import jwt
src = pathlib.Path("~/.config/sameeros/asc-check.sh").expanduser()
text = src.read_text() if src.exists() else ""
key_id = os.environ.get("ASC_KEY_ID") or re.search(r'KEY_ID = "([^"]+)"', text).group(1)
issuer = os.environ.get("ASC_ISSUER") or re.search(r'ISSUER = "([^"]+)"', text).group(1)
path = os.environ.get("ASC_KEY_PATH") or f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"
now = int(time.time())
tok = jwt.encode({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                 pathlib.Path(path).expanduser().read_text(), algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})
req = urllib.request.Request("https://api.appstoreconnect.apple.com/v1/certificates?limit=200",
                             headers={"Authorization": "Bearer " + tok})
data = json.loads(urllib.request.urlopen(req, timeout=30, context=ssl.create_default_context(cafile="/etc/ssl/cert.pem")).read())["data"]
devid = [c for c in data if c["attributes"]["certificateType"].startswith("DEVELOPER_ID_APPLICATION")]
if not devid:
    sys.exit("No Developer ID Application certificate in the account yet — create it on developer.apple.com first.")
newest = max(devid, key=lambda c: c["attributes"].get("expirationDate", ""))
a = newest["attributes"]
pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(a["certificateContent"]))
print(f"Found {a['certificateType']} '{a.get('displayName')}', expires {a.get('expirationDate', '')[:10]}")
PYEOF
security import "$CER" -k ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true   # already there is fine
rm -f "$CER"
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  security find-identity -v -p codesigning | grep "Developer ID Application" | sed -E 's/^ *[0-9]+\) [0-9A-F]+ /✓ Signing identity: /'
else
  echo "The certificate is in the keychain but doesn't pair with a private key here." >&2
  echo "It must be made from the certificate request created on this Mac (docs/RELEASING.md, Developer ID)." >&2
  exit 1
fi
