import json
import subprocess
import urllib.error
import urllib.request

project = "project-fd305953-166e-42aa-8d5"
location = "asia-southeast1"
user_email = "vishnu.as.automate1@gmail.com"

token = (
    subprocess.check_output("gcloud auth print-access-token", shell=True)
    .decode()
    .strip()
)
headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
}

policies_to_test = ["mask_asterisk_v2", "raw_pii_v2"]

candidates = [
    "roles/datacatalog.categoryFineGrainedReader",
    "roles/bigquerydatapolicy.fineGrainedReader",
    "roles/bigquerydatapolicy.rawDataReader",
    "roles/bigquerydatapolicy.user",
    "roles/bigquerydatapolicy.reader",
    "roles/bigquery.filteredDataViewer",
    "roles/bigquery.dataViewer",
    "roles/bigquery.maskedReader",
    "roles/bigquerydatapolicy.admin",
]

for pol in policies_to_test:
  base_url = f"https://bigquerydatapolicy.googleapis.com/v2/projects/{project}/locations/{location}/dataPolicies/{pol}"

  # Get current etag
  get_req = urllib.request.Request(
      f"{base_url}:getIamPolicy", data=b"{}", headers=headers, method="POST"
  )
  try:
    with urllib.request.urlopen(get_req) as resp:
      etag = json.loads(resp.read().decode()).get("etag", "ACAB")
  except Exception as e:
    print(f"Error fetching etag for {pol}: {e}")
    continue

  print(f"\n=== Testing roles on {pol} ===")
  for role in candidates:
    payload = {
        "policy": {
            "version": 1,
            "etag": etag,
            "bindings": [{"role": role, "members": [f"user:{user_email}"]}],
        }
    }
    req = urllib.request.Request(
        f"{base_url}:setIamPolicy",
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
      with urllib.request.urlopen(req) as resp:
        print(f"  [SUCCESS] {role}")
        # Refresh etag
        get_req2 = urllib.request.Request(
            f"{base_url}:getIamPolicy",
            data=b"{}",
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(get_req2) as resp2:
          etag = json.loads(resp2.read().decode()).get("etag", etag)
    except urllib.error.HTTPError as e:
      raw = e.read().decode()
      try:
        msg = json.loads(raw).get("error", {}).get("message", raw)
      except Exception:
        msg = raw
      print(f"  [FAIL] {role} -> {msg}")