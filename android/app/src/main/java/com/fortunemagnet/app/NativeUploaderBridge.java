package com.fortunemagnet.app;

import android.content.Intent;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.util.Log;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Native bridge for photo picker and upload functionality.
 * Handles photo selection, image processing, and upload to backend.
 */
public class NativeUploaderBridge {
    private static final String TAG = "NativeUploaderBridge";
    private static final String IMAGE_MIME_TYPE = "image/*";
    
    private final MainActivity activity;
    private final WebView webView;
    private final ExecutorService executorService;
    private String currentRequestId;
    private String accessToken; // Stored access token for API calls
    private JSONObject currentOptions; // Store options from current request

    public NativeUploaderBridge(MainActivity mainActivity, WebView webView) {
        this.activity = mainActivity;
        this.webView = webView;
        this.executorService = Executors.newSingleThreadExecutor();
    }

    /**
     * Sets the access token for authenticated API calls.
     * Called from JavaScript: window.AndroidNativeUploader.setAccessToken(token)
     */
    @JavascriptInterface
    public void setAccessToken(String token) {
        this.accessToken = token;
        Log.d(TAG, "Access token set: " + (token != null && !token.isEmpty() ? "***" + token.substring(Math.max(0, token.length() - 4)) : "null"));
    }

    @JavascriptInterface
    public void pickAndUploadFortunePhoto(String jsonPayload) {
        Log.d(TAG, "pickAndUploadFortunePhoto called with payload: " + jsonPayload);
        
        String id = "0";
        JSONObject options = null;
        String tokenFromOptions = null;
        
        try {
            if (jsonPayload != null) {
                JSONObject obj = new JSONObject(jsonPayload);
                id = obj.optString("id", "0");
                options = obj.optJSONObject("options");
                // Allow token to be passed in options as fallback
                if (options != null) {
                    tokenFromOptions = options.optString("accessToken", null);
                }
            }
        } catch (JSONException e) {
            Log.e(TAG, "Failed to parse JSON payload", e);
            resolveWithError(id, "Invalid request payload");
            return;
        }
        
        // Use token from options if provided, otherwise use stored token
        if (tokenFromOptions != null && !tokenFromOptions.isEmpty()) {
            this.accessToken = tokenFromOptions;
            Log.d(TAG, "Using access token from options");
        }
        
        currentRequestId = id;
        currentOptions = options; // Store options for use in processAndUploadImage
        
        // Launch photo picker on UI thread
        activity.runOnUiThread(() -> {
            Log.d(TAG, "Launching photo picker for request: " + id);
            Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
            intent.setType(IMAGE_MIME_TYPE);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            
            try {
                activity.startPhotoPicker(intent, this);
            } catch (Exception e) {
                Log.e(TAG, "Failed to launch photo picker", e);
                resolveWithError(id, "Failed to launch photo picker: " + e.getMessage());
            }
        });
    }
    
    public void handlePhotoPickerResult(Uri imageUri) {
        if (currentRequestId == null) {
            Log.e(TAG, "No active request ID for photo picker result");
            return;
        }
        
        String requestId = currentRequestId;
        Log.d(TAG, "Photo selected: " + imageUri + " for request: " + requestId);
        
        // Process image on background thread
        executorService.execute(() -> {
            try {
                processAndUploadImage(imageUri, requestId);
            } catch (Exception e) {
                Log.e(TAG, "Error processing image", e);
                resolveWithError(requestId, "Error processing image: " + e.getMessage());
            }
        });
    }
    
    public void handlePhotoPickerCancelled() {
        if (currentRequestId == null) {
            return;
        }
        
        String requestId = currentRequestId;
        currentRequestId = null;
        Log.d(TAG, "Photo picker cancelled for request: " + requestId);
        resolveWithCancelled(requestId);
    }
    
    private void processAndUploadImage(Uri imageUri, String requestId) {
        Log.d(TAG, "Step 1: Reading image from URI: " + imageUri);
        
        int width = 0;
        int height = 0;
        byte[] imageBytes = null;
        
        try (InputStream inputStream = activity.getContentResolver().openInputStream(imageUri)) {
            if (inputStream == null) {
                throw new IOException("Failed to open input stream for image");
            }
            
            // Read bitmap to get dimensions
            BitmapFactory.Options options = new BitmapFactory.Options();
            options.inJustDecodeBounds = true;
            BitmapFactory.decodeStream(inputStream, null, options);
            width = options.outWidth;
            height = options.outHeight;
            Log.d(TAG, "Image dimensions: " + width + "x" + height);
            
            // Read full image bytes
            inputStream.close();
            try (InputStream imageStream = activity.getContentResolver().openInputStream(imageUri)) {
                if (imageStream == null) {
                    throw new IOException("Failed to open image stream");
                }
                
                ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                byte[] chunk = new byte[8192];
                int bytesRead;
                while ((bytesRead = imageStream.read(chunk)) != -1) {
                    buffer.write(chunk, 0, bytesRead);
                }
                imageBytes = buffer.toByteArray();
                Log.d(TAG, "Image size: " + imageBytes.length + " bytes");
            }
        } catch (IOException e) {
            Log.e(TAG, "Error reading image", e);
            resolveWithError(requestId, "Error reading image: " + e.getMessage());
            return;
        }
        
        // Get server URL from Capacitor config
        String serverUrl = getServerUrl();
        if (serverUrl == null || serverUrl.isEmpty()) {
            Log.e(TAG, "Server URL not available");
            resolveWithError(requestId, "Server URL not configured");
            return;
        }
        
        Log.d(TAG, "Step 2: Requesting upload ticket from: " + serverUrl);
        Log.d(TAG, "Using access token: " + (accessToken != null && !accessToken.isEmpty() ? "***" + accessToken.substring(Math.max(0, accessToken.length() - 4)) : "none"));
        
        // Step 1: Issue upload ticket
        JSONObject ticketResponse = issueUploadTicket(serverUrl, requestId);
        if (ticketResponse == null) {
            return; // Error already resolved
        }
        
        // Support BOTH legacy and new ticket formats
        String uploadUrl = ticketResponse.optString("url", "");
        String ticketId = ticketResponse.optString("ticketId", "");
        String bucket = ticketResponse.optString("bucket", "photos");
        
        // Handle bucketRelativePath: new format has it, legacy format has "path"
        String bucketRelativePath = ticketResponse.optString("bucketRelativePath", "");
        if (bucketRelativePath.isEmpty()) {
            bucketRelativePath = ticketResponse.optString("path", "");
        }
        
        // Handle formFieldName: default to "file"
        String formFieldName = ticketResponse.optString("formFieldName", "file");
        
        // Handle headers: new format has "requiredHeaders", legacy has "headers"
        JSONObject requiredHeaders = ticketResponse.optJSONObject("requiredHeaders");
        if (requiredHeaders == null) {
            requiredHeaders = ticketResponse.optJSONObject("headers");
        }
        
        // Extract fortune_id: prefer from options, then from ticket, then fallback to ticketId
        String fortuneId = null;
        if (currentOptions != null) {
            fortuneId = currentOptions.optString("fortuneId", null);
        }
        if (fortuneId == null || fortuneId.isEmpty()) {
            fortuneId = ticketResponse.optString("fortuneId", null);
            if (fortuneId == null || fortuneId.isEmpty()) {
                fortuneId = ticketResponse.optString("fortune_id", null);
            }
        }
        if (fortuneId == null || fortuneId.isEmpty()) {
            fortuneId = ticketId; // Fallback to ticketId
        }
        
        // Log upload URL (sanitized - show host + path prefix, no token)
        String uploadUrlLog = uploadUrl;
        try {
            URL urlObj = new URL(uploadUrl);
            String path = urlObj.getPath();
            if (path.length() > 100) path = path.substring(0, 100) + "...";
            uploadUrlLog = urlObj.getHost() + path;
        } catch (Exception e) {
            if (uploadUrl.length() > 100) uploadUrlLog = uploadUrl.substring(0, 100) + "...";
        }
        
        Log.d(TAG, "TICKET_OK uploadUrl=" + uploadUrlLog + " bucketRelativePath=" + bucketRelativePath);
        
        if (uploadUrl.isEmpty() || bucketRelativePath.isEmpty()) {
            Log.e(TAG, "Invalid ticket response: missing url or path");
            resolveWithError(requestId, "Invalid upload ticket response: missing url or path");
            return;
        }
        
        if (requiredHeaders == null) {
            Log.w(TAG, "No headers/requiredHeaders in ticket, using default x-upsert:true");
        }
        
        // Step 2: Upload to Supabase using POST multipart/form-data
        boolean uploadSuccess = uploadToSupabaseMultipart(uploadUrl, imageBytes, formFieldName, requiredHeaders, requestId);
        if (!uploadSuccess) {
            return; // Error already resolved
        }
        
        // Step 2.5: Verify upload by checking if object exists in Storage
        boolean verifySuccess = verifyUploadInStorage(serverUrl, bucket, bucketRelativePath, requestId);
        if (!verifySuccess) {
            Log.e(TAG, "VERIFY_FAIL: Upload did not persist, stopping");
            resolveWithError(requestId, "Upload verification failed: file not found in storage");
            return;
        }
        
        // Step 3: Finalize with retry logic (max 3 attempts)
        int maxRetries = 3;
        JSONObject finalizeResponse = null;
        boolean finalizeSuccess = false;
        
        for (int retryAttempt = 0; retryAttempt < maxRetries; retryAttempt++) {
            Log.d(TAG, "Finalize attempt " + (retryAttempt + 1) + "/" + maxRetries);
            finalizeResponse = finalizeFortunePhoto(serverUrl, fortuneId, bucket, bucketRelativePath, width, height, imageBytes.length, requestId, retryAttempt, maxRetries);
            
            if (finalizeResponse != null) {
                finalizeSuccess = true;
                break; // Success, exit retry loop
            }
            
            // If this is the last attempt, exit
            if (retryAttempt == maxRetries - 1) {
                Log.e(TAG, "Failed to finalize photo after " + maxRetries + " attempts");
                return; // Error already resolved in finalizeFortunePhoto
            }
            
            // Wait before retry (exponential backoff: 1s, 2s)
            int waitTime = 1000 * (retryAttempt + 1);
            int retriesLeft = maxRetries - retryAttempt - 1;
            Log.d(TAG, "Retrying finalize in " + waitTime + "ms (left=" + retriesLeft + ")");
            try {
                Thread.sleep(waitTime);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
        
        if (!finalizeSuccess) {
            Log.e(TAG, "Failed to finalize photo after " + maxRetries + " attempts");
            resolveWithError(requestId, "Failed to finalize photo after " + maxRetries + " attempts");
            return;
        }
        
        Log.d(TAG, "Upload completed successfully for request: " + requestId);
        
        // Return success - extract signedUrl and replaced from finalize response
        JSONObject result = new JSONObject();
        try {
            String signedUrl = finalizeResponse.optString("signedUrl", "");
            boolean replaced = finalizeResponse.optBoolean("replaced", false);
            result.put("success", true);
            result.put("signedUrl", signedUrl);
            result.put("replaced", replaced);
            result.put("path", bucketRelativePath); // bucket-relative path: userId/file.jpg
            result.put("width", width);
            result.put("height", height);
        } catch (JSONException e) {
            Log.e(TAG, "Error creating result JSON", e);
        }
        
        resolveWithSuccess(requestId, result);
    }
    
    private JSONObject issueUploadTicket(String serverUrl, String requestId) {
        try {
            // Use Supabase Edge Function URL
            String supabaseUrl = serverUrl.contains("supabase.co") ? serverUrl : "https://pegiensgnptpdnfopnoj.supabase.co";
            URL url = new URL(supabaseUrl + "/functions/v1/issue-fortune-upload-ticket");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setRequestProperty("Accept", "application/json");
            
            // Add Authorization header if token is available
            if (accessToken != null && !accessToken.isEmpty()) {
                conn.setRequestProperty("Authorization", "Bearer " + accessToken);
                Log.d(TAG, "Added Authorization header to ticket request");
            } else {
                Log.w(TAG, "No access token available for ticket request");
            }
            
            conn.setDoOutput(true);
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(30000);
            
            // Send request body (empty or with metadata if needed)
            JSONObject requestBody = new JSONObject();
            try (OutputStream os = conn.getOutputStream()) {
                byte[] input = requestBody.toString().getBytes(StandardCharsets.UTF_8);
                os.write(input, 0, input.length);
            }
            
            int responseCode = conn.getResponseCode();
            Log.d(TAG, "Upload ticket response code: " + responseCode);
            
            if (responseCode != HttpURLConnection.HTTP_OK && responseCode != HttpURLConnection.HTTP_CREATED) {
                String errorMsg = readErrorResponse(conn);
                Log.e(TAG, "Failed to issue upload ticket: " + responseCode + " - " + errorMsg);
                resolveWithError(requestId, "Failed to issue upload ticket: " + responseCode);
                return null;
            }
            
            String response = readResponse(conn);
            Log.d(TAG, "Upload ticket response: " + response);
            
            return new JSONObject(response);
            
        } catch (Exception e) {
            Log.e(TAG, "Error issuing upload ticket", e);
            resolveWithError(requestId, "Error issuing upload ticket: " + e.getMessage());
            return null;
        }
    }
    
    private boolean verifyUploadInStorage(String serverUrl, String bucket, String bucketRelativePath, String requestId) {
        try {
            // Use Supabase REST API to list objects
            String supabaseUrl = serverUrl.contains("supabase.co") ? serverUrl : "https://pegiensgnptpdnfopnoj.supabase.co";
            
            // Extract folder and filename from bucketRelativePath
            int lastSlash = bucketRelativePath.lastIndexOf('/');
            String folder = lastSlash >= 0 ? bucketRelativePath.substring(0, lastSlash) : "";
            String filename = lastSlash >= 0 ? bucketRelativePath.substring(lastSlash + 1) : bucketRelativePath;
            
            // Build list API URL: /storage/v1/object/list/{bucket}/{folder}?search={filename}
            StringBuilder listUrlBuilder = new StringBuilder(supabaseUrl);
            listUrlBuilder.append("/storage/v1/object/list/").append(bucket);
            if (!folder.isEmpty()) {
                // URL-encode the entire folder path
                listUrlBuilder.append("/").append(java.net.URLEncoder.encode(folder, StandardCharsets.UTF_8).replace("+", "%20"));
            }
            listUrlBuilder.append("?search=").append(java.net.URLEncoder.encode(filename, StandardCharsets.UTF_8));
            String listUrl = listUrlBuilder.toString();
            
            URL url = new URL(listUrl);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            conn.setRequestProperty("Accept", "application/json");
            
            // Add Authorization header
            if (accessToken != null && !accessToken.isEmpty()) {
                conn.setRequestProperty("Authorization", "Bearer " + accessToken);
            } else {
                Log.w(TAG, "No access token for verification");
                return false;
            }
            
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(30000);
            
            int responseCode = conn.getResponseCode();
            if (responseCode == HttpURLConnection.HTTP_OK) {
                String response = readResponse(conn);
                try {
                    org.json.JSONArray files = new org.json.JSONArray(response);
                    int matches = files.length();
                    Log.d(TAG, "VERIFY_OK matches=" + matches);
                    return matches > 0;
                } catch (Exception e) {
                    Log.e(TAG, "Failed to parse verification response", e);
                    return false;
                }
            } else {
                Log.e(TAG, "VERIFY_FAIL status=" + responseCode);
                return false;
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Error verifying upload in storage", e);
            return false;
        }
    }
    
    private boolean uploadToSupabaseMultipart(String uploadUrl, byte[] imageBytes, String formFieldName, JSONObject requiredHeaders, String requestId) {
        try {
            URL url = new URL(uploadUrl);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            
            // Use POST multipart/form-data (required by createSignedUploadUrl)
            String boundary = "----WebKitFormBoundary" + Long.toString(System.currentTimeMillis());
            conn.setRequestMethod("POST");
            
            // Apply required headers from ticket (e.g., x-upsert: true)
            if (requiredHeaders != null) {
                java.util.Iterator<String> keys = requiredHeaders.keys();
                while (keys.hasNext()) {
                    String key = keys.next();
                    String value = requiredHeaders.optString(key, "");
                    if (!value.isEmpty()) {
                        conn.setRequestProperty(key, value);
                        Log.d(TAG, "Applied required header: " + key + ": " + value);
                    }
                }
            } else {
                // Fallback: always include x-upsert if not provided
                conn.setRequestProperty("x-upsert", "true");
            }
            
            // Let runtime set Content-Type with boundary
            conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);
            conn.setDoOutput(true);
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(60000); // Longer timeout for upload
            
            try (OutputStream os = conn.getOutputStream()) {
                // Write multipart form data
                String lineEnd = "\r\n";
                String twoHyphens = "--";
                
                // Start boundary
                os.write((twoHyphens + boundary + lineEnd).getBytes(StandardCharsets.UTF_8));
                // Content-Disposition header
                os.write(("Content-Disposition: form-data; name=\"" + formFieldName + "\"; filename=\"photo.jpg\"" + lineEnd).getBytes(StandardCharsets.UTF_8));
                // Content-Type header
                os.write(("Content-Type: image/jpeg" + lineEnd).getBytes(StandardCharsets.UTF_8));
                // Empty line before body
                os.write(lineEnd.getBytes(StandardCharsets.UTF_8));
                // File content
                os.write(imageBytes, 0, imageBytes.length);
                // End boundary
                os.write((lineEnd + twoHyphens + boundary + twoHyphens + lineEnd).getBytes(StandardCharsets.UTF_8));
            }
            
            int responseCode = conn.getResponseCode();
            
            String uploadResponseText = "";
            try {
                uploadResponseText = readResponse(conn);
            } catch (Exception e) {
                Log.w(TAG, "Could not read upload response", e);
            }
            
            // Accept 200, 201, or 204 as success
            String bodyPreview = uploadResponseText != null && !uploadResponseText.isEmpty() ? uploadResponseText : "";
            if (bodyPreview.length() > 300) {
                bodyPreview = bodyPreview.substring(0, 300);
            }
            
            if (responseCode == HttpURLConnection.HTTP_OK || responseCode == HttpURLConnection.HTTP_CREATED || responseCode == HttpURLConnection.HTTP_NO_CONTENT) {
                Log.d(TAG, "UPLOAD_OK status=" + responseCode + " body=" + bodyPreview);
            } else {
                Log.e(TAG, "UPLOAD_FAIL status=" + responseCode + " body=" + bodyPreview);
                resolveWithError(requestId, "Failed to upload image: " + responseCode);
                return false;
            }
            
            // Small delay to ensure object is persisted
            try {
                Thread.sleep(1000); // 1 second
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "Error uploading to Supabase", e);
            resolveWithError(requestId, "Error uploading image: " + e.getMessage());
            return false;
        }
    }
    
    private JSONObject finalizeFortunePhoto(String serverUrl, String fortuneId, String bucket, String bucketRelativePath, int width, int height, int sizeBytes, String requestId, int retryAttempt, int maxRetries) {
        try {
            // Use Supabase Edge Function URL
            String supabaseUrl = serverUrl.contains("supabase.co") ? serverUrl : "https://pegiensgnptpdnfopnoj.supabase.co";
            URL url = new URL(supabaseUrl + "/functions/v1/finalize-fortune-photo");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setRequestProperty("Accept", "application/json");
            
            // Add Authorization header if token is available
            if (accessToken != null && !accessToken.isEmpty()) {
                conn.setRequestProperty("Authorization", "Bearer " + accessToken);
            } else {
                Log.w(TAG, "No access token available for finalize request");
            }
            
            conn.setDoOutput(true);
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(30000);
            
            // Send finalize payload - backend expects: fortune_id, bucket, path (bucket-relative, NO prefix)
            JSONObject requestBody = new JSONObject();
            requestBody.put("fortune_id", fortuneId);
            requestBody.put("bucket", bucket);
            requestBody.put("path", bucketRelativePath); // bucket-relative: userId/file.jpg (NO "photos/" prefix)
            requestBody.put("mime", "image/jpeg");
            if (width > 0) requestBody.put("width", width);
            if (height > 0) requestBody.put("height", height);
            if (sizeBytes > 0) requestBody.put("size_bytes", sizeBytes);
            
            try (OutputStream os = conn.getOutputStream()) {
                byte[] input = requestBody.toString().getBytes(StandardCharsets.UTF_8);
                os.write(input, 0, input.length);
            }
            
            int responseCode = conn.getResponseCode();
            String responseBody = readResponse(conn);
            String responsePreview = responseBody.length() > 300 ? responseBody.substring(0, 300) : responseBody;
            
            if (responseCode == HttpURLConnection.HTTP_OK || responseCode == HttpURLConnection.HTTP_CREATED) {
                JSONObject responseJson = new JSONObject(responseBody);
                String signedUrl = responseJson.optString("signedUrl", "");
                Log.d(TAG, "FINALIZE_OK signedUrl=" + (signedUrl.length() > 80 ? signedUrl.substring(0, 80) + "..." : signedUrl));
                return responseJson;
            } else {
                Log.e(TAG, "FINALIZE_FAIL status=" + responseCode + " body=" + responsePreview);
                // Only resolve error on last attempt
                if (retryAttempt == maxRetries - 1) {
                    resolveWithError(requestId, "Failed to finalize photo after " + maxRetries + " attempts: " + responseCode);
                }
                return null;
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Error finalizing photo", e);
            if (retryAttempt == maxRetries - 1) {
                resolveWithError(requestId, "Error finalizing photo: " + e.getMessage());
            }
            return null;
        }
    }
    
    private String getServerUrl() {
        try {
            // Try to get from Capacitor Bridge
            String serverUrl = activity.getServerUrl();
            if (serverUrl != null && !serverUrl.isEmpty()) {
                return serverUrl;
            }
            
            // Fallback: read from capacitor.config.json
            try (InputStream is = activity.getAssets().open("capacitor.config.json")) {
                BufferedReader reader = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) {
                    sb.append(line);
                }
                
                JSONObject config = new JSONObject(sb.toString());
                JSONObject server = config.optJSONObject("server");
                if (server != null) {
                    return server.optString("url", "");
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Error reading server URL", e);
        }
        
        // Final fallback
        return "https://fortune-magnet.vercel.app";
    }
    
    private String readResponse(HttpURLConnection conn) throws IOException {
        InputStream inputStream = conn.getResponseCode() >= 200 && conn.getResponseCode() < 300
            ? conn.getInputStream()
            : conn.getErrorStream();
        
        if (inputStream == null) {
            return "";
        }
        
        BufferedReader reader = new BufferedReader(new InputStreamReader(inputStream, StandardCharsets.UTF_8));
        StringBuilder response = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            response.append(line);
        }
        reader.close();
        return response.toString();
    }
    
    private String readErrorResponse(HttpURLConnection conn) {
        try {
            return readResponse(conn);
        } catch (Exception e) {
            return "Unknown error";
        }
    }
    
    private void resolveWithSuccess(String requestId, JSONObject result) {
        currentRequestId = null;
        currentOptions = null;
        String js = String.format(
            "window.__resolveNativeUpload && window.__resolveNativeUpload('%s', %s);",
            requestId, result.toString()
        );
        activity.runOnUiThread(() -> webView.evaluateJavascript(js, null));
    }
    
    private void resolveWithError(String requestId, String errorMessage) {
        currentRequestId = null;
        currentOptions = null;
        JSONObject error = new JSONObject();
        try {
            error.put("success", false);
            error.put("error", errorMessage);
        } catch (JSONException e) {
            Log.e(TAG, "Error creating error JSON", e);
        }
        
        String js = String.format(
            "window.__resolveNativeUpload && window.__resolveNativeUpload('%s', %s);",
            requestId, error.toString()
        );
        activity.runOnUiThread(() -> webView.evaluateJavascript(js, null));
    }
    
    private void resolveWithCancelled(String requestId) {
        currentRequestId = null;
        currentOptions = null;
        JSONObject cancelled = new JSONObject();
        try {
            cancelled.put("cancelled", true);
        } catch (JSONException e) {
            Log.e(TAG, "Error creating cancelled JSON", e);
        }
        
        String js = String.format(
            "window.__resolveNativeUpload && window.__resolveNativeUpload('%s', %s);",
            requestId, cancelled.toString()
        );
        activity.runOnUiThread(() -> webView.evaluateJavascript(js, null));
    }
}
