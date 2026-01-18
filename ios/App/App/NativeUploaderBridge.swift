import Foundation
import UIKit
import Capacitor

/**
 * Native bridge for photo picker and upload functionality on iOS.
 * Injects JavaScript that uses CapacitorCamera plugin and handles upload pipeline.
 */
@objc class NativeUploaderBridge: NSObject {
    private static let TAG = "NativeUploaderBridge"
    
    weak var bridgeViewController: CAPBridgeViewController?
    
    init(bridgeViewController: CAPBridgeViewController) {
        self.bridgeViewController = bridgeViewController
        super.init()
    }
    
    func injectJavaScript() {
        let bootstrapJS = """
        (function(){
          try {
            if (typeof window.NativeUploaderAvailable === 'undefined') {
              window.NativeUploaderAvailable = true;
              if (!window.NativeUploader) window.NativeUploader = {};
              if (!window.__nativeUploadResolvers) window.__nativeUploadResolvers = {};
              if (!window.__nativeUploadReqId) window.__nativeUploadReqId = 0;
              
              window.NativeUploader.pickAndUploadFortunePhoto = function(options){
                console.log('[NativeUploader] FUNCTION CALLED - pickAndUploadFortunePhoto entry point');
                console.log('[NativeUploader] Options:', JSON.stringify(options || {}).substring(0, 200));
                return new Promise(async function(resolve){
                  console.log('[NativeUploader] Promise created');
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
                        
                        // Always read response body, even for 200 status
                        var responseText = await ticketResponse.text();
                        console.error('[NativeUploader] ⚠️ CRITICAL: Ticket response status:', ticketResponse.status);
                        console.error('[NativeUploader] ⚠️ CRITICAL: Ticket response text length:', responseText.length);
                        console.error('[NativeUploader] ⚠️ CRITICAL: Ticket response text (FULL BODY):', responseText);
                        
                        if (!ticketResponse.ok) {
                          console.error('[NativeUploader] Failed to issue upload ticket:', ticketResponse.status, responseText);
                          resolveOnce({ success: false, error: 'Failed to issue upload ticket: ' + ticketResponse.status });
                          return;
                        }
                        
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:243',message:'BEFORE ticket JSON parse',data:{requestId:id,responseOk:ticketResponse.ok,responseStatus:ticketResponse.status,responseTextLength:responseText.length},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                        // #endregion
                        
                        var ticketData = null;
                        console.error('[NativeUploader] ⚠️ CRITICAL: About to parse ticket JSON response...');
                        try {
                          ticketData = JSON.parse(responseText);
                          console.error('[NativeUploader] ⚠️ CRITICAL: Ticket JSON parsed successfully');
                        } catch (parseError) {
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:250',message:'RESOLVING ERROR - ticket JSON parse failed',data:{requestId:id,error:parseError.message || String(parseError),responseText:responseText.substring(0,500)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                          // #endregion
                          console.error('[NativeUploader] ❌ ERROR: Failed to parse ticket response as JSON:', parseError);
                          console.error('[NativeUploader] ❌ ERROR: Parse error message:', parseError.message);
                          console.error('[NativeUploader] ❌ ERROR: Parse error stack:', parseError.stack);
                          console.error('[NativeUploader] ❌ ERROR: Raw response text:', responseText);
                          resolveOnce({ success: false, error: 'Failed to parse ticket response: ' + (parseError.message || 'Invalid JSON') });
                          return;
                        }
                        
                        // #region agent log
                        fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:257',message:'AFTER ticket JSON parse',data:{requestId:id,hasTicketData:!!ticketData,hasUrl:!!(ticketData && ticketData.url),hasPath:!!(ticketData && (ticketData.bucketRelativePath || ticketData.path)),ticketKeys:ticketData ? Object.keys(ticketData) : []},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                        // #endregion
                        
                        // Log ALL keys in ticketData
                        console.error('[NativeUploader] ⚠️ CRITICAL: Ticket data ALL keys:', ticketData ? Object.keys(ticketData).join(', ') : 'null');
                        console.error('[NativeUploader] ⚠️ CRITICAL: Ticket data FULL JSON:', JSON.stringify(ticketData));
                        
                        // Wrap field extraction in try-catch to handle any unexpected data types
                        var uploadUrl = null;
                        var ticketId = null;
                        var bucket = 'photos'; // Default value
                        var bucketRelativePath = '';
                        var formFieldName = 'file'; // Default value
                        
                        try {
                          // Support BOTH legacy and new ticket formats
                          // Safely extract values, handling null/undefined/type mismatches
                          
                          // Extract uploadUrl - convert to string if needed
                          if (ticketData.url !== undefined && ticketData.url !== null) {
                            if (typeof ticketData.url === 'string') {
                              uploadUrl = ticketData.url;
                            } else {
                              uploadUrl = String(ticketData.url);
                            }
                          }
                          
                          // Extract ticketId
                          if (ticketData.ticketId !== undefined && ticketData.ticketId !== null) {
                            ticketId = ticketData.ticketId;
                          }
                          
                          // Extract bucket with default
                          if (ticketData.bucket !== undefined && ticketData.bucket !== null) {
                            if (typeof ticketData.bucket === 'string') {
                              bucket = ticketData.bucket;
                            } else {
                              bucket = String(ticketData.bucket);
                            }
                          }
                          
                          // Handle bucketRelativePath: new format has it, legacy format has "path"
                          if (ticketData.bucketRelativePath !== undefined && ticketData.bucketRelativePath !== null) {
                            if (typeof ticketData.bucketRelativePath === 'string') {
                              bucketRelativePath = ticketData.bucketRelativePath;
                            } else {
                              bucketRelativePath = String(ticketData.bucketRelativePath);
                            }
                          } else if (ticketData.path !== undefined && ticketData.path !== null) {
                            if (typeof ticketData.path === 'string') {
                              bucketRelativePath = ticketData.path;
                            } else {
                              bucketRelativePath = String(ticketData.path);
                            }
                          }
                          
                          // Handle formFieldName: default to "file"
                          if (ticketData.formFieldName !== undefined && ticketData.formFieldName !== null) {
                            if (typeof ticketData.formFieldName === 'string') {
                              formFieldName = ticketData.formFieldName;
                            } else {
                              formFieldName = String(ticketData.formFieldName);
                            }
                          }
                        } catch (fieldExtractionError) {
                          // Non-fatal: log warning but continue with defaults
                          console.warn('[NativeUploader] Warning: Error extracting fields from ticket (non-fatal, using defaults):', fieldExtractionError);
                          // Values already have defaults above
                        }
                        
                        // Log extracted values BEFORE parsing headers
                        console.error('[NativeUploader] ⚠️ CRITICAL: Extracted values BEFORE header parsing:');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - bucket:', bucket, '(raw:', ticketData.bucket, ')');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - url:', uploadUrl ? (uploadUrl.length > 100 ? uploadUrl.substring(0, 100) + '...' : uploadUrl) : 'MISSING', '(raw:', ticketData.url, ')');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - path:', bucketRelativePath, '(raw bucketRelativePath:', ticketData.bucketRelativePath, ', raw path:', ticketData.path, ')');
                        console.error('[NativeUploader] ⚠️ CRITICAL:   - formFieldName:', formFieldName, '(raw:', ticketData.formFieldName, ')');
                        
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
                        var validationErrors = [];
                        
                        // Check uploadUrl - must be a non-empty string
                        var urlIsValid = false;
                        if (uploadUrl && typeof uploadUrl === 'string') {
                          var trimmedUrl = uploadUrl.trim();
                          if (trimmedUrl.length > 0) {
                            urlIsValid = true;
                          }
                        }
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
                        if (!pathIsValid) {
                          validationErrors.push('path (bucketRelativePath) is missing, empty, or invalid type (got: ' + (typeof bucketRelativePath) + ')');
                        }
                        
                        // Only fail if BOTH required fields are missing - never fail due to headers
                        if (validationErrors.length > 0) {
                          // #region agent log
                          fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:288',message:'RESOLVING ERROR - missing required fields in ticket',data:{requestId:id,validationErrors:validationErrors,hasUploadUrl:!!uploadUrl,hasBucketRelativePath:!!bucketRelativePath,uploadUrlType:typeof uploadUrl,pathType:typeof bucketRelativePath,uploadUrl:uploadUrl || 'empty',bucketRelativePath:bucketRelativePath || 'empty',ticketKeys:ticketData ? Object.keys(ticketData) : [],ticketDataString:JSON.stringify(ticketData).substring(0,500)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'E'})}).catch(()=>{});
                          // #endregion
                          console.error('[NativeUploader] ❌ ERROR: Invalid ticket response - required fields missing');
                          console.error('[NativeUploader] ❌ ERROR: Validation errors:', validationErrors);
                          console.error('[NativeUploader] ❌ ERROR: uploadUrl:', uploadUrl ? ('present (' + typeof uploadUrl + '): "' + uploadUrl + '"') : 'MISSING');
                          console.error('[NativeUploader] ❌ ERROR: bucketRelativePath:', bucketRelativePath ? ('present (' + typeof bucketRelativePath + '): "' + bucketRelativePath + '"') : 'MISSING');
                          console.error('[NativeUploader] ❌ ERROR: Full ticketData:', JSON.stringify(ticketData));
                          console.error('[NativeUploader] ❌ ERROR: This error will cause flow to cancel at stage "ticket"');
                          resolveOnce({ success: false, error: 'Invalid upload ticket response: ' + validationErrors.join(', ') });
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
                        
                        // Step 2: Upload to Supabase signed upload URL via POST multipart/form-data
                        // Use FormData so Content-Type with boundary is set automatically by fetch
                        var formData = new FormData();
                        formData.append(formFieldName, imageBlob, 'photo.jpg');
                        
                        // Build upload headers from ticket (use requiredHeaders, do NOT set Content-Type - fetch will set it automatically with boundary)
                        var uploadHeaders = {};
                        if (requiredHeaders && typeof requiredHeaders === 'object') {
                          for (var key in requiredHeaders) {
                            if (Object.prototype.hasOwnProperty.call(requiredHeaders, key)) {
                              uploadHeaders[key] = requiredHeaders[key];
                            }
                          }
                        }
                        // Ensure x-upsert default if not in ticket
                        if (!uploadHeaders['x-upsert']) {
                          uploadHeaders['x-upsert'] = 'true';
                        }
                        // DO NOT set Content-Type - fetch will set it automatically with boundary when using FormData
                        
                        console.log('[NativeUploader] UPLOAD_START method=POST path=' + bucketRelativePath + ' field=' + formFieldName + ' headers=' + JSON.stringify(uploadHeaders));
                        var uploadResponse = await fetch(uploadUrl, {
                          method: 'POST',
                          headers: uploadHeaders,
                          body: formData
                        });

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

                        if (uploadStatus === 200 || uploadStatus === 201 || uploadStatus === 204) {
                          console.log('UPLOAD_OK status=' + uploadStatus + ' body=' + uploadBodyPreview);
                        } else {
                          console.error('UPLOAD_FAIL status=' + uploadStatus + ' body=' + uploadBodyPreview);
                          resolveOnce({ success: false, error: 'Failed to upload image: ' + uploadStatus, stage: 'upload' });
                          return;
                        }

                        // Step 2.5: Verify upload by checking if object exists in Storage using HTTP LIST API
                        console.log('[NativeUploader] Verifying upload in storage...');
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

                          if (matches === 0) {
                            console.error('VERIFY_FAIL matches=0');
                            resolveOnce({ success: false, error: 'Upload verification failed: file not found in storage', stage: 'verify' });
                            return;
                          }
                        } catch (verifyError) {
                          console.error('[NativeUploader] Verification error:', verifyError);
                          resolveOnce({ success: false, error: 'Upload verification failed: ' + (verifyError.message || 'Unknown error'), stage: 'verify' });
                          return;
                        }
                        
                        // Step 3: Finalize (POST to Supabase Edge Function) with retry logic
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
                            
                            var finalizeHeaders = { 'Content-Type': 'application/json' };
                            if (supabaseToken) {
                              finalizeHeaders['Authorization'] = 'Bearer ' + supabaseToken;
                            }
                            if (supabaseAnonKey) {
                              finalizeHeaders['apikey'] = supabaseAnonKey;
                            }
                            
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
                              finalizeSuccess = true;
                              break; // Success, exit retry loop
                            } else {
                              console.error('FINALIZE_FAIL status=' + finalizeStatus + ' body=' + finalizeResponsePreview);
                              
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
                    // #region agent log
                    fetch('http://127.0.0.1:7243/ingest/cbd6263e-f536-4878-bd07-bd07-b4ffde5dafde',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({location:'NativeUploaderBridge.swift:442',message:'Outer catch - general error',data:{requestId:id,errorType:typeof e,errorMessage:e.message || String(e) || 'no message',hasMessage:!!e.message,errorString:String(e)},timestamp:Date.now(),sessionId:'debug-session',runId:'run1',hypothesisId:'B,E'})}).catch(()=>{});
                    // #endregion
                    
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
                }
            }
        }
    }
}
