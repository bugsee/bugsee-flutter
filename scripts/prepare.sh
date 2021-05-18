#!/bin/bash

pushd ./plugin
flutter clean
flutter pub get
popd

pushd ./app
flutter clean
flutter pub get
popd
