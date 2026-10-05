import json
import subprocess
import urllib.error
import urllib.request

project = "project-fd305953-166e-42aa-8d5"
dataset = "dev_vishnu"
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

url = f"https://bigquery.googleapis.com/bigquery/v2/projects/{project}/datasets/{dataset}"

# 1. Fetch current dataset configuration
req = urllib.request.Request(url, headers=headers, method="GET")
with urllib.request.urlopen(req) as resp:
  ds_data = json.loads(resp.read().decode())

# 2. Append user to access list with OWNER / roles/bigquery.admin
access_list = ds_data.get("access", [])
new_entry = {"role": "roles/bigquery.admin", "userByEmail": user_email}

# Check if already present
already_exists = any(
    e.get("userByEmail") == user_email and e.get("role") == "roles/bigquery.admin"
    for e in access_list
)

if not already_exists:
  access_list.append(new_entry)
  ds_data["access"] = access_list

  # 3. Patch dataset
  patch_req = urllib.request.Request(
      url,
      data=json.dumps({"access": access_list}).encode("utf-8"),
      headers=headers,
      method="PATCH",
  )
  try:
    with urllib.request.urlopen(patch_req) as resp:
      print(f"Successfully updated dataset access: {resp.status}")
  except urllib.error.HTTPError as e:
    print(f"Failed to update dataset: {e.code} - {e.read().decode()}")
else:
  print("User already configured on dataset access list.")