#!/usr/bin/python

import sys
import getopt
import re
import json
import hashlib
import tempfile
import glob
import os
import binascii
from zipfile import ZipFile
from os import walk, path, unlink
import requests

API_BASE_URL = 'https://api.bugsee.com/v2/'


def _read_arguments():
    result_args = dict()
    argv = sys.argv[1:]

    try:
      opts, args = getopt.getopt(argv, "t:v:d:e:", ["token=","version=","symdir=","endpoint="])
    except getopt.GetoptError:
      print('Failed to read arguments')
      sys.exit(2)
    
    for opt, arg in opts:
        clean_arg_name = re.sub('^\-+', '', opt)
        result_args[clean_arg_name] = arg
    
    return result_args


def _hash_string(val):
    hash_object = hashlib.sha1(b'Hello World')
    return str(hash_object.hexdigest())


def _find_out_application_version():
    yaml_file_path = path.join(os.getcwd(), 'pubspec.yaml')
    if os.path.isfile(yaml_file_path):
        with open(yaml_file_path, 'r') as yaml_file:
            yaml_str = yaml_file.read()
        match_result = re.search(r'(version:\s*)([^\n\r]+)', yaml_str)
        if match_result:
            return match_result[2]

    return ''

def _get_file_hash(filename):
    h = hashlib.sha1()

    with open(filename, 'rb') as symbol_file_stream:
        chunk = 0
        while chunk != b'':
            chunk = symbol_file_stream.read(1024)
            h.update(chunk)
        
    return h.hexdigest()


# Flutter names its split-debug-info files after the TARGET PLATFORM, and that
# vocabulary is not the one symbol files are keyed by: Flutter writes
# `app.android-x64.symbols` where a symbol file -- and therefore the backend --
# spells the same architecture `x86_64`. Everything else Flutter can emit
# (`arm`, `arm64`, `x86`) is already spelled the same way in both, so this table
# has a single entry and is expected to stay small.
#
# Sending an untranslated name is not merely untidy. The architecture recorded
# on a symbol file is what the backend matches against, so a value outside its
# vocabulary can never line up with the crash it belongs to.
#
# See report-bundle-structure, bundle/crash.md "Architecture vocabulary".
_ARCH_BY_FLUTTER_NAME = {
    'x64': 'x86_64',
}


def _extract_info_from_filename(filename):
    matches = re.match(r'(?:.*\.)([^.]+)\-([^\-]+)(\.symbols)$', filename)
    flutter_arch = matches[2]
    return {
        'platform': matches[1],
        'arch': _ARCH_BY_FLUTTER_NAME.get(flutter_arch, flutter_arch)
    }


def _get_symbols_paths(symbols_dir):
    symbol_files = []
    filenames = map(lambda f: path.basename(f), glob.glob(f'{symbols_dir}/*.symbols'))
    symbol_files.extend(filenames)
    return symbol_files


def _create_symbols_manifest_as_string(symbols_dir, symbol_files, application_version):
    manifest_files = []
    for symbol_file in symbol_files:
        symbols_info = _extract_info_from_filename(symbol_file)
        manifest_files.append({
            'arch': symbols_info['arch'],
            'uuid': _get_file_hash(path.join(symbols_dir, symbol_file)),
            'entry': symbol_file,
            'version': application_version,
            'build': ''
        })
    return json.dumps({ 'target': 'flutter', 'items': manifest_files })


def _send_request(url, method, data):
    response = None

    if method == 'PUT':
        response = requests.put(url, data=data, headers={})
    elif method == 'POST':
        headers = { 'Content-type': 'application/json' }
        response = requests.post(url, None, json=data, headers=headers)

    if response.ok:
        return response.text or '{}'

    return None


def main():
    exit_result = 0

    args = _read_arguments()

    endpoint_base = args.get('e') or API_BASE_URL
    app_token = args.get('t')
    symbols_dir = args.get('d')
    application_version = args.get('v') or _find_out_application_version()
    symbol_files = _get_symbols_paths(symbols_dir)

    if len(symbol_files) > 0:
        _, symbols_zip_path = tempfile.mkstemp()

        with ZipFile(symbols_zip_path, 'w') as symbols_zip:
            for symbol_file in symbol_files:
                symbols_zip.write(path.join(symbols_dir, symbol_file), symbol_file)
            manifest_str = _create_symbols_manifest_as_string(symbols_dir, symbol_files, application_version)
            symbols_zip.writestr('/manifest.json', manifest_str)
        
        # we need to provide proper unique UUID here to prevent duplicated debug symbols
        # error from server
        request_uuid = _get_file_hash(path.join(symbols_dir, symbol_files[0]))
        raw_response = _send_request(f'{endpoint_base}apps/{app_token}/symbols', 'POST', {
            'uuid': request_uuid,
            'version': application_version,
            'build': '0'
        })

        if raw_response:
            response = json.loads(raw_response)
            if response.get('ok'):
                endpoint = response.get('result', {}).get('endpoint')
                with open(symbols_zip_path, 'rb') as symbols_bundle:
                    response = _send_request(endpoint, 'PUT', symbols_bundle)
                    if response is None:
                        print('Failed to upload symbols bundle!')
                        exit_result = 1
            else:
                response_error = response.get('error')
                if response_error:
                    error_message = response_error.get('type')
                    print(f'Failed to upload symbols bundle: {error_message}!')
                    exit_result = 1
                else:
                    print('Failed to upload symbols bundle!')
                    exit_result = 1

        # remove the temporary file in regardless of the result
        unlink(symbols_zip_path)

    return exit_result

if __name__ == "__main__":
   exit(main())