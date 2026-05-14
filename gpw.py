import logging
import os
import time

import requests


logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger("yvy.gpw")


def get_auth_token(username, password):
    url = "https://data-api.globalforestwatch.org/auth/token"
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    data = {
        "username": username,
        "password": password,
    }
    response = requests.post(url, headers=headers, data=data, timeout=30)
    if response.status_code == 200:
        token = response.json()["data"]["access_token"]
        logger.info("Authorization token obtained successfully.")
        return token

    logger.error("Failed to obtain auth token: %s - %s", response.status_code, response.text)
    return None


def create_api_key(auth_token, alias, email, organization, domains=None):
    url = "https://data-api.globalforestwatch.org/auth/apikey"
    headers = {
        "Authorization": f"Bearer {auth_token}",
        "Content-Type": "application/json",
    }
    data = {
        "alias": alias,
        "email": email,
        "organization": organization,
        "domains": domains or [],
    }
    response = requests.post(url, headers=headers, json=data, timeout=30)

    if 200 <= response.status_code < 300:
        api_key = response.json()["data"]["api_key"]
        logger.info("API key created successfully.")
        return api_key

    logger.error("Failed to create API key: %s - %s", response.status_code, response.text)
    return None


if __name__ == "__main__":
    username = os.getenv("GFW_USERNAME", "")
    password = os.getenv("GFW_PASSWORD", "")
    email = os.getenv("GFW_EMAIL", "")
    organization = os.getenv("GFW_ORGANIZATION", "dev")
    alias = os.getenv("GFW_API_KEY_ALIAS", f"api-key-yvy-{int(time.time())}")

    if not username or not password or not email:
        raise SystemExit("Set GFW_USERNAME, GFW_PASSWORD, and GFW_EMAIL before running this script.")

    auth_token = get_auth_token(username, password)
    if auth_token:
        api_key = create_api_key(auth_token, alias, email, organization)
        if api_key:
            print(api_key)
        else:
            raise SystemExit("Failed to create API key.")
    else:
        raise SystemExit("Failed to obtain authorization token.")
