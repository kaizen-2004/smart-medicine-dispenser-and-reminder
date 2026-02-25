# App Bootstrap Notes

This directory contains the Flutter app source and Android config scaffold.

If this is the first setup on your machine and Gradle wrapper files are missing, run:

```bash
cd app
flutter create --platforms android .
```

Then run:

```bash
flutter pub get
flutter run -d <android-device-id>
```

## Release Build

1. Create keystore (one time):

```bash
cd android
keytool -genkey -v \
  -keystore ../upload-keystore.jks \
  -alias upload \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000
```

2. Configure signing:

```bash
cd android
cp key.properties.example key.properties
```

Edit `android/key.properties` with your passwords and alias.

3. Build:

```bash
flutter clean
flutter pub get
flutter build appbundle --release
flutter build apk --release
```

Artifacts:
- `build/app/outputs/bundle/release/app-release.aab`
- `build/app/outputs/flutter-apk/app-release.apk`
