"""Google Drive upload for cold-archiving approved samples. No disk spooling.

Buffers the full ZIP in memory (bounded by MAX_ARCHIVE_BYTES in app.py)
rather than streaming chunk-by-chunk to Drive: the caller must know upload
succeeded before deleting anything from Postgres, so the total size is known
before the first Drive request anyway, which lets us use Google's documented
single-request path through the resumable upload endpoint and skip the
256 KiB chunk-alignment / 308-resume protocol entirely.
"""
import hashlib
import json
import time
import urllib.error
import urllib.request

TOKEN_URL = 'https://oauth2.googleapis.com/token'
UPLOAD_URL = 'https://www.googleapis.com/upload/drive/v3/files'

class DriveError(Exception):
    pass

class DriveClient:
    def __init__(self, client_id, client_secret, refresh_token, folder_id):
        self.client_id, self.client_secret = client_id, client_secret
        self.refresh_token, self.folder_id = refresh_token, folder_id
        self._access_token, self._expires_at = None, 0.0

    def _access(self):
        if self._access_token and time.time() < self._expires_at - 60:
            return self._access_token
        body = json.dumps({'client_id': self.client_id, 'client_secret': self.client_secret,
                            'refresh_token': self.refresh_token, 'grant_type': 'refresh_token'}).encode()
        req = urllib.request.Request(TOKEN_URL, data=body, method='POST',
                                      headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                payload = json.loads(resp.read())
        except urllib.error.URLError as error:
            raise DriveError('Google token refresh failed') from error
        self._access_token = payload['access_token']
        self._expires_at = time.time() + payload.get('expires_in', 3600)
        return self._access_token

    def upload_zip(self, data, filename):
        access = self._access()
        meta = json.dumps({'name': filename, 'parents': [self.folder_id]}).encode()
        init = urllib.request.Request(
            UPLOAD_URL + '?uploadType=resumable&fields=id,webViewLink,size,md5Checksum',
            data=meta, method='POST',
            headers={'Authorization': 'Bearer ' + access, 'Content-Type': 'application/json; charset=UTF-8',
                     'X-Upload-Content-Type': 'application/zip', 'X-Upload-Content-Length': str(len(data))})
        try:
            with urllib.request.urlopen(init, timeout=20) as resp:
                session_url = resp.headers.get('Location')
        except urllib.error.URLError as error:
            raise DriveError('Could not start Drive upload session') from error
        if not session_url:
            raise DriveError('Drive did not return an upload session URL')
        return self._put_with_retry(session_url, data, access)

    def _put_with_retry(self, session_url, data, access, attempts=3):
        total, last_error = len(data), None
        for attempt in range(attempts):
            put = urllib.request.Request(session_url, data=data, method='PUT',
                headers={'Authorization': 'Bearer ' + access, 'Content-Type': 'application/zip',
                         'Content-Range': f'bytes 0-{total-1}/{total}'})
            try:
                with urllib.request.urlopen(put, timeout=120) as resp:
                    return self._verify(json.loads(resp.read()), data)
            except (urllib.error.URLError, TimeoutError) as error:
                last_error = error
                if attempt < attempts - 1:
                    probed = self._probe(session_url, access, total)
                    if probed is not None:
                        return self._verify(probed, data)
                    continue
        raise DriveError(f'Drive upload failed after {attempts} attempts: {last_error}')

    def _probe(self, session_url, access, total):
        # Checks whether Drive actually finished the upload despite a client-side
        # timeout/error, to avoid uploading a duplicate file on retry.
        probe = urllib.request.Request(session_url, data=b'', method='PUT',
            headers={'Authorization': 'Bearer ' + access, 'Content-Range': f'bytes */{total}',
                     'Content-Length': '0'})
        try:
            with urllib.request.urlopen(probe, timeout=20) as resp:
                return json.loads(resp.read()) if resp.status in (200, 201) else None
        except urllib.error.HTTPError:
            return None

    def _verify(self, result, data):
        if 'id' not in result:
            raise DriveError('Drive response missing file id')
        if result.get('size') is not None and int(result['size']) != len(data):
            raise DriveError('Drive-reported size does not match uploaded bytes')
        if result.get('md5Checksum') and result['md5Checksum'] != hashlib.md5(data).hexdigest():
            raise DriveError('Drive-reported checksum does not match uploaded bytes')
        return result
