#!/bin/bash

flutter clean
flutter pub get

pushd ./example
flutter clean
flutter pub get
popd