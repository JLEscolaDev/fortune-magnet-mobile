Title: Mobile shell (iOS/Android) with Capacitor loading remote web + FMNative bridge

Summary
- Add Capacitor project with iOS and Android native projects
- Load remote URL via MOBILE_REMOTE_URL (default https://fortune-magnet.vercel.app)
- Inject window.FMNative with isNative() and pickImage() using @capacitor/camera
- iOS: WKUserScript injection at document-start
- Android: custom WebViewClient injects bridge JS on page start
- Add permissions (iOS Camera/Photo Library)
- Scripts: mobile:init/add/sync/ios/android
- Docs in docs/mobile.md

Verification
- npm run mobile:ios / mobile:android and run in simulator/device
- In the site console: await window.FMNative?.pickImage()

CI
- Add workflow to run npm ci and npx cap sync
