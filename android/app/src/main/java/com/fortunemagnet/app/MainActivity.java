package com.fortunemagnet.app;

import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.WebView;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.Nullable;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    private static final String BOOTSTRAP_JS = "" +
            "(function(){" +
            "  try {" +
            "    window.NativeUploaderAvailable = true;" +
            "    if (!window.NativeUploader) window.NativeUploader = {};" +
            "    if (!window.__nativeUploadResolvers) window.__nativeUploadResolvers = {};" +
            "    if (!window.__nativeUploadReqId) window.__nativeUploadReqId = 0;" +
            "    " +
            "    // Helper to set access token from web app's Supabase session" +
            "    function updateAccessToken(){" +
            "      try {" +
            "        if (window.AndroidNativeUploader && window.AndroidNativeUploader.setAccessToken) {" +
            "          var token = null;" +
            "          if (window.__SUPABASE_ACCESS_TOKEN__) token = window.__SUPABASE_ACCESS_TOKEN__;" +
            "          else if (window.supabase && window.supabase.auth) {" +
            "            var session = window.supabase.auth.session();" +
            "            if (session && session.access_token) token = session.access_token;" +
            "          }" +
            "          if (token) window.AndroidNativeUploader.setAccessToken(token);" +
            "        }" +
            "      } catch(e){}" +
            "    }" +
            "    " +
            "    // Update token periodically and on auth changes" +
            "    setInterval(updateAccessToken, 5000);" +
            "    updateAccessToken();" +
            "    " +
            "    window.NativeUploader.pickAndUploadFortunePhoto = function(options){" +
            "      return new Promise(function(resolve){" +
            "        try {" +
            "          updateAccessToken();" +
            "          var id = (++window.__nativeUploadReqId).toString();" +
            "          window.__nativeUploadResolvers[id] = resolve;" +
            "          var payload = { id: id, options: (options||{}) };" +
            "          " +
            "          // Include access token in options if available" +
            "          if (!payload.options.accessToken) {" +
            "            var token = null;" +
            "            if (window.__SUPABASE_ACCESS_TOKEN__) token = window.__SUPABASE_ACCESS_TOKEN__;" +
            "            else if (window.supabase && window.supabase.auth) {" +
            "              var session = window.supabase.auth.session();" +
            "              if (session && session.access_token) token = session.access_token;" +
            "            }" +
            "            if (token) payload.options.accessToken = token;" +
            "          }" +
            "          " +
            "          if (window.AndroidNativeUploader && window.AndroidNativeUploader.pickAndUploadFortunePhoto) {" +
            "            window.AndroidNativeUploader.pickAndUploadFortunePhoto(JSON.stringify(payload));" +
            "          } else {" +
            "            resolve({ cancelled: true });" +
            "          }" +
            "        } catch (e) {" +
            "          resolve({ cancelled: true });" +
            "        }" +
            "      });" +
            "    };" +
            "    window.__resolveNativeUpload = function(id, result){" +
            "      try { var fn = window.__nativeUploadResolvers[id]; if (fn) { fn(result||{cancelled:true}); } delete window.__nativeUploadResolvers[id]; } catch(_){}" +
            "    };" +
            "    try { window.dispatchEvent(new CustomEvent('native-uploader:availability', { detail: { available: true } })); } catch(e){}" +
            "  } catch (e) {}" +
            "})();";

    private boolean uploaderInjected = false;
    private NativeUploaderBridge uploaderBridge;
    private ActivityResultLauncher<Intent> photoPickerLauncher;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        
        // Register activity result launcher for photo picker
        photoPickerLauncher = registerForActivityResult(
            new ActivityResultContracts.StartActivityForResult(),
            result -> {
                if (uploaderBridge == null) {
                    return;
                }
                
                if (result.getResultCode() == RESULT_OK && result.getData() != null) {
                    Uri imageUri = result.getData().getData();
                    if (imageUri != null) {
                        uploaderBridge.handlePhotoPickerResult(imageUri);
                    } else {
                        uploaderBridge.handlePhotoPickerCancelled();
                    }
                } else {
                    uploaderBridge.handlePhotoPickerCancelled();
                }
            }
        );
    }

    @Override
    public void onStart() {
        super.onStart();
        if (uploaderInjected) return;

        final WebView webView = getBridge() != null ? getBridge().getWebView() : null;
        if (webView == null) return; // Bridge not ready yet

        // Create and expose Android interface used by the JS bootstrap above
        uploaderBridge = new NativeUploaderBridge(this, webView);
        webView.addJavascriptInterface(uploaderBridge, "AndroidNativeUploader");

        // Inject bootstrap after WebView is alive
        webView.post(() -> webView.evaluateJavascript(BOOTSTRAP_JS, null));

        uploaderInjected = true;
    }
    
    /**
     * Starts the photo picker activity using the registered launcher.
     * Called from NativeUploaderBridge.
     */
    public void startPhotoPicker(Intent intent, NativeUploaderBridge bridge) {
        photoPickerLauncher.launch(intent);
    }
    
    /**
     * Gets the server URL from Capacitor Bridge configuration.
     */
    public String getServerUrl() {
        if (getBridge() != null && getBridge().getServerUrl() != null) {
            return getBridge().getServerUrl();
        }
        return null;
    }
}
