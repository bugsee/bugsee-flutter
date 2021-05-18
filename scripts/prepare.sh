#!/bin/bash

flutter clean

pushd ./example
flutter clean
popd

flutter pub get