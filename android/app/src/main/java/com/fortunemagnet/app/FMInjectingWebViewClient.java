package com.fortunemagnet.app;

import android.graphics.Bitmap;
import android.webkit.WebView;
import androidx.annotation.NonNull;

import com.getcapacitor.Bridge;
import com.getcapacitor.BridgeWebViewClient;

public class FMInjectingWebViewClient extends BridgeWebViewClient {
    private final String bridgeJs;

    public FMInjectingWebViewClient(@NonNull Bridge bridge) {
        super(bridge);
        this.bridgeJs = "(function(){try{var Cap=window.Capacitor||{};var Plugins=Cap.Plugins||{};var Camera=Plugins.Camera||{};var CameraResultType=Camera.CameraResultType||(Plugins.Camera&&Plugins.CameraResultType)||{};var CameraSource=Camera.CameraSource||(Plugins.Camera&&Plugins.CameraSource)||{};async function pickImage(opts){try{var sourceMap={prompt:CameraSource.Prompt,camera:CameraSource.Camera,photos:CameraSource.Photos};var photo=await Camera.getPhoto({resultType:CameraResultType.DataUrl,quality:(opts&&opts.quality)??80,allowEditing:(opts&&opts.allowEditing)??false,source:sourceMap[(opts&&opts.source)||'prompt']});return(photo&&photo.dataUrl)?{dataUrl:photo.dataUrl}:null;}catch(e){return null;}}window.FMNative={isNative:function(){return true;},pickImage:pickImage};}catch(e){}})();";
    }

    @Override
    public void onPageStarted(WebView view, String url, Bitmap favicon) {
        super.onPageStarted(view, url, favicon);
        try {
            view.evaluateJavascript(bridgeJs, null);
        } catch (Exception ignored) { }
    }
}