import json
import os

XTEA_FILE = "xtea.json"

print(f"Reading object-formatted data from {XTEA_FILE}...")

try:
    with open(XTEA_FILE, 'r') as f:
        # Load the data which is a dictionary (JSON object)
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(f"Error reading or parsing {XTEA_FILE}. Is it a valid JSON object? Error: {e}")
    exit(1)

# The dumper expects a list of objects (JSON array)
# like [{"region": 1234, "keys": [key1, key2, key3, key4]}, ...]
reformatted_data = []
for region_id, keys_list in data.items():
    # The original file might have keys as a list or a dict. We just need the values.
    # This handles both cases like {"keys": [1,2,3,4]} and just [1,2,3,4]
    key_values = keys_list if isinstance(keys_list, list) else keys_list.get("keys", [])
    
    reformatted_data.append({
        "region": int(region_id),
        "keys": key_values
    })

print(f"Successfully converted {len(reformatted_data)} regions.")

# Overwrite the original file with the new array-formatted data
with open(XTEA_FILE, 'w') as f:
    json.dump(reformatted_data, f)

print(f"Successfully wrote array-formatted data back to {XTEA_FILE}.")

