import Foundation
import UIKit
import Capacitor

/**
 * Native bridge for photo picker and upload functionality on iOS.
 * 
 * Architecture:
 * 1. Simple Photo Picker (NEW): Exposes window.NativePhotoPicker.pickPhoto()
 *    - Only handles photo picking, returns bytes + metadata
 *    - Upload is handled by Lovable's TypeScript code (processAndUpload)
 *    - Uses supabase.storage.uploadToSignedUrl() which correctly uses PUT
 * 
 * 2. Legacy Uploader (BACKWARDS COMPATIBILITY): Exposes window.NativeUploader.pickAndUploadFortunePhoto()
 *    - Handles full pipeline: pick → upload → finalize
 *    - Kept for backwards compatibility
 *    - Will be deprecated once all clients use the new picker
 */
@objc class NativeUploaderBridge: NSObject {
    private static let TAG = "NativeUploaderBridge"
    private static let NATIVE_UPLOADER_IMPL_VERSION = "ios-injected-v3-2026-01-18"
    private static let NATIVE_PHOTO_PICKER_VERSION = "ios-picker-v1-2026-01-23"
    
    weak var bridgeViewController: CAPBridgeViewController?
    
    init(bridgeViewController: CAPBridgeViewController) {
        self.bridgeViewController = bridgeViewController
        super.init()
    }
    
    func injectJavaScript() {
        // Inject simplified photo picker (new approach)
        injectSimplePhotoPicker()
        
        // Keep legacy uploader for backwards compatibility
        injectLegacyUploader()
    }
    
    /// Injects simplified photo picker that only handles picking, not uploading
    private func injectSimplePhotoPicker() {
        let pickerJS = """
        (function(){
          try {
            var IMPL_VERSION = "\(NativeUploaderBridge.NATIVE_PHOTO_PICKER_VERSION)";
            
            // Check if already installed
            if (window.NativePhotoPicker && window.NativePhotoPicker.__impl) {
              console.log("[NativePhotoPicker] Already installed:", window.NativePhotoPicker.__impl);
              return;
            }
            
            console.log("[NativePhotoPicker] Initializing simple photo picker bridge");
            
            // Simple photo picker - uses Capacitor Camera plugin directly
            // Returns image bytes to web code, which handles upload via processAndUpload()
            window.NativePhotoPicker = {
              __impl: IMPL_VERSION,
              
              pickPhoto: function() {
                console.log("[NativePhotoPicker] pickPhoto called");
                
                return new Promise(async function(resolve, reject) {
                  try {
                    // Use Capacitor Camera plugin to pick photo
                    if (typeof Capacitor === 'undefined' || !Capacitor.Plugins || !Capacitor.Plugins.Camera) {
                      console.error("[NativePhotoPicker] Capacitor Camera plugin not available");
                      reject(new Error('Camera plugin not available'));
                      return;
                    }
                    
                    console.log("[NativePhotoPicker] Opening photo picker...");
                    var cameraResult = await Capacitor.Plugins.Camera.getPhoto({
                      quality: 90,
                      allowEditing: false,
                      source: 'PHOTOS',
                      resultType: 'Uri',
                      correctOrientation: true
                    });
                    
                    console.log("[NativePhotoPicker] Camera result received");
                    
                    // Check if cancelled
                    if (cameraResult === null || cameraResult === undefined) {
                      console.log("[NativePhotoPicker] User cancelled photo selection");
                      resolve({ cancelled: true });
                      return;
                    }
                    
                    var webPath = cameraResult.webPath || cameraResult.path || '';
                    if (!webPath) {
                      console.log("[NativePhotoPicker] No webPath or path in result");
                      resolve({ cancelled: true });
                      return;
                    }
                    
                    console.log("[NativePhotoPicker] Photo selected, loading from:", webPath.substring(0, 100));
                    
                    // Load image from URI to get bytes
                    var fileResp = await fetch(webPath);
                    var blob = await fileResp.blob();
                    var mimeType = blob.type || 'image/jpeg';
                    var buf = await blob.arrayBuffer();
                    var imageBytes = new Uint8Array(buf);
                    
                    // Get dimensions
                    var width = cameraResult.width || 0;
                    var height = cameraResult.height || 0;
                    
                    // If dimensions not provided, load image to get them
                    if (!width || !height) {
                      var img = new Image();
                      img.src = webPath;
                      await new Promise(function(imgResolve, imgReject) {
                        img.onload = function() {
                          width = img.width;
                          height = img.height;
                          imgResolve();
                        };
                        img.onerror = function() {
                          // Still return bytes even if we can't get dimensions
                          width = 0;
                          height = 0;
                          imgResolve();
                        };
                        setTimeout(function() {
                          width = 0;
                          height = 0;
                          imgResolve();
                        }, 5000);
                      });
                    }
                    
                    var result = {
                      bytes: imageBytes,
                      mimeType: mimeType,
                      width: width,
                      height: height,
                      cancelled: false
                    };
                    
                    console.log("[NativePhotoPicker] Photo converted: " + result.bytes.length + " bytes, " + result.width + "x" + result.height);
                    resolve(result);
                    
                  } catch (error) {
                    console.error("[NativePhotoPicker] Error picking photo:", error);
                    var errorMsg = error && (error.message || String(error)) || 'Unknown error';
                    var lowerErrorMsg = errorMsg.toLowerCase();
                    
                    // Treat camera cancellation as cancelled, not error
                    if (lowerErrorMsg.indexOf('cancel') !== -1 || lowerErrorMsg.indexOf('cancelled') !== -1) {
                      console.log("[NativePhotoPicker] Camera error indicates cancellation");
                      resolve({ cancelled: true });
                    } else {
                      reject(error);
                    }
                  }
                });
              }
            };
            
            // Mark picker as available
            window.NativePhotoPickerAvailable = true;
            
            console.log("[NativePhotoPicker] Bridge initialized - simplified picker ready");
            
          } catch (e) {
            console.error("[NativePhotoPicker] Failed to initialize:", e);
          }
        })();
        """
        
        guard let webView = bridgeViewController?.webView else {
            print("\(NativeUploaderBridge.TAG): WebView not available for photo picker injection")
            return
        }
        
        // Inject JavaScript
        webView.evaluateJavaScript(pickerJS) { result, error in
            if let error = error {
                print("\(NativeUploaderBridge.TAG): Failed to inject photo picker: \(error)")
            } else {
                print("\(NativeUploaderBridge.TAG): Simple photo picker injected successfully")
            }
        }
    }
    
    /// Legacy uploader (kept for backwards compatibility)
    private func injectLegacyUploader() {
        let bootstrapJS = """
        (function(){
          try {
            var IMPL_VERSION = "\(NativeUploaderBridge.NATIVE_UPLOADER_IMPL_VERSION)";
            
            // Check if NativeUploader already exists with __impl defined (versioned implementation)
            if (window.NativeUploader && window.NativeUploader.__impl) {
              console.log("[NATIVE-UPLOADER][INJECTED] existing implementation detected, skipping install", window.NativeUploader.__impl);
              return; // Do NOT overwrite versioned implementation
            }
            
            // If NativeUploader exists but has no __impl, log warning but still install
            if (window.NativeUploader && !window.NativeUploader.__impl) {
              console.log("[NATIVE-UPLOADER][INJECTED] overriding non-versioned NativeUploader");
            }
            
            if (typeof window.NativeUploaderAvailable === 'undefined') {
              window.NativeUploaderAvailable = true;
            }
            if (!window.NativeUploader) window.NativeUploader = {};
            if (!window.__nativeUploadResolvers) window.__nativeUploadResolvers = {};
            if (!window.__nativeUploadReqId) window.__nativeUploadReqId = 0;
            
            // Set implementation version identifier
            window.NativeUploader.__impl = IMPL_VERSION;
            console.log("[NATIVE-UPLOADER][INJECTED] installed", window.NativeUploader.__impl);
            
            // Helper function to log to Xcode console - uses console.log which Capacitor forwards to Xcode
            // These logs WILL appear in Xcode console with prefix "⚡️  [log]"
            window.__nativeLogToXcode = function(message) {
              console.log('[NATIVE-LOG] ' + message);
              // Also send to debug server
              try {
                fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:__nativeLogToXcode',message:'XCODE_LOG',data:{message:message},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A,B,C,D,E'})}).catch(()=>{});
              } catch(e) {}
            };
            
            window.NativeUploader.pickAndUploadFortunePhoto = function(options){
                // CRITICAL: Log immediately to confirm function is called and detect implementation
                var currentImpl = window.NativeUploader ? window.NativeUploader.__impl : null;
                console.log("[NATIVE-UPLOADER][INJECTED] FUNCTION CALLED - pickAndUploadFortunePhoto entry point");
                console.log("[NATIVE-UPLOADER][INJECTED] implementation version:", currentImpl || "none");
                if (typeof window.__nativeLogToXcode === 'function') {
                  window.__nativeLogToXcode('FUNCTION_CALLED pickAndUploadFortunePhoto impl=' + (currentImpl || 'none'));
                }
                console.log('[NativeUploader] Options:', JSON.stringify(options || {}).substring(0, 200));
                
                // Guard against duplicate parallel uploads
                if (!window.__nativeUploadActive) {
                  window.__nativeUploadActive = false;
                }
                if (window.__nativeUploadActive) {
                  console.log('[NATIVE-UPLOADER][INJECTED] Upload already in progress, returning busy');
                  return Promise.resolve({ error: true, stage: 'busy' });
                }
                window.__nativeUploadActive = true;
                
                // Wrap in Promise with explicit error handling to ensure errors are never swallowed
                return new Promise(async function(resolve, reject){
                  console.log('[NativeUploader] Promise created');
                  if (typeof window.__nativeLogToXcode === 'function') {
                    window.__nativeLogToXcode('PROMISE_CREATED');
                  }
                  // #region agent log
                  fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:29',message:'pickAndUploadFortunePhoto entry',data:{hasOptions:!!options},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A,B,C,D,E'})}).catch(()=>{});
                  // #endregion
                  
                  var resolved = false; // Guard to ensure resolve is called exactly once
                  var resolveOnce = function(result) {
                    if (resolved) {
                      // #region agent log
                      fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:resolveOnce',message:'RESOLVE ALREADY CALLED - preventing double resolve',data:{previousResult:result},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'C'})}).catch(()=>{});
                      // #endregion
                      return;
                    }
                    resolved = true;
                    window.__nativeUploadActive = false; // Clear busy flag on resolve
                    resolve(result);
                  };
                  
                  try {
                    var id = (++window.__nativeUploadReqId).toString();
                    window.__nativeUploadResolvers[id] = resolveOnce;
                    
                    // #region agent log
                    fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:33',message:'Request initialized',data:{requestId:id,hasCameraPlugin:typeof Capacitor !== 'undefined' && Capacitor.Plugins && Capacitor.Plugins.Camera},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A,B,C'})}).catch(()=>{});
                    // #endregion
                    
                    console.log('[NativeUploader] Starting photo picker for request:', id);
                    
                    // Use Capacitor Camera plugin
                    if (typeof Capacitor !== 'undefined' && Capacitor.Plugins && Capacitor.Plugins.Camera) {
                      try {
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:40',message:'BEFORE Camera.getPhoto call',data:{requestId:id},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A,B,D'})}).catch(()=>{});
                        // #endregion
                        
                        console.log('[NativeUploader] Opening photo picker...');
                        var cameraResult = await Capacitor.Plugins.Camera.getPhoto({
                          quality: 90,
                          allowEditing: false,
                          source: 'PHOTOS',
                          resultType: 'Uri',
                          correctOrientation: true
                        });
                        
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:48',message:'AFTER Camera.getPhoto resolved',data:{requestId:id,hasResult:cameraResult !== null && cameraResult !== undefined,isNull:cameraResult === null,isUndefined:cameraResult === undefined,hasBase64:!!(cameraResult && cameraResult.base64String),hasWebPath:!!(cameraResult && cameraResult.webPath),resultKeys:cameraResult ? Object.keys(cameraResult) : []},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A,D'})}).catch(()=>{});
                        // #endregion
                        
                        console.log('[NativeUploader] Camera result received:', cameraResult ? 'has result' : 'null');
                        
                        // ONLY cancel if cameraResult is explicitly null/undefined
                        // DO NOT cancel based on missing base64String or webPath - these may arrive later
                        if (cameraResult === null || cameraResult === undefined) {
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:53',message:'RESOLVING CANCELLED - null result',data:{requestId:id},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A'})}).catch(()=>{});
                          // #endregion
                          console.log('[NativeUploader] Photo picker cancelled (null result)');
                          resolveOnce({ cancelled: true });
                          return;
                        }
                        
                        // With resultType: 'Uri', Camera.getPhoto() returns webPath or path (URI)
                        // NEVER cancel if cameraResult exists - only cancel if null/undefined or explicit cancel error
                        var webPath = cameraResult.webPath || cameraResult.path || '';
                        
                        // Only cancel if NO valid data (neither webPath nor path)
                        if (!webPath) {
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:76',message:'RESOLVING CANCELLED - no webPath or path',data:{requestId:id,hasWebPath:!!cameraResult.webPath,hasPath:!!cameraResult.path,resultKeys:cameraResult ? Object.keys(cameraResult) : []},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'D'})}).catch(()=>{});
                          // #endregion
                          console.log('[NativeUploader] Photo picker cancelled (no webPath or path)');
                          resolveOnce({ cancelled: true });
                          return;
                        }
                        
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:82',message:'Photo data validated - proceeding with upload',data:{requestId:id,webPath:webPath.substring(0,100)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'D'})}).catch(()=>{});
                        // #endregion
                        
                        console.log('[NativeUploader] Photo selected (webPath available):', webPath.substring(0, 100));

                        // Load image from URI to get dimensions and bytes
                        var fileResp = await fetch(webPath);
                        var blob = await fileResp.blob();
                        var mimeType = blob.type || 'image/jpeg';
                        var buf = await blob.arrayBuffer();
                        var imageBytes = new Uint8Array(buf);
                        var imageBlob = new Blob([imageBytes], { type: mimeType });
                        
                        // Get dimensions from image
                        var width = cameraResult.width || 0;
                        var height = cameraResult.height || 0;
                        
                        if (!width || !height) {
                          var img = new Image();
                          img.src = webPath;
                          await new Promise(function(imgResolve, imgReject) {
                            img.onload = imgResolve;
                            img.onerror = imgReject;
                            setTimeout(imgReject, 5000);
                          });
                          width = img.width;
                          height = img.height;
                        }

                        console.log('[NativeUploader] PICKER_OK w=' + width + ' h=' + height + ' bytes=' + imageBytes.length);
                        
                        // Get Supabase URL, access token, and anon key from window
                        var supabaseUrl = 'https://pegiensgnptpdnfopnoj.supabase.co';
                        var supabaseToken = '';
                        var supabaseAnonKey = '';
                        
                        // Try to extract from window globals (web code might expose these)
                        if (typeof window !== 'undefined') {
                          // Try common patterns for Supabase client
                          if (window.__SUPABASE_URL__) supabaseUrl = window.__SUPABASE_URL__;
                          if (window.__SUPABASE_ANON_KEY__) supabaseAnonKey = window.__SUPABASE_ANON_KEY__;
                          if (window.__SUPABASE_ACCESS_TOKEN__) {
                            supabaseToken = window.__SUPABASE_ACCESS_TOKEN__;
                          } else if (window.supabase && window.supabase.supabaseUrl) {
                            supabaseUrl = window.supabase.supabaseUrl;
                          }
                          // Try to get from Supabase client session
                          if (window.supabase && window.supabase.auth) {
                            try {
                              var session = window.supabase.auth.session();
                              if (session && session.access_token) supabaseToken = session.access_token;
                              if (!supabaseAnonKey && window.supabase.supabaseKey) supabaseAnonKey = window.supabase.supabaseKey;
                            } catch(e) {
                              console.log('[NativeUploader] Could not get session:', e);
                            }
                          }
                          // Try getSession (newer API)
                          if (window.supabase && window.supabase.auth && window.supabase.auth.getSession) {
                            try {
                              var sessionResult = await window.supabase.auth.getSession();
                              if (sessionResult && sessionResult.data && sessionResult.data.session && sessionResult.data.session.access_token) {
                                supabaseToken = sessionResult.data.session.access_token;
                              }
                            } catch(e) {
                              console.log('[NativeUploader] Could not get session (new API):', e);
                            }
                          }
                        }
                        
                        // Build headers with auth for API calls
                        var headers = { 'Content-Type': 'application/json' };
                        if (supabaseToken) {
                          headers['Authorization'] = 'Bearer ' + supabaseToken;
                          console.log('[NativeUploader] Using access token: ***' + supabaseToken.substring(Math.max(0, supabaseToken.length - 4)));
                        } else {
                          console.warn('[NativeUploader] No access token available');
                        }
                        if (supabaseAnonKey) {
                          headers['apikey'] = supabaseAnonKey;
                        }
                        
                        if (!options || !options.fortuneId) {
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:179',message:'RESOLVING ERROR - missing fortuneId',data:{requestId:id},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                          // #endregion
                          console.error('[NativeUploader] Missing fortuneId in options');
                          resolveOnce({ success: false, error: 'Missing fortuneId' });
                          return;
                        }
                        var fortuneId = options.fortuneId;
                        console.log('[NativeUploader] Using Supabase URL:', supabaseUrl);
                        console.log('[NativeUploader] Step 1: Requesting upload ticket');

                        // Step 1: Issue upload ticket (POST to Supabase Edge Function)
                        console.log('[NativeUploader] About to fetch ticket from:', supabaseUrl + '/functions/v1/issue-fortune-upload-ticket');
                        console.log('[NativeUploader] Request headers:', JSON.stringify(headers).substring(0, 300));
                        console.log('[NativeUploader] Request body:', JSON.stringify({ fortune_id: fortuneId, mime: mimeType }));
                        
                        var ticketResponse = await fetch(supabaseUrl + '/functions/v1/issue-fortune-upload-ticket', {
                          method: 'POST',
                          headers: headers,
                          body: JSON.stringify({ fortune_id: fortuneId, mime: mimeType })
                        });
                        
                        console.log('[NativeUploader] Ticket response received - status:', ticketResponse.status, 'ok:', ticketResponse.ok);
                        // Log to window.console IMMEDIATELY after receiving response
                        if (typeof window !== 'undefined' && window.console) {
                          window.console.log('[NATIVE-UPLOADER] TICKET_RESPONSE_RECEIVED status=' + ticketResponse.status + ' ok=' + ticketResponse.ok);
                          window.console.error('[NATIVE-UPLOADER] TICKET_RESPONSE_RECEIVED_ERROR status=' + ticketResponse.status + ' ok=' + ticketResponse.ok);
                        }
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:212',message:'TICKET_RESPONSE_RECEIVED',data:{requestId:id,status:ticketResponse.status,ok:ticketResponse.ok},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A,B,C,D,E'})}).catch(()=>{});
                        // #endregion
                        
                        // Always read response body, even for 200 status
                        var responseText = await ticketResponse.text();
                        // CRITICAL: Log to window.console.error with a format the wrapper web can capture
                        // This will appear in Xcode console as "⚡️  [log] - [NATIVE-UPLOADER] ..."
                        if (typeof window !== 'undefined' && window.console) {
                          window.console.error('[NATIVE-UPLOADER] TICKET_TEXT_READ length=' + responseText.length);
                          window.console.error('[NATIVE-UPLOADER] TICKET_RESPONSE_TEXT_FULL: ' + responseText);
                          // Also try console.log
                          window.console.log('[NATIVE-UPLOADER] TICKET_TEXT_READ length=' + responseText.length);
                          window.console.log('[NATIVE-UPLOADER] TICKET_RESPONSE_TEXT_FULL: ' + responseText);
                        }
                        // Log to Xcode console via helper function
                        if (typeof window.__nativeLogToXcode === 'function') {
                          window.__nativeLogToXcode('TICKET_TEXT_READ length=' + responseText.length);
                          window.__nativeLogToXcode('TICKET_RESPONSE_TEXT: ' + responseText.substring(0, 500));
                          if (responseText.length > 500) {
                            window.__nativeLogToXcode('TICKET_RESPONSE_TEXT (cont): ' + responseText.substring(500));
                          }
                        }
                        console.log('[NativeUploader] 🔍🔍🔍 TICKET RESPONSE TEXT (FULL):', responseText);
                        console.log('[NativeUploader] 🔍🔍🔍 TICKET RESPONSE TEXT LENGTH:', responseText.length);
                        // Force log to console with multiple methods
                        console.error('[NativeUploader] ⚠️⚠️⚠️ CRITICAL TICKET RESPONSE:', responseText);
                        console.warn('[NativeUploader] ⚠️⚠️⚠️ CRITICAL TICKET RESPONSE:', responseText);
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:217',message:'TICKET_RESPONSE_TEXT_READ',data:{requestId:id,textLength:responseText.length,textPreview:responseText.substring(0,500),fullText:responseText},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A,B,C,D,E'})}).catch(()=>{});
                        // #endregion
                        
                        if (!ticketResponse.ok) {
                          console.error('[NativeUploader] Failed to issue upload ticket:', ticketResponse.status, responseText);
                          resolveOnce({ success: false, error: 'Failed to issue upload ticket: ' + ticketResponse.status });
                          return;
                        }
                        
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:243',message:'BEFORE ticket JSON parse',data:{requestId:id,responseOk:ticketResponse.ok,responseStatus:ticketResponse.status,responseTextLength:responseText.length},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                        // #endregion
                        
                        var ticketData = null;
                        console.log('[NativeUploader] 🔍 About to parse ticket JSON response...');
                        console.log('[NativeUploader] 🔍 Response text length:', responseText.length);
                        console.log('[NativeUploader] 🔍 Response text preview:', responseText.substring(0, 500));
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:231',message:'BEFORE_PARSE',data:{requestId:id,responseTextLength:responseText.length,responseTextPreview:responseText.substring(0,500)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                        // #endregion
                        try {
                          ticketData = JSON.parse(responseText);
                          
                          // ALWAYS log ticket keys - REQUIRED DEBUG LOG
                          var ticketKeys = Object.keys(ticketData).sort();
                          console.log('[NATIVE-UPLOADER] ticket json keys: ' + ticketKeys.join(', '));
                          if (typeof window !== 'undefined' && window.console) {
                            window.console.log('[NATIVE-UPLOADER] ticket json keys: ' + ticketKeys.join(', '));
                          }
                          
                          // Log to Xcode console via helper function - THIS WILL APPEAR IN XCODE
                          if (typeof window.__nativeLogToXcode === 'function') {
                            window.__nativeLogToXcode('TICKET_PARSED keys: ' + ticketKeys.join(', '));
                            window.__nativeLogToXcode('TICKET_PARSED hasUrl: ' + !!ticketData.url);
                            window.__nativeLogToXcode('TICKET_PARSED hasPath: ' + !!(ticketData.bucketRelativePath || ticketData.path));
                            window.__nativeLogToXcode('TICKET_PARSED url: ' + (ticketData.url || 'null'));
                            window.__nativeLogToXcode('TICKET_PARSED bucketRelativePath: ' + (ticketData.bucketRelativePath || 'null'));
                            window.__nativeLogToXcode('TICKET_PARSED path: ' + (ticketData.path || 'null'));
                            var ticketDataStr = JSON.stringify(ticketData);
                            window.__nativeLogToXcode('TICKET_PARSED FULL: ' + ticketDataStr.substring(0, 500));
                            if (ticketDataStr.length > 500) {
                              window.__nativeLogToXcode('TICKET_PARSED FULL (cont): ' + ticketDataStr.substring(500));
                            }
                          }
                          // Also log to window.console for wrapper web to see
                          if (typeof window !== 'undefined' && window.console) {
                            window.console.log('[NATIVE-UPLOADER] TICKET_PARSED keys:', Object.keys(ticketData).join(', '));
                            window.console.log('[NATIVE-UPLOADER] TICKET_PARSED hasUrl:', !!ticketData.url);
                            window.console.log('[NATIVE-UPLOADER] TICKET_PARSED hasPath:', !!(ticketData.bucketRelativePath || ticketData.path));
                          }
                          console.log('[NativeUploader] ✅ Ticket JSON parsed successfully');
                          console.log('[NativeUploader] ✅ Ticket keys:', Object.keys(ticketData).join(', '));
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:238',message:'PARSE_SUCCESS',data:{requestId:id,ticketKeys:Object.keys(ticketData),hasUrl:!!ticketData.url,hasPath:!!(ticketData.bucketRelativePath || ticketData.path),url:ticketData.url,bucketRelativePath:ticketData.bucketRelativePath,path:ticketData.path,ticketDataFull:JSON.stringify(ticketData)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A,B,C,D,E'})}).catch(()=>{});
                          // #endregion
                        } catch (parseError) {
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:241',message:'RESOLVING ERROR - ticket JSON parse failed',data:{requestId:id,error:parseError.message || String(parseError),responseText:responseText.substring(0,500)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                          // #endregion
                          console.error('[NativeUploader] ❌ ERROR: Failed to parse ticket response as JSON:', parseError);
                          console.error('[NativeUploader] ❌ ERROR: Parse error message:', parseError.message);
                          console.error('[NativeUploader] ❌ ERROR: Parse error stack:', parseError.stack);
                          console.error('[NativeUploader] ❌ ERROR: Raw response text:', responseText);
                          resolveOnce({ success: false, error: 'Failed to parse ticket response: ' + (parseError.message || 'Invalid JSON'), stage: 'ticket' });
                          return;
                        }
                        
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:247',message:'AFTER ticket JSON parse',data:{requestId:id,hasTicketData:!!ticketData,hasUrl:!!(ticketData && ticketData.url),hasPath:!!(ticketData && (ticketData.bucketRelativePath || ticketData.path)),ticketKeys:ticketData ? Object.keys(ticketData) : []},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                        // #endregion
                        
                        // Log ALL keys in ticketData
                        console.error('[NativeUploader] ⚠️ CRITICAL: Ticket data ALL keys:', ticketData ? Object.keys(ticketData).join(', ') : 'null');
                        console.error('[NativeUploader] ⚠️ CRITICAL: Ticket data FULL JSON:', JSON.stringify(ticketData));
                        console.log('[NativeUploader] 🔍 DEBUG: Ticket parsed, starting field extraction...');
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:254',message:'TICKET_PARSED - starting extraction',data:{requestId:id,ticketKeys:ticketData ? Object.keys(ticketData) : [],ticketDataPreview:JSON.stringify(ticketData).substring(0,300)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                        // #endregion
                        
                        // Extract ticket fields with variant support - resilient to backend field name changes
                        var uploadUrl = ticketData.url || ticketData.uploadUrl || ticketData.upload_url || ticketData.signedUrl || ticketData.signed_url || null;
                        var bucketRelativePath = ticketData.bucketRelativePath || ticketData.path || ticketData.filePath || ticketData.dbPath || ticketData.db_path || '';
                        var requiredHeaders = ticketData.requiredHeaders || ticketData.headers || {};
                        var bucket = ticketData.bucket || ticketData.bucket_name || 'photos';
                        var formFieldName = ticketData.formFieldName || 'file';
                        var uploadMethod = ticketData.uploadMethod || 'POST_MULTIPART';
                        
                        // Ensure values are strings (handle type coercion)
                        if (uploadUrl && typeof uploadUrl !== 'string') {
                          uploadUrl = String(uploadUrl).trim();
                        }
                        if (bucketRelativePath && typeof bucketRelativePath !== 'string') {
                          bucketRelativePath = String(bucketRelativePath).trim();
                        }
                        if (bucket && typeof bucket !== 'string') {
                          bucket = String(bucket).trim();
                        }
                        if (formFieldName && typeof formFieldName !== 'string') {
                          formFieldName = String(formFieldName).trim();
                        }
                        if (uploadMethod && typeof uploadMethod !== 'string') {
                          uploadMethod = String(uploadMethod).trim();
                        }
                        
                        // Ensure requiredHeaders is an object
                        if (!requiredHeaders || typeof requiredHeaders !== 'object' || Array.isArray(requiredHeaders)) {
                          requiredHeaders = {};
                        }
                        
                        // ALWAYS log parsed ticket values - REQUIRED DEBUG LOG
                        var urlPreview = uploadUrl ? (uploadUrl.length > 80 ? uploadUrl.substring(0, 80) + '...' : uploadUrl) : 'null';
                        console.log('[NATIVE-UPLOADER] parsed ticket: url=' + urlPreview + ', path=' + (bucketRelativePath || 'null') + ', method=' + (uploadMethod || 'null') + ', field=' + formFieldName);
                        console.log('[NATIVE-UPLOADER] ticket uploadMethod from edge function: ' + (ticketData.uploadMethod || 'NOT_PROVIDED'));
                        if (typeof window !== 'undefined' && window.console) {
                          window.console.log('[NATIVE-UPLOADER] parsed ticket: url=' + urlPreview + ', path=' + (bucketRelativePath || 'null') + ', method=' + (uploadMethod || 'null') + ', field=' + formFieldName);
                          window.console.log('[NATIVE-UPLOADER] ticket uploadMethod from edge function: ' + (ticketData.uploadMethod || 'NOT_PROVIDED'));
                        }
                        
                        // Log extracted values BEFORE parsing headers (detailed logs)
                        console.error('[NativeUploader] ⚠️ CRITICAL: Extracted values BEFORE header parsing:');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - bucket:', bucket, '(raw:', ticketData.bucket, ')');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - url:', uploadUrl ? (uploadUrl.length > 100 ? uploadUrl.substring(0, 100) + '...' : uploadUrl) : 'MISSING', '(raw:', ticketData.url, ')');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - path:', bucketRelativePath, '(raw bucketRelativePath:', ticketData.bucketRelativePath, ', raw path:', ticketData.path, ')');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - formFieldName:', formFieldName, '(raw:', ticketData.formFieldName, ')');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - uploadMethod:', uploadMethod, '(raw:', ticketData.uploadMethod, ')');
                        
                        // Handle headers: new format has "requiredHeaders", legacy has "headers"
                        // Make headers parsing robust: accept [String: Any] and stringify values into [String: String]
                        // NEVER fail on headers parsing - always produce a valid [String: String] object
                        var rawHeaders = null;
                        try {
                          rawHeaders = ticketData.requiredHeaders || ticketData.headers || null;
                        } catch (e) {
                          console.warn('[NativeUploader] Warning: Could not read headers from ticket, using empty object');
                          rawHeaders = null;
                        }
                        
                        console.error('[NativeUploader] ⚠️ CRITICAL: Raw headers type:', typeof rawHeaders);
                        console.error('[NativeUploader] ⚠️ CRITICAL: Raw headers is array?', Array.isArray(rawHeaders));
                        console.error('[NativeUploader] ⚠️ CRITICAL: Raw headers (before conversion):', rawHeaders ? JSON.stringify(rawHeaders) : 'null/undefined');
                        
                        // CRITICAL: Headers parsing MUST NEVER fail - always produce valid [String: String]
                        // Accept [String: Any] and convert ALL values to strings
                        var requiredHeaders = {};
                        
                        // Wrap entire headers parsing in try-catch to ensure it NEVER throws
                        try {
                          if (rawHeaders !== null && rawHeaders !== undefined) {
                            // Handle array case - log but don't fail
                            if (Array.isArray(rawHeaders)) {
                              console.warn('[NativeUploader] Warning: Headers is an array (expected object), converting to empty object');
                              rawHeaders = null; // Will use empty object below
                            } else if (typeof rawHeaders === 'object') {
                              // Valid object - iterate over all properties
                              var keysProcessed = 0;
                              var keysSkipped = 0;
                              
                              for (var key in rawHeaders) {
                                try {
                                  // Additional safety check for hasOwnProperty
                                  if (Object.prototype.hasOwnProperty.call(rawHeaders, key)) {
                                    try {
                                      var value = rawHeaders[key];
                                      var originalType = typeof value;
                                      
                                      // Convert any value type to string - NEVER fail here
                                      if (value === null || value === undefined) {
                                        requiredHeaders[key] = '';
                                        keysProcessed++;
                                      } else if (typeof value === 'string') {
                                        requiredHeaders[key] = value;
                                        keysProcessed++;
                                      } else if (typeof value === 'boolean') {
                                        // Special handling for booleans - Supabase may return these
                                        requiredHeaders[key] = String(value); // "true" or "false"
                                        console.log('[NativeUploader] Converted boolean header "' + key + '" from ' + value + ' to "' + String(value) + '"');
                                        keysProcessed++;
                                      } else if (typeof value === 'number') {
                                        requiredHeaders[key] = String(value);
                                        keysProcessed++;
                                      } else if (typeof value === 'object') {
                                        // For objects (including arrays), stringify them
                                        try {
                                          requiredHeaders[key] = JSON.stringify(value);
                                          keysProcessed++;
                                        } catch (stringifyError) {
                                          // If stringify fails, use fallback
                                          requiredHeaders[key] = '[object]';
                                          keysProcessed++;
                                          console.warn('[NativeUploader] Warning: Could not stringify header value for key "' + key + '", using "[object]"');
                                        }
                                      } else {
                                        // Fallback: convert anything else to string
                                        try {
                                          requiredHeaders[key] = String(value);
                                          keysProcessed++;
                                        } catch (stringError) {
                                          keysSkipped++;
                                          console.warn('[NativeUploader] Warning: Could not convert header value for key "' + key + '" (type: ' + originalType + '), skipping');
                                        }
                                      }
                                    } catch (headerValueError) {
                                      // If we can't convert a header value, skip it but log warning
                                      keysSkipped++;
                                      console.warn('[NativeUploader] Warning: Could not convert header value for key "' + key + '", skipping:', headerValueError);
                                    }
                                  }
                                } catch (keyError) {
                                  keysSkipped++;
                                  console.warn('[NativeUploader] Warning: Error processing header key, skipping:', keyError);
                                }
                              }
                              
                              console.log('[NativeUploader] Headers conversion: processed ' + keysProcessed + ', skipped ' + keysSkipped);
                            } else {
                              // Not an object or array - log warning but don't fail
                              console.warn('[NativeUploader] Warning: Headers is not an object or array, type: ' + (typeof rawHeaders) + ', using empty object');
                            }
                          }
                          // If rawHeaders is null/undefined, requiredHeaders remains empty {} (valid)
                          
                        } catch (headerParseError) {
                          // If header parsing fails completely, use empty object but log error
                          // This should NEVER happen, but if it does, we continue with empty headers
                          console.error('[NativeUploader] ❌ CRITICAL ERROR parsing headers (non-fatal, using empty object):', headerParseError);
                          console.error('[NativeUploader] ❌ Header parse error message:', headerParseError.message);
                          console.error('[NativeUploader] ❌ Header parse error stack:', headerParseError.stack);
                          requiredHeaders = {}; // Always ensure we have a valid object
                        }
                        
                        // Ensure requiredHeaders is always a valid object (defensive check)
                        if (!requiredHeaders || typeof requiredHeaders !== 'object' || Array.isArray(requiredHeaders)) {
                          console.warn('[NativeUploader] Warning: requiredHeaders invalid type, resetting to empty object');
                          requiredHeaders = {};
                        }
                        
                        console.error('[NativeUploader] ⚠️ CRITICAL: Converted headers (after stringify):', JSON.stringify(requiredHeaders));
                        console.error('[NativeUploader] ⚠️ CRITICAL: Headers conversion successful - count:', Object.keys(requiredHeaders).length);
                        console.error('[NativeUploader] ⚠️ CRITICAL: Headers is valid object?', typeof requiredHeaders === 'object' && !Array.isArray(requiredHeaders));
                        
                        // fortuneId is provided by the caller (options.fortuneId)
                        var fortuneIdFromTicket = ticketData.fortuneId || ticketData.fortune_id;
                        if (fortuneIdFromTicket && fortuneIdFromTicket !== fortuneId) {
                          console.log('[NativeUploader] Ticket fortuneId differs from options, using options.fortuneId');
                        }
                        
                        // Log extracted values AFTER parsing headers
                        console.error('[NativeUploader] ⚠️ CRITICAL: Final extracted values:');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - bucket:', bucket);
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - url:', uploadUrl ? 'present (length: ' + uploadUrl.length + ')' : 'MISSING');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - path (bucketRelativePath):', bucketRelativePath ? 'present (' + bucketRelativePath + ')' : 'MISSING');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - formFieldName:', formFieldName);
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - headers count:', Object.keys(requiredHeaders).length);
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - headers keys:', Object.keys(requiredHeaders).join(', '));
                        if (Object.keys(requiredHeaders).length > 0) {
                          for (var hKey in requiredHeaders) {
                            if (requiredHeaders.hasOwnProperty(hKey)) {
                              console.error('[NativeUploader] ⚠️ CRITICAL:   - header[' + hKey + ']:', requiredHeaders[hKey]);
                            }
                          }
                        }
                        
                        // Validate required fields - only fail if TRULY missing
                        // uploadUrl is REQUIRED (cannot proceed without it)
                        // bucketRelativePath is REQUIRED (cannot proceed without it)
                        // Headers are OPTIONAL - never fail validation due to headers
                        console.error('[NativeUploader] ⚠️ CRITICAL: Starting validation of required fields...');
                        console.error('[NativeUploader] ⚠️ CRITICAL: uploadUrl value:', uploadUrl);
                        console.error('[NativeUploader] ⚠️ CRITICAL: uploadUrl type:', typeof uploadUrl);
                        console.error('[NativeUploader] ⚠️ CRITICAL: bucketRelativePath value:', bucketRelativePath);
                        console.error('[NativeUploader] ⚠️ CRITICAL: bucketRelativePath type:', typeof bucketRelativePath);
                        
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:461',message:'VALIDATION_START',data:{requestId:id,hasUploadUrl:!!uploadUrl,uploadUrlType:typeof uploadUrl,uploadUrlValue:uploadUrl ? String(uploadUrl).substring(0,100) : 'null',hasBucketRelativePath:!!bucketRelativePath,bucketRelativePathType:typeof bucketRelativePath,bucketRelativePathValue:bucketRelativePath || 'null'},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                        // #endregion
                        
                        var validationErrors = [];
                        
                        // Check uploadUrl - must be a non-empty string
                        var urlIsValid = false;
                        if (uploadUrl && typeof uploadUrl === 'string') {
                          var trimmedUrl = uploadUrl.trim();
                          if (trimmedUrl.length > 0) {
                            urlIsValid = true;
                          }
                        }
                        console.error('[NativeUploader] ⚠️ CRITICAL: urlIsValid:', urlIsValid);
                        if (!urlIsValid) {
                          validationErrors.push('url is missing, empty, or invalid type (got: ' + (typeof uploadUrl) + ')');
                        }
                        
                        // Check bucketRelativePath - must be a non-empty string
                        var pathIsValid = false;
                        if (bucketRelativePath && typeof bucketRelativePath === 'string') {
                          var trimmedPath = bucketRelativePath.trim();
                          if (trimmedPath.length > 0) {
                            pathIsValid = true;
                          }
                        }
                        console.error('[NativeUploader] ⚠️ CRITICAL: pathIsValid:', pathIsValid);
                        if (!pathIsValid) {
                          validationErrors.push('path (bucketRelativePath) is missing, empty, or invalid type (got: ' + (typeof bucketRelativePath) + ')');
                        }
                        
                        console.error('[NativeUploader] ⚠️ CRITICAL: validationErrors.length:', validationErrors.length);
                        console.error('[NativeUploader] ⚠️ CRITICAL: validationErrors:', validationErrors);
                        
                        // Log to Xcode console via helper function - THIS WILL APPEAR IN XCODE
                        if (typeof window.__nativeLogToXcode === 'function') {
                          window.__nativeLogToXcode('VALIDATION_CHECK uploadUrl=' + (uploadUrl || 'null') + ' bucketRelativePath=' + (bucketRelativePath || 'null'));
                          window.__nativeLogToXcode('VALIDATION_CHECK validationErrors.length=' + validationErrors.length);
                          window.__nativeLogToXcode('VALIDATION_CHECK validationErrors=' + JSON.stringify(validationErrors));
                        }
                        // Also log to window.console for wrapper web to see
                        if (typeof window !== 'undefined' && window.console) {
                          window.console.log('[NATIVE-UPLOADER] VALIDATION_CHECK uploadUrl=' + (uploadUrl || 'null') + ' bucketRelativePath=' + (bucketRelativePath || 'null'));
                          window.console.log('[NATIVE-UPLOADER] VALIDATION_CHECK validationErrors.length=' + validationErrors.length);
                        }
                        
                        // Only fail if BOTH required fields are missing - never fail due to headers
                        if (validationErrors.length > 0) {
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:492',message:'RESOLVING ERROR - missing required fields in ticket',data:{requestId:id,validationErrors:validationErrors,hasUploadUrl:!!uploadUrl,hasBucketRelativePath:!!bucketRelativePath,uploadUrlType:typeof uploadUrl,pathType:typeof bucketRelativePath,uploadUrl:uploadUrl || 'empty',bucketRelativePath:bucketRelativePath || 'empty',ticketKeys:ticketData ? Object.keys(ticketData) : [],ticketDataString:JSON.stringify(ticketData).substring(0,500)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                          // #endregion
                          console.error('[NativeUploader] ❌ ERROR: Invalid ticket response - required fields missing');
                          console.error('[NativeUploader] ❌ ERROR: Validation errors:', validationErrors);
                          console.error('[NativeUploader] ❌ ERROR: uploadUrl:', uploadUrl ? ('present (' + typeof uploadUrl + '): "' + uploadUrl + '"') : 'MISSING');
                          console.error('[NativeUploader] ❌ ERROR: bucketRelativePath:', bucketRelativePath ? ('present (' + typeof bucketRelativePath + '): "' + bucketRelativePath + '"') : 'MISSING');
                          console.error('[NativeUploader] ❌ ERROR: Full ticketData:', JSON.stringify(ticketData));
                          console.error('[NativeUploader] ❌ ERROR: This error will cause flow to cancel at stage "ticket"');
                          // Log to window for wrapper web to see
                          if (typeof window !== 'undefined' && window.console) {
                            window.console.error('[NATIVE-UPLOADER] VALIDATION FAILED:', {
                              validationErrors: validationErrors,
                              uploadUrl: uploadUrl,
                              bucketRelativePath: bucketRelativePath,
                              ticketData: ticketData
                            });
                          }
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:535',message:'RESOLVING ERROR - validation failed',data:{requestId:id,validationErrors:validationErrors,uploadUrl:uploadUrl || 'null',bucketRelativePath:bucketRelativePath || 'null',ticketData:JSON.stringify(ticketData)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                          // #endregion
                          resolveOnce({ 
                            error: true, 
                            cancelled: false, 
                            stage: 'ticket', 
                            message: 'Invalid upload ticket response: ' + validationErrors.join(', '),
                            details: { presentKeys: Object.keys(ticketData) }
                          });
                          return;
                        }
                        
                        // If we reach here, required fields are valid - headers parsing cannot cause failure
                        console.error('[NativeUploader] ✅ VALIDATION PASSED - Required fields present, headers parsing succeeded (even if empty)');
                        
                        // Headers are optional - if missing, use default
                        if (!requiredHeaders || Object.keys(requiredHeaders).length === 0) {
                          console.warn('[NativeUploader] No headers/requiredHeaders in ticket, using default x-upsert:true');
                          requiredHeaders = { 'x-upsert': 'true' };
                        }
                        
                        console.log('TICKET_OK bucketRelativePath=' + bucketRelativePath);
                        
                        // Step 2: Upload to Supabase signed upload URL
                        // Check uploadMethod from ticket: 'PUT' uses raw bytes, 'POST_MULTIPART' uses FormData (legacy)
                        
                        // Helper function to detect MIME type from bytes
                        function getMimeTypeFromBytes(bytes) {
                          if (bytes.length < 4) return 'image/jpeg';
                          var byte0 = bytes[0];
                          var byte1 = bytes[1];
                          var byte2 = bytes[2];
                          var byte3 = bytes[3];
                          
                          // JPEG: FF D8 FF
                          if (byte0 === 0xFF && byte1 === 0xD8 && byte2 === 0xFF) {
                            return 'image/jpeg';
                          }
                          // PNG: 89 50 4E 47
                          if (byte0 === 0x89 && byte1 === 0x50 && byte2 === 0x4E && byte3 === 0x47) {
                            return 'image/png';
                          }
                          // WebP: RIFF (52 49 46 46)
                          if (byte0 === 0x52 && byte1 === 0x49 && byte2 === 0x46 && byte3 === 0x46) {
                            return 'image/webp';
                          }
                          return 'image/jpeg'; // fallback
                        }
                        
                        // Detect MIME type from image bytes
                        var detectedMimeType = getMimeTypeFromBytes(imageBytes);
                        
                        // Step 2: Upload to Supabase signed upload URL
                        // Check uploadMethod from ticket - use PUT for signed URLs with token (new method)
                        // or POST multipart for legacy endpoints
                        
                        var uploadResponse;
                        var uploadHeaders = {};
                        
                        if (uploadMethod === 'PUT') {
                          // NEW: Use PUT with raw bytes (required for createSignedUploadUrl with token)
                          // Content-Type must be the actual MIME type, not multipart
                          uploadHeaders['Content-Type'] = detectedMimeType;  // image/jpeg, image/png, etc.
                          
                          // Add any required headers from ticket (except Content-Type which we set above)
                          if (requiredHeaders && typeof requiredHeaders === 'object') {
                            for (var key in requiredHeaders) {
                              if (Object.prototype.hasOwnProperty.call(requiredHeaders, key)) {
                                if (key.toLowerCase() !== 'content-type') {
                                  uploadHeaders[key] = requiredHeaders[key];
                                }
                              }
                            }
                          }
                          
                          console.log('[NativeUploader] UPLOAD_START method=PUT path=' + bucketRelativePath + ' mime=' + detectedMimeType + ' bytes=' + imageBytes.length);
                          uploadResponse = await fetch(uploadUrl, {
                            method: 'PUT',
                            headers: uploadHeaders,
                            body: imageBytes  // Raw Uint8Array, NOT FormData
                          });
                        } else {
                          // LEGACY: Use POST with multipart/form-data (for backwards compatibility)
                          var formData = new FormData();
                          formData.append(formFieldName, imageBlob, 'photo.jpg');
                          
                          if (requiredHeaders && typeof requiredHeaders === 'object') {
                            for (var key in requiredHeaders) {
                              if (Object.prototype.hasOwnProperty.call(requiredHeaders, key)) {
                                uploadHeaders[key] = requiredHeaders[key];
                              }
                            }
                          }
                          if (!uploadHeaders['x-upsert']) {
                            uploadHeaders['x-upsert'] = 'true';
                          }
                          
                          console.log('[NativeUploader] UPLOAD_START method=POST path=' + bucketRelativePath + ' field=' + formFieldName);
                          uploadResponse = await fetch(uploadUrl, {
                            method: 'POST',
                            headers: uploadHeaders,
                            body: formData
                          });
                        }

                        var uploadStatus = uploadResponse.status;
                        var uploadResponseText = '';
                        try {
                          uploadResponseText = await uploadResponse.text();
                        } catch (e) {
                          uploadResponseText = 'Could not read response';
                        }

                        var uploadBodyPreview = uploadResponseText || '';
                        if (uploadBodyPreview.length > 300) {
                          uploadBodyPreview = uploadBodyPreview.substring(0, 300);
                        }

                        var actualMethod = normalizedUploadMethod === 'PUT' ? 'PUT' : 'POST';
                        
                        if (uploadStatus === 200 || uploadStatus === 201 || uploadStatus === 204) {
                          console.log('[NATIVE-UPLOADER] upload success');
                          console.log('UPLOAD_OK status=' + uploadStatus + ' method=' + actualMethod + ' body=' + uploadBodyPreview);
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:557',message:'UPLOAD_OK - proceeding to verify',data:{requestId:id,status:uploadStatus,method:actualMethod,bodyPreview:uploadBodyPreview.substring(0,100)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A'})}).catch(()=>{});
                          // #endregion
                        } else {
                          console.error('[NATIVE-UPLOADER] upload failed: ' + uploadBodyPreview);
                          console.error('UPLOAD_FAIL status=' + uploadStatus + ' method=' + actualMethod + ' body=' + uploadBodyPreview);
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:560',message:'UPLOAD_FAIL - returning error',data:{requestId:id,status:uploadStatus,method:actualMethod,bodyPreview:uploadBodyPreview.substring(0,100)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A'})}).catch(()=>{});
                          // #endregion
                          resolveOnce({ success: false, error: 'Failed to upload image: ' + uploadStatus, stage: 'upload' });
                          return;
                        }

                        // Step 2.5: Verify upload by checking if object exists in Storage using HTTP LIST API
                        console.log('[NativeUploader] Verifying upload in storage...');
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:566',message:'VERIFY_START',data:{requestId:id,bucket:bucket,path:bucketRelativePath},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B'})}).catch(()=>{});
                        // #endregion
                        try {
                          var lastSlash = bucketRelativePath.lastIndexOf('/');
                          var folder = lastSlash >= 0 ? bucketRelativePath.substring(0, lastSlash) : '';
                          var filename = lastSlash >= 0 ? bucketRelativePath.substring(lastSlash + 1) : bucketRelativePath;
                          
                          var folderPath = folder ? folder : '';
                          var listUrl = supabaseUrl + '/storage/v1/object/list/' + bucket + '/' + folderPath + '?search=' + encodeURIComponent(filename);
                          
                          var listHeaders = {};
                          if (supabaseToken) {
                            listHeaders['Authorization'] = 'Bearer ' + supabaseToken;
                          }
                          if (supabaseAnonKey) {
                            listHeaders['apikey'] = supabaseAnonKey;
                          }
                          
                          var listResponse = await fetch(listUrl, {
                            method: 'GET',
                            headers: listHeaders
                          });
                          
                          var listStatus = listResponse.status;
                          var listData = null;
                          if (listStatus === 200) {
                            try {
                              listData = await listResponse.json();
                            } catch (e) {
                              listData = [];
                            }
                          } else {
                            var listErrorText = await listResponse.text();
                            console.error('[NativeUploader] VERIFY_FAIL list error status=' + listStatus + ' body=' + (listErrorText.substring(0, 300)));
                            resolveOnce({ success: false, error: 'Upload verification failed: ' + listStatus, stage: 'verify' });
                            return;
                          }

                          var matches = (listData && Array.isArray(listData)) ? listData.length : 0;
                          console.log('VERIFY_OK matches=' + matches);
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:603',message:'VERIFY_OK - proceeding to finalize',data:{requestId:id,matches:matches},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B'})}).catch(()=>{});
                          // #endregion

                          if (matches === 0) {
                            console.error('VERIFY_FAIL matches=0');
                            // #region agent log
                            fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:607',message:'VERIFY_FAIL matches=0 - returning error',data:{requestId:id,matches:matches},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B'})}).catch(()=>{});
                            // #endregion
                            resolveOnce({ success: false, error: 'Upload verification failed: file not found in storage', stage: 'verify' });
                            return;
                          }
                        } catch (verifyError) {
                          console.error('[NativeUploader] Verification error:', verifyError);
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:612',message:'VERIFY_FAIL exception - returning error',data:{requestId:id,error:verifyError.message || String(verifyError)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B'})}).catch(()=>{});
                          // #endregion
                          resolveOnce({ success: false, error: 'Upload verification failed: ' + (verifyError.message || 'Unknown error'), stage: 'verify' });
                          return;
                        }
                        
                        // Step 3: Finalize (POST to Supabase Edge Function) with retry logic
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:617',message:'FINALIZE_PREPARE - building payload',data:{requestId:id,fortuneId:fortuneId,bucket:bucket,path:bucketRelativePath,hasToken:!!supabaseToken,hasAnonKey:!!supabaseAnonKey},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'C'})}).catch(()=>{});
                        // #endregion
                        // Backend expects: fortune_id, bucket, path (bucket-relative, NO "photos/" prefix)
                        var finalizePayload = {
                          fortune_id: fortuneId,
                          bucket: bucket,
                          path: bucketRelativePath, // bucket-relative: userId/file.jpg (NO "photos/" prefix)
                          mime: mimeType,
                          width: width || null,
                          height: height || null,
                          size_bytes: (imageBytes && imageBytes.length) ? imageBytes.length : null
                        };
                        
                        // Retry logic for finalize - maximum 3 attempts
                        var maxFinalizeRetries = 3;
                        var finalizeData = null;
                        var finalizeSuccess = false;
                        
                        for (var retryAttempt = 0; retryAttempt < maxFinalizeRetries; retryAttempt++) {
                          try {
                            console.log('[NativeUploader] FINALIZE_START attempt=' + (retryAttempt + 1) + '/' + maxFinalizeRetries + ' path=' + bucketRelativePath);
                            // #region agent log
                            fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:634',message:'FINALIZE_START attempt',data:{requestId:id,attempt:retryAttempt+1,maxRetries:maxFinalizeRetries,url:supabaseUrl + '/functions/v1/finalize-fortune-photo',hasToken:!!supabaseToken,hasAnonKey:!!supabaseAnonKey},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'C'})}).catch(()=>{});
                            // #endregion
                            
                            var finalizeHeaders = { 'Content-Type': 'application/json' };
                            if (supabaseToken) {
                              finalizeHeaders['Authorization'] = 'Bearer ' + supabaseToken;
                            }
                            if (supabaseAnonKey) {
                              finalizeHeaders['apikey'] = supabaseAnonKey;
                            }
                            
                            // #region agent log
                            fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:646',message:'FINALIZE_FETCH - calling endpoint',data:{requestId:id,url:supabaseUrl + '/functions/v1/finalize-fortune-photo',payload:JSON.stringify(finalizePayload).substring(0,200)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'C'})}).catch(()=>{});
                            // #endregion
                            
                            var finalizeResponse = await fetch(supabaseUrl + '/functions/v1/finalize-fortune-photo', {
                              method: 'POST',
                              headers: finalizeHeaders,
                              body: JSON.stringify(finalizePayload)
                            });
                            
                            var finalizeStatus = finalizeResponse.status;
                            var finalizeResponseText = '';
                            try {
                              finalizeResponseText = await finalizeResponse.text();
                            } catch (e) {
                              finalizeResponseText = 'Could not read response';
                            }
                            var finalizeResponsePreview = finalizeResponseText.length > 300 ? finalizeResponseText.substring(0, 300) : finalizeResponseText;
                            
                            // Accept 200 or 201 as success
                            if (finalizeStatus === 200 || finalizeStatus === 201) {
                              try {
                                finalizeData = JSON.parse(finalizeResponseText);
                              } catch (e) {
                                finalizeData = {};
                              }
                              var signedUrl = finalizeData.signedUrl || '';
                              console.log('FINALIZE_OK status=' + finalizeStatus + ' signedUrl=' + (signedUrl.length > 80 ? signedUrl.substring(0, 80) + '...' : signedUrl) + ' body=' + finalizeResponsePreview);
                              // #region agent log
                              fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:662',message:'FINALIZE_OK - success',data:{requestId:id,status:finalizeStatus,hasSignedUrl:!!signedUrl},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'C'})}).catch(()=>{});
                              // #endregion
                              finalizeSuccess = true;
                              break; // Success, exit retry loop
                            } else {
                              console.error('FINALIZE_FAIL status=' + finalizeStatus + ' body=' + finalizeResponsePreview);
                              // #region agent log
                              fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:673',message:'FINALIZE_FAIL status',data:{requestId:id,status:finalizeStatus,bodyPreview:finalizeResponsePreview.substring(0,100),isLastAttempt:retryAttempt === maxFinalizeRetries - 1},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'C'})}).catch(()=>{});
                              // #endregion
                              
                              // If this is the last attempt, return error
                              if (retryAttempt === maxFinalizeRetries - 1) {
                                resolveOnce({ success: false, error: 'Failed to finalize photo after ' + maxFinalizeRetries + ' attempts: ' + finalizeStatus, stage: 'finalize' });
                                return;
                              }
                              
                              // Wait before retry (exponential backoff: 1s, 2s)
                              var waitTime = 1000 * (retryAttempt + 1);
                              console.log('[NativeUploader] Retrying finalize in ' + waitTime + 'ms (left=' + (maxFinalizeRetries - retryAttempt - 1) + ')');
                              await new Promise(function(resolve) { setTimeout(resolve, waitTime); });
                            }
                          } catch (finalizeError) {
                            console.error('[NativeUploader] FINALIZE_FAIL error (attempt ' + (retryAttempt + 1) + '):', finalizeError.message || finalizeError);
                            
                            // If this is the last attempt, return error
                            if (retryAttempt === maxFinalizeRetries - 1) {
                              resolveOnce({ success: false, error: 'Failed to finalize photo after ' + maxFinalizeRetries + ' attempts: ' + (finalizeError.message || 'Unknown error'), stage: 'finalize' });
                              return;
                            }
                            
                            // Wait before retry
                            var waitTime = 1000 * (retryAttempt + 1);
                            console.log('[NativeUploader] Retrying finalize in ' + waitTime + 'ms (left=' + (maxFinalizeRetries - retryAttempt - 1) + ')');
                            await new Promise(function(resolve) { setTimeout(resolve, waitTime); });
                          }
                        }
                        
                        if (!finalizeSuccess) {
                          resolveOnce({ success: false, error: 'Failed to finalize photo after ' + maxFinalizeRetries + ' attempts', stage: 'finalize' });
                          return;
                        }
                        
                        console.log('[NativeUploader] Upload completed successfully for request:', id);
                        
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:400',message:'RESOLVING SUCCESS',data:{requestId:id,hasSignedUrl:!!finalizeData.signedUrl},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'C'})}).catch(()=>{});
                        // #endregion
                        
                        // Return success - extract signedUrl and replaced from finalize response
                        var signedUrl = finalizeData.signedUrl || '';
                        var replaced = finalizeData.replaced || false;
                        resolveOnce({
                          success: true,
                          signedUrl: signedUrl,
                          replaced: replaced,
                          path: bucketRelativePath, // bucket-relative: userId/file.jpg
                          width: width,
                          height: height,
                          size_bytes: imageBytes.length
                        });
                        
                      } catch (cameraError) {
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:414',message:'Camera.getPhoto error caught',data:{requestId:id,errorType:typeof cameraError,errorMessage:cameraError.message || String(cameraError) || 'no message',hasMessage:!!cameraError.message,errorString:String(cameraError)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B'})}).catch(()=>{});
                        // #endregion
                        
                        console.error('[NativeUploader] Camera error:', cameraError);
                        // ONLY cancel if error message explicitly contains "cancel"
                        // DO NOT cancel for other errors (treat as failures, not cancellations)
                        var errorMsg = cameraError.message || String(cameraError) || '';
                        var lowerErrorMsg = errorMsg.toLowerCase();
                        var containsCancel = lowerErrorMsg.includes('cancel') || lowerErrorMsg.includes('cancelled');
                        
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:424',message:'Error analysis',data:{requestId:id,containsCancel:containsCancel,errorMsg:errorMsg.substring(0,200)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B'})}).catch(()=>{});
                        // #endregion
                        
                        if (containsCancel) {
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:428',message:'RESOLVING CANCELLED - explicit cancel in error',data:{requestId:id},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B'})}).catch(()=>{});
                          // #endregion
                          console.log('[NativeUploader] Photo picker cancelled (explicit cancel in error)');
                          resolveOnce({ cancelled: true });
                        } else {
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:432',message:'RESOLVING ERROR - not cancellation',data:{requestId:id},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B'})}).catch(()=>{});
                          // #endregion
                          resolveOnce({ success: false, error: errorMsg || 'Camera error' });
                        }
                      }
                    } else {
                      // #region agent log
                      fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:436',message:'RESOLVING ERROR - Camera plugin not available',data:{requestId:id},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'A'})}).catch(()=>{});
                      // #endregion
                      console.error('[NativeUploader] Capacitor Camera plugin not available');
                      resolveOnce({ success: false, error: 'Camera plugin not available' });
                    }
                  } catch (e) {
                    window.__nativeUploadActive = false; // Clear busy flag on error
                    // #region agent log
                    fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:442',message:'Outer catch - general error',data:{requestId:id,errorType:typeof e,errorMessage:e.message || String(e) || 'no message',hasMessage:!!e.message,errorString:String(e)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B,E'})}).catch(()=>{});
                    // #endregion
                    
                    // Ensure errors are never swallowed - log to Xcode with stage
                    var errorStage = 'unknown';
                    var errorMessage = e.message || String(e) || 'Unknown error';
                    console.error('[NATIVE-UPLOADER][INJECTED] ERROR caught (stage=' + errorStage + '):', errorMessage);
                    if (typeof window.__nativeLogToXcode === 'function') {
                      window.__nativeLogToXcode('ERROR stage=' + errorStage + ' message=' + errorMessage.substring(0, 200));
                    }
                    console.error('[NativeUploader] Error:', e);
                    // Do NOT treat general errors as cancellation
                    // Only cancel if explicitly requested or null result
                    var errorMsg = e.message || String(e) || '';
                    var lowerErrorMsg = errorMsg.toLowerCase();
                    var containsCancel = lowerErrorMsg.includes('cancel') || lowerErrorMsg.includes('cancelled');
                    
                    // #region agent log
                    fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:451',message:'Outer error analysis',data:{requestId:id,containsCancel:containsCancel,errorMsg:errorMsg.substring(0,200)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B,E'})}).catch(()=>{});
                    // #endregion
                    
                    if (containsCancel) {
                      // #region agent log
                      fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:455',message:'RESOLVING CANCELLED - explicit cancel in outer error',data:{requestId:id},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B,E'})}).catch(()=>{});
                      // #endregion
                      resolveOnce({ cancelled: true });
                    } else {
                      // #region agent log
                      fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:459',message:'RESOLVING ERROR - not cancellation (outer)',data:{requestId:id},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B,E'})}).catch(()=>{});
                      // #endregion
                      resolveOnce({ success: false, error: errorMsg || 'Unknown error' });
                    }
                  }
                });
              };
              
              // Dispatch availability event
              try {
                window.dispatchEvent(new CustomEvent('native-uploader:availability', {
                  detail: { available: true }
                }));
              } catch(e) {}
            }
          } catch (e) {
            console.error('[NativeUploader] Bootstrap error:', e);
          }
        })();
        """
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let webView = self.bridgeViewController?.webView else {
                return
            }
            
            webView.evaluateJavaScript(bootstrapJS) { result, error in
                if let error = error {
                    print("\(NativeUploaderBridge.TAG): Failed to inject JavaScript: \(error.localizedDescription)")
                } else {
                    print("\(NativeUploaderBridge.TAG): JavaScript injected successfully")
                    
                    // Verify what implementation is installed
                    let verifyJS = """
                        (function() {
                            var hasNativeUploader = !!window.NativeUploader;
                            var impl = (window.NativeUploader && window.NativeUploader.__impl) || null;
                            return JSON.stringify({ hasNativeUploader: hasNativeUploader, impl: impl });
                        })();
                    """
                    
                    webView.evaluateJavaScript(verifyJS) { result, error in
                        if let resultString = result as? String,
                           let data = resultString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            let hasNativeUploader = json["hasNativeUploader"] as? Bool ?? false
                            let impl = json["impl"] as? String
                            print("\(NativeUploaderBridge.TAG): [NATIVE-UPLOADER][NATIVE] web impl detected: hasNativeUploader=\(hasNativeUploader), impl=\(impl ?? "none")")
                        } else {
                            print("\(NativeUploaderBridge.TAG): [NATIVE-UPLOADER][NATIVE] could not verify implementation")
                        }
                    }
                }
            }
        }
    }
}

