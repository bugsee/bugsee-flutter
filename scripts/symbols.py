#!/usr/bin/python

import sys
import getopt
import re
import json
import hashlib
import tempfile
import glob
import os
from zipfile import ZipFile
from os import walk, path, unlink
import requests

API_BASE_URL = 'https://api.bugsee.com/v2/'


def _read_arguments():
    result_args = dict()
    argv = sys.argv[1:]

    try:
      opts, args = getopt.getopt(argv, "t:v:d:p:", ["token=","version=","symdir=","platform="])
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


def _extract_info_from_filename(filename):
    matches = re.match(r'(?:.*\.)([^.]+)\-([^\-]+)(\.symbols)$', filename)
    return {
        'platform': matches[1],
        'arch': matches[2]
    }


def _get_symbols_paths(symbols_dir):
    symbol_files = []
    filenames = map(lambda f: path.basename(f), glob.glob(f'{symbols_dir}/*.symbols'))
    symbol_files.extend(filenames)
    return symbol_files


def _create_symbols_manifest_as_string(symbol_files, application_version, target_platform):
    manifest_files = []
    for symbol_file in symbol_files:
        # TODO: extract arch info from file contents (ELF/DWARF data)
        symbols_info = _extract_info_from_filename(symbol_file)
        arch = symbols_info['arch']
        target_platform = target_platform if target_platform is not None else symbols_info['platform']
        manifest_files.append({
            'arch': arch,
            'uuid': _hash_string(f'{application_version}-{target_platform}-{arch}'),
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
    args = _read_arguments()

    app_token = args.get('t')
    symbols_dir = args.get('d')
    application_version = args.get('v') or _find_out_application_version()
    target_platform = args.get('p')
    symbol_files = _get_symbols_paths(symbols_dir)
    
    _, symbols_zip_path = tempfile.mkstemp()

    with ZipFile(symbols_zip_path, 'w') as symbols_zip:
        for symbol_file in symbol_files:
            symbols_zip.write(path.join(symbols_dir, symbol_file), symbol_file)
        manifest_str = _create_symbols_manifest_as_string(symbol_files, application_version, target_platform)
        symbols_zip.writestr('/manifest.json', manifest_str)

    request_uuid = _hash_string(f'{application_version}-{target_platform}-arm64'),
    raw_response = _send_request(f'{API_BASE_URL}apps/{app_token}/symbols', 'POST', {
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
        else:
            response_error = response.get('error')
            if response_error:
                print(response_error.get('type'))
            else:
                print('Failed to upload symbols bundle!')

    # remove the temporary file in regardless of the result
    unlink(symbols_zip_path)

if __name__ == "__main__":
   main()