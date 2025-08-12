# Fortune Magnet Mobile Shell

This repo provides a Capacitor-based native shell for iOS and Android that loads the remote web app inside a WebView and exposes a tiny native bridge `window.FMNative` for camera/gallery.

- Remote URL: `MOBILE_REMOTE_URL` (default: https://fortune-magnet.vercel.app)
- No changes in the web app are required. The bridge is safe if unused.

## Prerequisites
- Node.js >= 18
- Xcode (for iOS)
- Android Studio + SDKs (for Android)

## Setup
```bash
cp .env.example .env   # optional; edit MOBILE_REMOTE_URL if needed
npm install
npm run mobile:init
npm run mobile:add:ios
npm run mobile:add:android
```

## Run projects
```bash
npm run mobile:ios      # opens Xcode
npm run mobile:android  # opens Android Studio
```

## Bridge API
```ts
interface FMNativeApi {
  isNative(): boolean;
  pickImage(options?: {
    quality?: number;
    allowEditing?: boolean;
    source?: 'prompt' | 'camera' | 'photos';
  }): Promise<{ dataUrl: string } | null>;
}
```

Test in the loaded site console:
```js
await window.FMNative?.pickImage(); // -> { dataUrl } on device, null on desktop
```

## Permissions
- iOS: Camera and Photo Library usage descriptions added in `ios/App/App/Info.plist`.
- Android: `@capacitor/camera` handles runtime permissions.

## CI
A lightweight workflow runs `npm ci` and `npx cap sync`.