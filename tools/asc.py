#!/usr/bin/env python3
"""Tiny App Store Connect API client (no dependencies beyond openssl).

Reads ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH from native/.env (the same
settings testflight.sh uses). Usage:

  tools/asc.py status                  # TestFlight builds + beta review state
  tools/asc.py get /v1/apps            # raw GET, prints JSON
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE_ID = "dev.ericbetts.voxelnative"
API = "https://api.appstoreconnect.apple.com"


def env():
    vals = dict(os.environ)
    path = os.path.join(HERE, "..", "native", ".env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                vals.setdefault(k.strip(), v.strip())
    missing = [k for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH") if not vals.get(k)]
    if missing:
        sys.exit(f"missing {', '.join(missing)} (set them in native/.env)")
    return vals


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der):
    """ECDSA DER signature -> the 64-byte r||s form JWT's ES256 wants."""
    assert der[0] == 0x30
    i = 2
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        n = der[i + 1]
        v = der[i + 2:i + 2 + n].lstrip(b"\x00")
        out += v.rjust(32, b"\x00")
        i += 2 + n
    return out


def token(e):
    header = {"alg": "ES256", "kid": e["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    claims = {"iss": e["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(claims).encode())}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.path.expanduser(e["ASC_KEY_PATH"])],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    return f"{signing_input}.{b64(der_to_raw(der))}"


def request(method, path, body=None):
    e = env()
    req = urllib.request.Request(API + path if path.startswith("/") else path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token(e)}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as err:
        sys.exit(f"{method} {path} -> HTTP {err.code}: {err.read().decode()[:2000]}")


def app_id():
    apps = request("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        sys.exit(f"no app record for {BUNDLE_ID}")
    return apps[0]["id"]


def status():
    aid = app_id()
    builds = request("GET", f"/v1/builds?filter[app]={aid}&sort=-uploadedDate&limit=5"
                            "&include=buildBetaDetail,betaAppReviewSubmission")
    inc = {(i["type"], i["id"]): i["attributes"] for i in builds.get("included", [])}
    for b in builds["data"]:
        a, rel = b["attributes"], b["relationships"]
        detail = rel.get("buildBetaDetail", {}).get("data")
        review = rel.get("betaAppReviewSubmission", {}).get("data")
        d = inc.get((detail["type"], detail["id"]), {}) if detail else {}
        r = inc.get((review["type"], review["id"]), {}) if review else {}
        print(f"build {a['version']}  uploaded {a['uploadedDate'][:16]}  processing={a['processingState']}"
              f"  internal={d.get('internalBuildState')}  external={d.get('externalBuildState')}"
              f"  betaReview={r.get('betaReviewState', 'not submitted')}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        status()
    elif cmd == "get":
        print(json.dumps(request("GET", sys.argv[2]), indent=2))
    else:
        sys.exit(__doc__)
