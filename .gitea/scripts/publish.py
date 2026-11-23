#!/usr/bin/env python3
"""Publish every cookbook version that is not yet in the static supermarket.

The supermarket is an S3 bucket (homelab-infra apps/seaweedfs/terraform/chef-supermarket.tf).
chef-cli's supermarket source reads only <site>/universe, the dependency graph with a download_url
per version, and then downloads those tarballs; so the bucket holds that one JSON object plus one
tarball per version. Versions are immutable: an existing tarball is never overwritten.

Stdlib only, so it runs in the Cinc Workstation image as is; knife is used solely to render
metadata.json, because metadata.rb is Ruby and only Chef evaluates it faithfully.
Env: S3_URL (https://s3.lab.ddupan.top/chef-supermarket) and either BAO_ADDR + BAO_TOKEN +
BAO_S3_SECRET (KV path of the publisher keys) or AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY.
Usage: publish.py <cookbooks dir>
"""
import datetime
import hashlib
import hmac
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

REGION = 'us-east-1'  # SeaweedFS ignores it, but it is part of the signature scope.


def sigv4_headers(method, url, body, key, secret, now=None):
    """AWS Signature V4 for S3: sign host, payload hash and date; nothing else is needed."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    u = urllib.parse.urlsplit(url)
    amz_date = now.strftime('%Y%m%dT%H%M%SZ')
    payload = hashlib.sha256(body).hexdigest()
    headers = {'host': u.netloc, 'x-amz-content-sha256': payload, 'x-amz-date': amz_date}
    signed = ';'.join(sorted(headers))
    canonical = '\n'.join([method, u.path or '/', u.query,
                           ''.join(f'{k}:{headers[k]}\n' for k in sorted(headers)), signed, payload])
    scope = f'{amz_date[:8]}/{REGION}/s3/aws4_request'
    to_sign = '\n'.join(['AWS4-HMAC-SHA256', amz_date, scope,
                         hashlib.sha256(canonical.encode()).hexdigest()])
    k = ('AWS4' + secret).encode()
    for part in (amz_date[:8], REGION, 's3', 'aws4_request'):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    headers['authorization'] = (f'AWS4-HMAC-SHA256 Credential={key}/{scope}, '
                                f'SignedHeaders={signed}, Signature={signature}')
    del headers['host']  # urllib sets Host from the URL; it is the same value that was signed.
    return headers


def credentials():
    """S3 keys from OpenBao (CI: BAO_ADDR/BAO_TOKEN from spiffe-openbao-login), else from env."""
    if 'AWS_ACCESS_KEY_ID' in os.environ:
        return os.environ['AWS_ACCESS_KEY_ID'], os.environ['AWS_SECRET_ACCESS_KEY']
    req = urllib.request.Request(
        os.environ['BAO_ADDR'].rstrip('/') + '/v1/kv/data/' + os.environ['BAO_S3_SECRET'],
        headers={'X-Vault-Token': os.environ['BAO_TOKEN']})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)['data']['data']
    return data['access_key'], data['secret_key']


CREDS = None


def s3(method, url, body=b'', content_type=None):
    """Return (status, body). 4xx is an answer, not a failure; network errors and 5xx retry."""
    global CREDS
    CREDS = CREDS or credentials()
    for attempt in range(5):
        headers = sigv4_headers(method, url, body, *CREDS)
        if content_type:
            headers['content-type'] = content_type
        req = urllib.request.Request(url, data=body if method == 'PUT' else None,
                                     method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            if e.code < 500:
                return e.code, e.read()
            err = f'HTTP {e.code}'
        except urllib.error.URLError as e:
            err = str(e.reason)
        print(f'{method} {url}: {err}, retrying', file=sys.stderr)
        time.sleep(2 ** attempt)
    sys.exit(f'{method} {url}: giving up after {err}')


def version_of(cookbook):
    return re.search(r"""^version\s+['"]([^'"]+)""", (cookbook / 'metadata.rb').read_text(),
                     re.M).group(1)


def package(cookbook):
    """Tarball laid out like `knife supermarket share`: <name>/ with a rendered metadata.json."""
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / cookbook.name
        shutil.copytree(cookbook, work)
        subprocess.run(['knife', 'cookbook', 'metadata', 'from', 'file', str(work / 'metadata.rb')],
                       check=True, capture_output=True)
        deps = json.loads((work / 'metadata.json').read_text())['dependencies']
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w:gz') as tar:
            tar.add(work, arcname=cookbook.name)
    return buf.getvalue(), deps


def add_version(universe, site, name, version, deps):
    """The universe entry chef-cli needs; it reads only download_url and dependencies."""
    universe.setdefault(name, {})[version] = {
        'location_type': 'uri',
        'location_path': site,
        'download_url': f'{site}/{name}-{version}.tar.gz',
        'dependencies': deps,
    }
    return universe


def main(root):
    site = os.environ['S3_URL'].rstrip('/')
    code, body = s3('GET', f'{site}/universe')
    if code == 404:
        universe = {}
    elif code == 200:
        universe = json.loads(body)
    else:
        sys.exit(f'GET universe: HTTP {code} {body[:300]!r}')

    for cookbook in sorted(p for p in pathlib.Path(root).iterdir() if (p / 'metadata.rb').exists()):
        name, version = cookbook.name, version_of(cookbook)
        if version in universe.get(name, {}):
            print(f'{name} {version} already published')
            continue
        url = f'{site}/{name}-{version}.tar.gz'
        code, _ = s3('HEAD', url)
        if code != 404:
            # A tarball outside the universe means an earlier run died between the two PUTs.
            # Do not guess whether it matches this tree; look at it and fix the universe by hand.
            sys.exit(f'{url} exists (HTTP {code}) but is not in universe; refusing to overwrite')
        tarball, deps = package(cookbook)
        code, body = s3('PUT', url, tarball, 'application/gzip')
        if code != 200:
            sys.exit(f'PUT {url}: HTTP {code} {body[:300]!r}')
        add_version(universe, site, name, version, deps)
        # Write the universe after every cookbook so a later failure keeps earlier publishes visible.
        code, body = s3('PUT', f'{site}/universe',
                        json.dumps(universe, indent=1, sort_keys=True).encode(), 'application/json')
        if code != 200:
            sys.exit(f'PUT universe: HTTP {code} {body[:300]!r}')
        print(f'{name} {version} published')


if __name__ == '__main__':
    main(sys.argv[1])
