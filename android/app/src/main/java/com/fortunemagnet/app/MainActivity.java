package com.fortunemagnet.app;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;
import com.getcapacitor.Bridge;

public class MainActivity extends BridgeActivity {
  @Override
  public void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    Bridge bridge = this.bridge;
    if (bridge != null && bridge.getWebView() != null) {
      bridge.getWebView().setWebViewClient(new FMInjectingWebViewClient(bridge));
    }
  }
}
