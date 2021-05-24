#!/bin/bash

rm -rf ./build

pushd example
flutter build apk --obfuscate --split-debug-info=../build
popd
adb install ./example/build/app/outputs/apk/release/app-release.apk
