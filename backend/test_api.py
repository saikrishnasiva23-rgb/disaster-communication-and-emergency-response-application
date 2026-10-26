import requests

url = "http://127.0.0.1:5000/api/rescue-request"

data = {
    "name": "Test User",
    "emergencyType": "Medical Emergency",
    "numberOfPeople": 2,
    "injured": "Yes",
    "latitude": 11.9416,
    "longitude": 79.8083,
    "message": "Test rescue request"
}

response = requests.post(url, json=data)

print("Status Code:", response.status_code)
print("Response:")
print(response.json())