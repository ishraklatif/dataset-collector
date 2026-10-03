#!/usr/bin/env python3
"""One-time local OAuth bootstrap for the collector's Google Drive archival.

Run this once on your own machine (never on the server) after creating a
"Desktop app" OAuth client in Google Cloud Console. It opens the consent
screen in your browser, catches the redirect on a one-shot local server, and
prints a refresh token to paste into the collector service's environment as
GOOGLE_OAUTH_REFRESH_TOKEN. Stdlib only; nothing is installed or written to
disk.
"""
import argparse
import json
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth'
TOKEN_URL = 'https://oauth2.googleapis.com/token'
SCOPE = 'https://www.googleapis.com/auth/drive.file'

def capture_redirect(port):
    captured = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            captured['code'] = query.get('code', [None])[0]
            captured['error'] = query.get('error', [None])[0]
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            message = 'Authorization complete. You can close this tab.' if captured.get('code') else 'Authorization failed; see the terminal.'
            self.wfile.write(f'<html><body>{message}</body></html>'.encode())

        def log_message(self, *args):
            pass

    server = HTTPServer(('127.0.0.1', port), Handler)
    server.handle_request()
    server.server_close()
    return captured

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client-id', required=True)
    parser.add_argument('--client-secret', required=True)
    parser.add_argument('--port', type=int, default=8765, help='Local port for the loopback redirect (default: 8765)')
    args = parser.parse_args()

    redirect_uri = f'http://localhost:{args.port}/'
    params = {
        'client_id': args.client_id, 'redirect_uri': redirect_uri, 'response_type': 'code',
        'scope': SCOPE, 'access_type': 'offline', 'prompt': 'consent',
    }
    auth_url = AUTH_URL + '?' + urllib.parse.urlencode(params)
    print('Opening a browser for Google sign-in. If it does not open, visit:\n' + auth_url + '\n')
    webbrowser.open(auth_url)

    result = capture_redirect(args.port)
    if not result.get('code'):
        raise SystemExit('Authorization failed: ' + (result.get('error') or 'no code received'))

    body = urllib.parse.urlencode({
        'code': result['code'], 'client_id': args.client_id, 'client_secret': args.client_secret,
        'redirect_uri': redirect_uri, 'grant_type': 'authorization_code',
    }).encode()
    request = urllib.request.Request(TOKEN_URL, data=body, method='POST',
        headers={'Content-Type': 'application/x-www-form-urlencoded'})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise SystemExit('Token exchange failed: ' + error.read().decode()) from error

    refresh_token = payload.get('refresh_token')
    if not refresh_token:
        raise SystemExit('Google did not return a refresh token. Revoke prior access at '
                          'https://myaccount.google.com/permissions and run this script again.')
    print('\nRefresh token (set this as GOOGLE_OAUTH_REFRESH_TOKEN on the server):\n')
    print(refresh_token)

if __name__ == '__main__':
    main()
