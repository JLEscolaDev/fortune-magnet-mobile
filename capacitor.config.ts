import { CapacitorConfig } from '@capacitor/cli';

const remoteUrl = process.env.MOBILE_REMOTE_URL || 'https://fortune-magnet.vercel.app';

const config: CapacitorConfig = {
  appId: 'com.fortunemagnet.app',
  appName: 'Fortune Magnet',
  webDir: 'dist',
  bundledWebRuntime: false,
  server: remoteUrl ? { url: remoteUrl, cleartext: false } : undefined,
  ios: { contentInset: 'automatic' },
  android: { allowMixedContent: false },
};

export default config;
