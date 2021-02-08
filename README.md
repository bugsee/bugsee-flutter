Installation and configuration instructions

## 1. Install latest Flutter and Dart SDK. If you already have both, run the following to update Flutter

```
flutter upgrade
```

## 2. Install the required dependecies for both plugin and test app.

```
# For plugin
cd plugin
flutter pub get

# For application
cd app
flutter pub get
```

## 3. Finally, as the starting point, you should pick the "app/lib/main.dart" when setting up the launch configuration in your preferred IDE.
