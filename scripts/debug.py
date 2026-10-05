import json
import subprocess
import urllib.request

project = "project-fd305953-166e-42aa-8d5"
location = "asia-southeast1"
dataset = "dev_vishnu"
table = "customer"

token = (
    subprocess.check_output("gcloud auth print-access-token", shell=True)
    .decode()
    .strip()
)
headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
}

# 1. Fetch full table definition (including dataPolicies in schema fields)
url = f"https://bigquery.googleapis.com/bigquery/v2/projects/{project}/datasets/{dataset}/tables/{table}"
req = urllib.request.Request(url, headers=headers, method="GET")

try:
  with urllib.request.urlopen(req) as resp:
    data = json.loads(resp.read().decode())
    print("--- TABLE SCHEMA FIELDS & DATA POLICIES ---")
    for f in data.get("schema", {}).get("fields", []):
      print(f"Column: {f.get('name')}")
      if "policyTags" in f:
        print(f"  policyTags: {f['policyTags']}")
      if "dataPolicies" in f:
        print(f"  dataPolicies: {f['dataPolicies']}")
      # Check if any extra metadata is present
      extra_keys = set(f.keys()) - {
          "name",
          "type",
          "mode",
          "description",
          "policyTags",
      }
      if extra_keys:
        print(f"  extra attributes: { {k: f[k] for k in extra_keys} }")
except Exception as e:
  print(f"Error fetching table: {e}")

# 2. Check if there are data policy associations under the table or dataset in v2
for parent_endpoint in [
    f"https://bigquerydatapolicy.googleapis.com/v2/projects/{project}/locations/{location}/dataPolicies",
]:
  print(f"\n--- LISTING {parent_endpoint} ---")
  try:
    req = urllib.request.Request(parent_endpoint, headers=headers, method="GET")
    with urllib.request.urlopen(req) as resp:
      print(json.dumps(json.loads(resp.read().decode()), indent=2))
  except Exception as e:
    print(f"Error: {e}")