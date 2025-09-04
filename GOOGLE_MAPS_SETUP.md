# Google Maps Setup Guide

## Problem: Blank Google Maps Display

If you see Google Maps controls (icons, buttons) but a blank/white map area, this indicates that the Google Maps API key is missing or invalid.

## Solution: Configure Google Maps API Key

### Step 1: Get Google Maps API Key

1. **Go to Google Cloud Console**: https://console.cloud.google.com/
2. **Create or select a project**
3. **Enable APIs**:
   - Navigate to "APIs & Services" > "Library"
   - Search for "Maps SDK for Android"
   - Click on it and press "ENABLE"
4. **Create API Key**:
   - Go to "APIs & Services" > "Credentials"
   - Click "CREATE CREDENTIALS" > "API key"
   - Copy your new API key

### Step 2: Add API Key to Your App

1. **Open AndroidManifest.xml**:
   ```
   c:\a\drone_app\android\app\src\main\AndroidManifest.xml
   ```

2. **Find this line** (around line 18):
   ```xml
   android:value="YOUR_GOOGLE_MAPS_API_KEY"
   ```

3. **Replace with your actual API key**:
   ```xml
   android:value="AIzaSyC4YK6mVvXX..." <!-- Your actual API key here -->
   ```

### Step 3: (Optional) Secure Your API Key

For production apps, restrict your API key:

1. **In Google Cloud Console**, go to your API key
2. **Click "EDIT"**
3. **Under "Application restrictions"**:
   - Select "Android apps"
   - Add package name: `com.example.drone_app`
   - Add your app's SHA-1 fingerprint

### Step 4: Rebuild and Test

```bash
flutter clean
flutter build apk --debug
```

## Fallback Options

If you don't want to set up Google Maps API key right now:

1. **Use the backup map**: The app will automatically show a "Use Backup Map" button when Google Maps fails
2. **FlutterMap fallback**: The small map uses FlutterMap which doesn't require API keys
3. **Temporary solution**: You can use the 2D fallback maps for basic functionality

## Troubleshooting

### Still seeing blank maps?

1. **Check API key**: Make sure there are no extra spaces or characters
2. **Check quotas**: Ensure your Google Cloud project has Maps API quota
3. **Check network**: Ensure your device has internet connectivity
4. **Check logs**: Look for Google Maps related errors in the console

### Error: "Google Maps API key not specified"

- Double-check that you've replaced `YOUR_GOOGLE_MAPS_API_KEY` with your actual key
- Ensure the key is inside double quotes
- Rebuild the app after making changes

### Map loads but shows "For development purposes only"

- This means your API key works but isn't properly restricted
- Add billing information to your Google Cloud project
- This watermark won't affect functionality during development

## Features Available with Google Maps

✅ **3D Buildings**: Realistic 3D building visualization  
✅ **Satellite Imagery**: High-quality satellite views  
✅ **Tilt and Rotation**: Full 3D navigation controls  
✅ **Chinese Labels**: Proper Chinese language support (hl=zh-TW)  
✅ **Smooth Performance**: Optimized for mobile devices  

## Features with FlutterMap Fallback

✅ **2D Maps**: Standard map display  
✅ **Satellite Views**: Basic satellite imagery  
✅ **Markers**: Drone and phone location markers  
✅ **Zoom/Pan**: Basic map navigation  
❌ **3D Buildings**: Not available  
❌ **Tilt Controls**: Limited 3D features  

---

**Note**: The app is designed to work with or without Google Maps API key. The fallback system ensures your drone application remains functional even without 3D map features.