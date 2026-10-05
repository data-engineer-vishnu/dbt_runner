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

# The masking policies applied to customer table columns
policies = ["mask_asterisk_v2", "mask_hash_v2"]
target_role = "roles/bigquerydatapolicy.user"
target_member = f"user:{user_email}"

for pol in policies:
  base_url = f"https://bigquerydatapolicy.googleapis.com/v2/projects/{project}/locations/{location}/dataPolicies/{pol}"

  # Step A: Fetch current policy & fresh etag
  get_req = urllib.request.Request(
      f"{base_url}:getIamPolicy",
      data=b"{}",
      headers=headers,
      method="POST",
  )
  try:
    with urllib.request.urlopen(get_req) as resp:
      policy_data = json.loads(resp.read().decode())
  except urllib.error.HTTPError as e:
    print(f"Error reading IAM for {pol}: {e.code} - {e.read().decode()}")
    continue

  # Step B: Add user to roles/bigquerydatapolicy.user
  bindings = policy_data.get("bindings", [])
  role_found = False
  for b in bindings:
    if b.get("role") == target_role:
      if target_member not in b.get("members", []):
        b.setdefault("members", []).append(target_member)
      role_found = True
      break

  if not role_found:
    bindings.append({"role": target_role, "members": [target_member]})

  policy_data["bindings"] = bindings

  # Step C: Save IAM policy
  set_payload = json.dumps({"policy": policy_data}).encode("utf-8")
  set_req = urllib.request.Request(
      f"{base_url}:setIamPolicy",
      data=set_payload,
      headers=headers,
      method="POST",
  )
  try:
    with urllib.request.urlopen(set_req) as resp:
      print(
          f"Successfully granted '{target_role}' on {pol}: status"
          f" {resp.status}"
      )
  except urllib.error.HTTPError as e:
    print(f"Error applying IAM to {pol}: {e.code} - {e.read().decode()}")