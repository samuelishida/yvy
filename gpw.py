import requests
import time

def get_auth_token(username, password):
    url = 'https://data-api.globalforestwatch.org/auth/token'
    headers = {'Content-Type': 'application/x-www-form-urlencoded'}
    data = {
        'username': username,
        'password': password
    }
    response = requests.post(url, headers=headers, data=data)
    print(f"Response status code: {response.status_code}")
    print(f"Response text: {response.text}")
    if response.status_code == 200:
        token = response.json()['data']['access_token']
        print("Authorization token obtained successfully.")
        return token
    else:
        print(f"Failed to obtain auth token: {response.status_code} - {response.text}")
        return None



# Function to create an API key
def create_api_key(auth_token, alias, email, organization, domains=[]):
    url = 'https://data-api.globalforestwatch.org/auth/apikey'
    headers = {
        'Authorization': f'Bearer {auth_token}',
        'Content-Type': 'application/json'
    }
    data = {
        'alias': alias,
        'email': email,
        'organization': organization,
        'domains': domains
    }
    response = requests.post(url, headers=headers, json=data)
    print(f"Response status code: {response.status_code}")
    print(f"Response text: {response.text}")

    # Check if status code is in the 2xx range
    if response.status_code >= 200 and response.status_code < 300:
        api_key = response.json()['data']['api_key']
        print("API key created successfully.")
        return api_key
    else:
        print(f"Failed to create API key: {response.status_code} - {response.text}")
        return None


# Usage example
if __name__ == "__main__":
    # Replace these with your actual credentials and information
    username = 'samuelwinston420@gmail.com'       # Your GFW username
    password = 'hcUK1MZm.'       # Your GFW password
    email = 'samuelwinston420@gmail.com' # Your email associated with GFW
    organization = 'dev'
    alias = f"api-key-ivy-{int(time.time())}"
    domains = []                     # List of domains, leave empty if not applicable

    # Obtain the authorization token
    auth_token = get_auth_token(username, password)
    if auth_token:
        # Create the API key
        api_key = create_api_key(auth_token, alias, email, organization, domains)
        if api_key:
            print(f"Your new API key is: {api_key}")
        else:
            print("Failed to create API key.")
    else:
        print("Failed to obtain authorization token.")
