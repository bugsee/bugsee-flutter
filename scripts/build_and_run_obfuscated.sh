#!/bin/bash

pushd example
flutter build apk --obfuscate --split-debug-info=../build
popd
adb install ./app/build/app/outputs/apk/release/app-release.apk
