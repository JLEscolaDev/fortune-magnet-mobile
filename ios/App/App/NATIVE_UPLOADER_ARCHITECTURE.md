# Native Uploader Architecture - iOS Implementation

## Tabla de Contenidos

1. [Visión General](#visión-general)
2. [Arquitectura del Sistema](#arquitectura-del-sistema)
3. [Clases Clave](#clases-clave)
4. [Flujo Completo de Upload](#flujo-completo-de-upload)
5. [Selección de Fotos: Capacitor Camera Plugin](#selección-de-fotos-capacitor-camera-plugin)
6. [Inyección de JavaScript](#inyección-de-javascript)
7. [Comunicación Web ↔ Native](#comunicación-web--native)
8. [Edge Functions - Contratos de API](#edge-functions---contratos-de-api)
9. [Manejo de Memoria y Performance](#manejo-de-memoria-y-performance)
10. [Manejo de Errores y Edge Cases](#manejo-de-errores-y-edge-cases)
11. [Debugging y Logging](#debugging-y-logging)
   - [Cómo Leer los Logs de iOS](#cómo-leer-los-logs-de-ios)
   - [Logs Clave para Debugging](#logs-clave-para-debugging)
   - [Identificar Qué Código Está Ejecutándose](#identificar-qué-código-está-ejecutándose)
   - [Checklist de Diagnóstico para Lovable](#checklist-de-diagnóstico-para-lovable)
12. [Cómo Modificar el Código](#cómo-modificar-el-código)
13. [Troubleshooting](#troubleshooting)
   - [Resumen Ejecutivo para Lovable](#resumen-ejecutivo-para-lovable)
   - [Problema: UPLOAD_NOT_PERSISTED](#problema-upload_not_persisted---el-archivo-no-se-encuentra-después-del-upload)
14. [Preguntas Frecuentes](#preguntas-frecuentes)

---

## Visión General

El sistema de **Native Uploader** permite que la aplicación web (que corre en un WebView de Capacitor) pueda usar funcionalidades nativas de iOS para seleccionar y subir fotos. La arquitectura utiliza:

- **Swift (iOS Native)**: Maneja la inyección de JavaScript en el WebView
- **JavaScript (Inyectado)**: Se ejecuta dentro del WebView y maneja toda la lógica de upload
- **Capacitor Camera Plugin**: Para acceder al selector de fotos nativo de iOS
- **Supabase Edge Functions**: Para obtener tickets de upload y finalizar el proceso

**Punto crítico**: Aunque el código está en Swift, **toda la lógica de upload se ejecuta en JavaScript dentro del WebView**. El Swift solo inyecta el código JavaScript al inicio.

---

## Arquitectura del Sistema

```
┌─────────────────────────────────────────────────────────────┐
│                    iOS App (Swift)                          │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  AppDelegate.swift                                    │  │
│  │  - Inicializa NativeUploaderBridge                   │  │
│  │  - Inyecta JavaScript al WebView                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                        │                                    │
│                        ▼                                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  NativeUploaderBridge.swift                           │  │
│  │  - Contiene JavaScript como string                    │  │
│  │  - Lo inyecta vía webView.evaluateJavaScript()       │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                        │
                        │ Inyecta JavaScript
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              WebView (Capacitor)                            │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  JavaScript Inyectado (window.NativeUploader)       │  │
│  │                                                       │  │
│  │  1. pickAndUploadFortunePhoto(options)               │  │
│  │     ├─ Capacitor.Plugins.Camera.getPhoto()          │  │
│  │     ├─ POST /functions/v1/issue-fortune-upload-ticket│  │
│  │     ├─ PUT uploadUrl (raw bytes)                    │  │
│  │     ├─ GET /storage/v1/object/list (verify)         │  │
│  │     └─ POST /functions/v1/finalize-fortune-photo    │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                        │
                        │ HTTP Requests
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              Supabase Backend                               │
│                                                             │
│  • Edge Function: issue-fortune-upload-ticket               │
│  • Storage: Signed URL para PUT                            │
│  • Edge Function: finalize-fortune-photo                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Clases Clave

### 1. `AppDelegate.swift`

**Ubicación**: `ios/App/App/AppDelegate.swift`

**Responsabilidad**: 
- Punto de entrada de la aplicación iOS
- Inicializa `NativeUploaderBridge` cuando el WebView está listo
- Maneja el ciclo de vida de la app

**Código Clave**:

```swift
class AppDelegate: UIResponder, UIApplicationDelegate {
    private var uploaderBridge: NativeUploaderBridge?
    private var uploaderInjected = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions...) -> Bool {
        // Espera 0.5s para que el WebView esté listo
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self?.injectUploaderBridge()
        }
        return true
    }
    
    private func injectUploaderBridge() {
        guard !uploaderInjected else { return }
        
        // Obtiene el CAPBridgeViewController del window
        guard let window = window,
              let rootViewController = window.rootViewController as? CAPBridgeViewController,
              rootViewController.webView != nil else {
            // Reintenta si el bridge no está listo
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.injectUploaderBridge()
            }
            return
        }
        
        // Crea e inyecta el bridge
        uploaderBridge = NativeUploaderBridge(bridgeViewController: rootViewController)
        uploaderBridge?.injectJavaScript()
        uploaderInjected = true
    }
}
```

**Cuándo modificar**: 
- Si necesitas cambiar cuándo se inyecta el JavaScript
- Si necesitas múltiples inyecciones o reinyecciones

**Nota sobre Memory Management**: Se usa `weak var bridgeViewController` en `NativeUploaderBridge` para prevenir retain cycles. Si el view controller se dealloca durante la inyección, el código simplemente retorna sin hacer nada, lo cual es preferible a un memory leak.

---

### 2. `NativeUploaderBridge.swift`

**Ubicación**: `ios/App/App/NativeUploaderBridge.swift`

**Responsabilidad**:
- Contiene el código JavaScript completo como string literal
- Lo inyecta en el WebView usando `evaluateJavaScript()`
- Verifica que la inyección fue exitosa

**Estructura**:

```swift
@objc class NativeUploaderBridge: NSObject {
    private static let TAG = "NativeUploaderBridge"
    private static let NATIVE_UPLOADER_IMPL_VERSION = "ios-injected-v3-2026-01-18"
    
    weak var bridgeViewController: CAPBridgeViewController?
    
    init(bridgeViewController: CAPBridgeViewController) {
        self.bridgeViewController = bridgeViewController
        super.init()
    }
    
    func injectJavaScript() {
        let bootstrapJS = """
        (function(){
          // TODO EL CÓDIGO JAVASCRIPT VA AQUÍ
        })();
        """
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let webView = self.bridgeViewController?.webView else {
                return
            }
            
            webView.evaluateJavaScript(bootstrapJS) { result, error in
                // Verifica que se inyectó correctamente
            }
        }
    }
}
```

**Versión de Implementación**: 
- `NATIVE_UPLOADER_IMPL_VERSION` se usa para evitar sobrescribir implementaciones existentes
- Si `window.NativeUploader.__impl` ya existe, NO se sobrescribe
- Esto permite que el código web pueda definir su propia implementación si es necesario

**Cuándo modificar**:
- **Cualquier cambio en la lógica de upload** debe hacerse aquí (en el string JavaScript)
- Cambios en el flujo de upload
- Cambios en los headers, métodos HTTP, etc.

---

## Flujo Completo de Upload

### Paso 1: Llamada desde el Código Web

El código web llama a la función inyectada:

```javascript
// En tu código web (React/Vue/etc)
const result = await window.NativeUploader.pickAndUploadFortunePhoto({
  fortuneId: '123e4567-e89b-12d3-a456-426614174000'
});
```

**Ubicación en código**: El JavaScript inyectado define esta función en `window.NativeUploader.pickAndUploadFortunePhoto` (línea ~58 del Swift file)

---

### Paso 2: Validación y Guard contra Duplicados

```javascript
// Guard contra uploads paralelos
if (window.__nativeUploadActive) {
  return Promise.resolve({ error: true, stage: 'busy' });
}
window.__nativeUploadActive = true;

// Validación de parámetros
if (!options || !options.fortuneId) {
  resolveOnce({ success: false, error: 'Missing fortuneId' });
  return;
}
```

**Guard `__nativeUploadActive`**: 
- Previene múltiples uploads simultáneos
- Si hay un upload en progreso, las llamadas subsecuentes retornan inmediatamente con `{ error: true, stage: 'busy' }`
- Se limpia automáticamente cuando el upload termina (éxito o error)
- **Importante**: Si hay un error no manejado fuera del Promise, el flag puede quedarse bloqueado

**`resolveOnce`**: 
- Previene "double resolve" que causaría warnings en JavaScript
- Usa un flag `resolved` para asegurar que `resolve()` solo se llama una vez
- Siempre limpia `__nativeUploadActive` al resolver, incluso si hay múltiples intentos

**Ubicación**: Líneas 68-76 y 240-247

---

## Selección de Fotos: Capacitor Camera Plugin

### Configuración Actual

El código usa la siguiente configuración de Capacitor Camera:

```javascript
var cameraResult = await Capacitor.Plugins.Camera.getPhoto({
  quality: 90,              // Calidad de compresión JPEG (0-100)
  allowEditing: false,      // NO muestra pantalla de edición
  source: 'PHOTOS',         // Abre la galería de fotos (no la cámara)
  resultType: 'Uri',        // Retorna URI, no base64
  correctOrientation: true  // Corrige orientación EXIF automáticamente
});
```

### Flujo de Selección en iOS

Cuando el usuario llama a `pickAndUploadFortunePhoto()`, ocurre lo siguiente:

1. **Apertura del Selector de Fotos Nativo**:
   - Capacitor Camera abre el selector nativo de iOS (`UIImagePickerController`)
   - Con `source: 'PHOTOS'`, muestra la galería de fotos del dispositivo
   - El usuario puede navegar por sus álbumes y seleccionar una foto

2. **Selección de Foto**:
   - El usuario toca una foto en la galería
   - iOS muestra una vista previa de la foto seleccionada
   - **Importante**: Aunque `allowEditing: false`, iOS muestra una pantalla de confirmación donde el usuario puede:
     - Ver la foto seleccionada
     - Hacer zoom/pan para ajustar el encuadre
     - Confirmar con "Choose" o cancelar con "Cancel"

3. **Procesamiento de la Foto**:
   - Si el usuario confirma, Capacitor procesa la foto según la configuración:
     - `quality: 90` comprime la imagen a calidad 90% (balance entre tamaño y calidad)
     - `correctOrientation: true` lee los metadatos EXIF y rota la imagen si es necesario
     - `resultType: 'Uri'` guarda la foto procesada en un archivo temporal y retorna la URI

4. **Resultado**:
   ```javascript
   {
     webPath: "capacitor://localhost/_capacitor_file_/path/to/image.jpg",
     width: 1920,   // Dimensiones después de corrección de orientación
     height: 1080
   }
   ```

### ¿Por qué se Muestra una Segunda Pantalla?

Aunque `allowEditing: false`, iOS siempre muestra una pantalla de confirmación después de seleccionar una foto. Esta pantalla permite:

- **Vista previa**: El usuario puede ver exactamente qué foto seleccionó
- **Ajuste de encuadre**: Aunque no hay edición completa, el usuario puede hacer zoom/pan
- **Confirmación explícita**: El usuario debe confirmar con "Choose" antes de que la app reciba la foto

**Esto es comportamiento nativo de iOS** y no se puede deshabilitar completamente. Es parte del flujo estándar de `UIImagePickerController`.

### Manejo de Cancelación

El código maneja la cancelación en múltiples puntos:

1. **Cancelación explícita**: Si `cameraResult === null || cameraResult === undefined` → Retorna `{ cancelled: true }`
2. **Sin datos**: Si no hay `webPath` ni `path` → Retorna `{ cancelled: true }`
3. **Error con "cancel"**: Si el error contiene "cancel" o "cancelled" → Retorna `{ cancelled: true }`

**Importante**: Solo se considera cancelación si es explícita. Otros errores se tratan como fallos y retornan `{ success: false, error: '...' }`.

### Formatos Soportados

El código detecta automáticamente estos formatos desde los bytes de la imagen:

- **JPEG**: Detectado por los primeros bytes `FF D8 FF`
- **PNG**: Detectado por `89 50 4E 47`
- **WebP**: Detectado por `RIFF` (52 49 46 46)

**Limitación**: Solo estos 3 formatos están soportados explícitamente. Si el usuario selecciona un HEIC, GIF, o otro formato:
- El código lo tratará como JPEG (fallback)
- El edge function puede rechazar formatos no soportados
- Se recomienda validar el formato en el edge function

### Corrección de Orientación

`correctOrientation: true` es crítico porque:

- Las fotos tomadas en portrait pueden tener metadatos EXIF que indican rotación
- Sin corrección, la imagen puede aparecer rotada incorrectamente
- Capacitor lee los metadatos EXIF y rota la imagen físicamente antes de retornarla
- El código recibe dimensiones ya corregidas (`width` y `height` reflejan la orientación final)

**Limitación**: Si la imagen ya está en el dispositivo sin metadatos EXIF correctos, `correctOrientation` no puede ayudar. En ese caso, el código también obtiene dimensiones cargando la imagen en un elemento `<img>` como fallback.

**Ubicación**: Líneas 119-156

---

### Paso 3: Carga de Imagen y Extracción de Metadata

```javascript
// Carga la imagen desde el URI
var fileResp = await fetch(webPath);
var blob = await fileResp.blob();
var mimeType = blob.type || 'image/jpeg';
var buf = await blob.arrayBuffer();
var imageBytes = new Uint8Array(buf);

// Obtiene dimensiones (de cameraResult o carga imagen)
var width = cameraResult.width || 0;
var height = cameraResult.height || 0;
if (!width || !height) {
  // Carga imagen para obtener dimensiones
  var img = new Image();
  img.src = webPath;
  await new Promise((resolve) => { img.onload = resolve; });
  width = img.width;
  height = img.height;
}
```

**Obtención de Dimensiones**:
- Primero intenta usar `cameraResult.width/height` (más rápido, preferido)
- Si faltan, carga la imagen en un elemento `<img>` y espera a que cargue
- Esto añade ~100-500ms de delay pero garantiza dimensiones correctas

**Ubicación**: Líneas 164-188

---

### Paso 4: Obtención de Credenciales Supabase

El código busca credenciales en varios lugares del objeto `window`:

```javascript
var supabaseUrl = 'https://pegiensgnptpdnfopnoj.supabase.co'; // Default
var supabaseToken = '';
var supabaseAnonKey = '';

// Intenta múltiples fuentes:
// 1. Variables globales explícitas
if (window.__SUPABASE_URL__) supabaseUrl = window.__SUPABASE_URL__;
if (window.__SUPABASE_ANON_KEY__) supabaseAnonKey = window.__SUPABASE_ANON_KEY__;
if (window.__SUPABASE_ACCESS_TOKEN__) supabaseToken = window.__SUPABASE_ACCESS_TOKEN__;

// 2. Cliente Supabase (API antigua)
if (window.supabase && window.supabase.auth) {
  var session = window.supabase.auth.session();
  if (session && session.access_token) supabaseToken = session.access_token;
}

// 3. Cliente Supabase (API nueva)
if (window.supabase && window.supabase.auth && window.supabase.auth.getSession) {
  var sessionResult = await window.supabase.auth.getSession();
  if (sessionResult?.data?.session?.access_token) {
    supabaseToken = sessionResult.data.session.access_token;
  }
}
```

**Cómo exponer credenciales desde tu código web**:

```javascript
// Opción 1: Variables globales (más simple y confiable)
window.__SUPABASE_URL__ = 'https://tu-proyecto.supabase.co';
window.__SUPABASE_ANON_KEY__ = 'tu-anon-key';
window.__SUPABASE_ACCESS_TOKEN__ = session.access_token;

// Opción 2: El código detecta automáticamente window.supabase
// Si usas @supabase/supabase-js, ya debería funcionar
```

**Refresh de Tokens**: 
- **NO hay refresh automático**. El token se obtiene una vez al inicio y se usa durante todo el proceso
- Si el token expira durante el upload o finalize, la request fallará con 401
- **Solución**: Refresca el token antes de llamar a `pickAndUploadFortunePhoto()`, o expón un token fresco en `window.__SUPABASE_ACCESS_TOKEN__` justo antes de la llamada

**Ubicación**: Líneas 190-226

---

### Paso 5: Solicitud de Ticket de Upload

**Endpoint**: `POST /functions/v1/issue-fortune-upload-ticket`

**Request**:
```javascript
var ticketResponse = await fetch(supabaseUrl + '/functions/v1/issue-fortune-upload-ticket', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ' + supabaseToken,
    'apikey': supabaseAnonKey
  },
  body: JSON.stringify({
    fortune_id: fortuneId,
    mime: mimeType  // 'image/jpeg', 'image/png', etc.
  })
});
```

**Response Esperado** (JSON):
```json
{
  "url": "https://storage.supabase.co/object/signed-url-here",
  "bucketRelativePath": "userId/filename.jpg",
  "bucket": "photos",
  "requiredHeaders": {
    "x-upsert": "true"
  }
}
```

**Campos soportados** (el código es resiliente a variaciones):
- `url` / `uploadUrl` / `upload_url` / `signedUrl` / `signed_url` → URL para upload
- `bucketRelativePath` / `path` / `filePath` / `dbPath` / `db_path` → Ruta relativa al bucket
- `requiredHeaders` / `headers` → Headers adicionales para el upload
- `bucket` / `bucket_name` → Nombre del bucket (default: "photos")
- `formFieldName` → Nombre del campo en multipart (default: "file", pero ya no se usa con PUT)

**Validación**:
- `url` es **REQUERIDO** (debe ser string no vacío)
- `bucketRelativePath` es **REQUERIDO** (debe ser string no vacío)
- `requiredHeaders` es **OPCIONAL** (si falta, usa `{ 'x-upsert': 'true' }`)

**Manejo de Errores de Parseo**:
- El código tiene try-catch explícito alrededor del parseo JSON
- Si el edge function retorna HTML (página de error), el código intenta parsearlo como JSON y falla
- Los logs mostrarán el HTML completo, lo cual ayuda a debuggear
- **Mejora sugerida**: Verificar `Content-Type` header antes de parsear

**Ubicación**: Líneas 252-363

---

### Paso 6: Upload a Storage (PUT con Raw Bytes)

**Cambio crítico**: El código ahora usa **PUT** con bytes raw, NO multipart POST.

**Por qué PUT en lugar de POST**:
- **PUT es idempotente**: Puedes repetir la misma request sin efectos secundarios
- **Más simple**: No necesita multipart/form-data, solo envías los bytes raw con Content-Type
- **Mejor para signed URLs**: Los signed URLs de Storage están diseñados para PUT
- **Headers más limpios**: Solo necesitas Content-Type, no boundary

**Detección de MIME Type**:

```javascript
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

var detectedMimeType = getMimeTypeFromBytes(imageBytes);

// Construye headers
var uploadHeaders = {
  'Content-Type': detectedMimeType
};

// Añade headers adicionales del ticket (excepto Content-Type)
if (requiredHeaders && typeof requiredHeaders === 'object') {
  for (var key in requiredHeaders) {
    if (key.toLowerCase() !== 'content-type') {
      uploadHeaders[key] = requiredHeaders[key];
    }
  }
}

// PUT request con raw bytes
var uploadResponse = await fetch(uploadUrl, {
  method: 'PUT',  // CRÍTICO: PUT, no POST
  headers: uploadHeaders,
  body: imageBytes  // Raw bytes, NO multipart
});
```

**Manejo de Headers con Valores No-String**:
- Los headers HTTP solo aceptan strings
- El código convierte automáticamente valores booleanos, números, null, undefined a strings
- Si el edge function retorna `requiredHeaders: { "x-upsert": true }`, se convierte a `"true"`
- Objetos complejos se convierten con `JSON.stringify()`

**Response Esperado**:
- Status `200`, `201`, o `204` → Éxito
- Cualquier otro status → Error

**Retry**: **NO hay retry automático para el upload PUT**. Solo el paso de finalize tiene retry. Si el PUT falla por error de red, el código retorna inmediatamente con error. Esto es intencional porque:
1. El signed URL puede expirar
2. El usuario debería poder reintentar manualmente
3. El upload es el paso más costoso en términos de datos

**Cancelación**: **NO hay forma de cancelar un upload en progreso**. Una vez que comienza el PUT, no hay mecanismo de cancelación. Para añadir cancelación, necesitarías usar `AbortController`.

**Ubicación**: Líneas 659-735

---

### Paso 7: Verificación de Upload

Verifica que el archivo existe en Storage antes de finalizar:

```javascript
// Extrae folder y filename de bucketRelativePath
var lastSlash = bucketRelativePath.lastIndexOf('/');
var folder = lastSlash >= 0 ? bucketRelativePath.substring(0, lastSlash) : '';
var filename = lastSlash >= 0 ? bucketRelativePath.substring(lastSlash + 1) : bucketRelativePath;

var folderPath = folder ? folder : '';
var listUrl = supabaseUrl + '/storage/v1/object/list/' + bucket + '/' + folderPath + '?search=' + encodeURIComponent(filename);

var listResponse = await fetch(listUrl, {
  method: 'GET',
  headers: {
    'Authorization': 'Bearer ' + supabaseToken,
    'apikey': supabaseAnonKey
  }
});

var listData = await listResponse.json();
var matches = (listData && Array.isArray(listData)) ? listData.length : 0;

if (matches === 0) {
  // Error: archivo no encontrado
  resolveOnce({ success: false, error: 'Upload verification failed: file not found in storage', stage: 'verify' });
  return;
}
```

**Por qué se Verifica**:
1. **Eventual consistency**: Storage puede retornar 200 pero el archivo puede no estar disponible inmediatamente
2. **Errores silenciosos**: Algunos sistemas retornan 200 incluso si el upload falla internamente
3. **Validación de ruta**: Confirma que el archivo está en la ruta esperada
4. **Prevención de finalize prematuro**: Evita que finalize se ejecute si el archivo realmente no existe

**Trade-off**: Añade una request HTTP adicional, pero previene errores más costosos en finalize.

**Ubicación**: Líneas 737-799

---

### Paso 8: Finalización (con Retry)

**Endpoint**: `POST /functions/v1/finalize-fortune-photo`

**Request**:
```javascript
var finalizePayload = {
  fortune_id: fortuneId,
  bucket: bucket,
  path: bucketRelativePath,  // bucket-relative: userId/file.jpg (NO "photos/" prefix)
  mime: mimeType,
  width: width || null,
  height: height || null,
  size_bytes: imageBytes.length || null
};

var finalizeResponse = await fetch(supabaseUrl + '/functions/v1/finalize-fortune-photo', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ' + supabaseToken,
    'apikey': supabaseAnonKey
  },
  body: JSON.stringify(finalizePayload)
});
```

**Retry Logic**:
- Máximo 3 intentos
- Backoff exponencial: 1s, 2s entre intentos
- Solo reintenta si el status NO es 200/201

**Response Esperado**:
```json
{
  "signedUrl": "https://storage.supabase.co/object/public/...",
  "replaced": false
}
```

**Ubicación**: Líneas 801-905

---

### Paso 9: Respuesta Final

```javascript
resolveOnce({
  success: true,
  signedUrl: finalizeData.signedUrl || '',
  replaced: finalizeData.replaced || false,
  path: bucketRelativePath,
  width: width,
  height: height,
  size_bytes: imageBytes.length
});
```

**Errores posibles**:
```javascript
// Cancelación
{ cancelled: true }

// Error con stage
{ 
  success: false, 
  error: 'Error message', 
  stage: 'ticket' | 'upload' | 'verify' | 'finalize' 
}

// Error sin stage
{ success: false, error: 'Error message' }
```

---

## Manejo de Memoria y Performance

### Carga de Imágenes en Memoria

**Problema**: Toda la imagen se carga completamente en memoria antes del upload. El flujo es:

1. `fetch(webPath)` carga la imagen completa
2. `blob.arrayBuffer()` convierte a ArrayBuffer en memoria
3. `new Uint8Array(buf)` crea otra copia en memoria
4. `fetch(uploadUrl, { body: imageBytes })` mantiene otra referencia

**Impacto**: Una imagen de 10MB puede usar 30-40MB de RAM temporalmente.

**Límites Prácticos**:
- **Memoria del dispositivo**: Las imágenes muy grandes pueden causar OOM (Out of Memory)
- **Timeout de red**: Las requests HTTP pueden timeout si son muy grandes (default: 30-60s)
- **Límites de Supabase Storage**: Supabase tiene límites por plan
- **Límites del edge function**: Pueden tener timeouts (típicamente 60s)

**Recomendaciones**:
- El código usa `quality: 90` en Camera.getPhoto(), lo cual comprime la imagen
- Para imágenes muy grandes, considera comprimir adicionalmente en el cliente antes del upload
- Considera usar streaming para uploads muy grandes (requiere cambios significativos)

### Límites de Tamaño de Archivo

**No hay límite explícito** en el código JavaScript. Los límites son prácticos:

- **iOS**: Limitado por memoria disponible del dispositivo
- **Supabase Storage**: Limitado por el plan (gratis: 1GB total, Pro: 100GB)
- **Network**: Timeouts en requests muy grandes
- **Edge Functions**: Timeouts típicamente a 60s

**Recomendación**: Comprimir imágenes antes de subirlas. El código ya comprime a calidad 90%, pero para imágenes muy grandes (ej: RAW), considera compresión adicional.

---

## Manejo de Errores y Edge Cases

### WebView se Recarga Durante Upload

**Problema**: Si el WebView se recarga durante un upload:
1. Todo el JavaScript se reinicia
2. Las variables globales (`__nativeUploadActive`, `__nativeUploadResolvers`) se pierden
3. El Promise nunca se resuelve
4. El upload puede completarse en el servidor, pero el cliente no lo sabrá

**Solución**: El código web debe evitar recargar durante uploads, o implementar un sistema de recuperación que verifique uploads pendientes al iniciar.

### App va a Background Durante Upload

**Comportamiento**:
- **iOS**: Puede pausar el WebView cuando la app va a background
- **JavaScript**: Las Promises pueden continuar ejecutándose en background (depende de la implementación)
- **Network requests**: Pueden continuar o cancelarse según la política del OS

**Comportamiento típico**:
- Si el upload PUT ya comenzó: probablemente continúa
- Si está en el paso de finalize: puede continuar o timeout
- Si el usuario vuelve a la app: el Promise puede resolverse normalmente o estar "colgado"

**Mejora sugerida**: Escuchar eventos de lifecycle de Capacitor y cancelar uploads cuando la app va a background.

### Signed URL Expira Antes del Upload

**Problema**: Si el signed URL expira antes de que se complete el upload:
- El PUT fallará con 403 Forbidden o 401 Unauthorized
- El código retornará error en el paso de upload

**Causas comunes**:
- Upload muy lento (red lenta, imagen grande)
- Signed URL con TTL muy corto (ej: 60 segundos)
- Delay entre obtener ticket y hacer upload

**Solución en edge function**: Generar signed URLs con TTL suficiente (ej: 5-10 minutos). El código no puede refrescar el URL automáticamente porque requiere llamar al edge function de nuevo.

### Bucket No Existe

**Problema**: Si el bucket no existe en Storage:
1. El PUT al signed URL puede fallar con 404 o 403
2. La verificación LIST fallará con 404
3. El código retornará error en el paso de verificación

**Solución**: El bucket debe existir previamente en Supabase Storage. El edge function `issue-fortune-upload-ticket` debe validar que el bucket existe antes de generar el signed URL.

### Dispositivo Sin Espacio

**Problema**: Si el dispositivo se queda sin espacio durante el upload:
- **Durante carga de imagen**: `fetch(webPath)` puede fallar si no hay espacio para cache temporal
- **Durante PUT**: El upload puede fallar con error de red o timeout
- **En Storage**: Supabase puede rechazar el upload si el plan está lleno

**El código NO detecta específicamente** "sin espacio". Simplemente falla con error genérico. Los logs mostrarán el error, pero puede ser difícil distinguir "sin espacio" de otros errores de red.

**Mejora sugerida**: Verificar espacio disponible antes del upload usando Capacitor Filesystem plugin.

### MIME Type Detectado vs blob.type

**Comportamiento**: El código usa `detectedMimeType` (de bytes) para el upload, NO `blob.type`. Flujo:

1. Obtiene `mimeType` de `blob.type` - usado para el ticket
2. Detecta `detectedMimeType` desde bytes - usado para el PUT
3. Usa `detectedMimeType` en el header `Content-Type` del PUT

**Por qué**: Los bytes son más confiables que `blob.type`, que puede ser incorrecto o faltar. Si hay discrepancia, el código confía en la detección desde bytes.

**Potencial problema**: Si el edge function genera un signed URL esperando un MIME type específico (del ticket), pero el PUT usa otro MIME type (detectado), puede haber conflicto. Sin embargo, Storage típicamente acepta cualquier MIME type en el PUT.

---

## Inyección de JavaScript

### Cuándo se Inyecta

1. **Al iniciar la app**: `AppDelegate.application(_:didFinishLaunchingWithOptions:)` espera 0.5s y llama a `injectUploaderBridge()`
2. **Si el WebView no está listo**: Reintenta cada 0.5s hasta que esté disponible
3. **Solo una vez**: `uploaderInjected` flag previene múltiples inyecciones

### Cómo Funciona la Inyección

```swift
func injectJavaScript() {
    let bootstrapJS = """
    (function(){
      // TODO EL CÓDIGO JAVASCRIPT
    })();
    """
    
    DispatchQueue.main.async { [weak self] in
        guard let self = self,
              let webView = self.bridgeViewController?.webView else {
            return
        }
        
        webView.evaluateJavaScript(bootstrapJS) { result, error in
            if let error = error {
                print("Failed to inject JavaScript: \(error.localizedDescription)")
            } else {
                print("JavaScript injected successfully")
                // Verifica que se instaló correctamente
                self.verifyInjection()
            }
        }
    }
}
```

### Protección contra Sobrescritura

El código verifica si ya existe una implementación versionada:

```javascript
// En el JavaScript inyectado
if (window.NativeUploader && window.NativeUploader.__impl) {
  console.log("existing implementation detected, skipping install");
  return; // NO sobrescribe
}
```

Esto permite que el código web defina su propia implementación si es necesario.

**Limitación**: El código verifica `__impl` antes de inyectar, pero NO previene sobrescritura posterior. Si el código web redefine `window.NativeUploader` después de la inyección, puede perder la función `pickAndUploadFortunePhoto`.

**Mejora sugerida**: Usar `Object.defineProperty` con `writable: false` para prevenir sobrescritura.

---

## Comunicación Web ↔ Native

### Web → Native

**NO HAY comunicación directa Web → Native**. Todo se hace vía JavaScript inyectado que corre en el WebView.

### Native → Web

**Evento de Disponibilidad**:

```javascript
// Despachado automáticamente después de la inyección
window.dispatchEvent(new CustomEvent('native-uploader:availability', {
  detail: { available: true }
}));
```

**Escucha en tu código web**:

```javascript
window.addEventListener('native-uploader:availability', (event) => {
  if (event.detail.available) {
    console.log('Native uploader está disponible');
  }
});
```

### Variables Globales Expuestas

El JavaScript inyectado crea/modifica estas variables globales:

```javascript
window.NativeUploaderAvailable = true;
window.NativeUploader = {
  __impl: "ios-injected-v3-2026-01-18",
  pickAndUploadFortunePhoto: function(options) { ... }
};
window.__nativeUploadResolvers = {};  // Interno
window.__nativeUploadReqId = 0;       // Interno
window.__nativeUploadActive = false;  // Guard contra duplicados
window.__nativeLogToXcode = function(message) { ... };  // Helper de logging
```

---

## Edge Functions - Contratos de API

### 1. `issue-fortune-upload-ticket`

**Endpoint**: `POST /functions/v1/issue-fortune-upload-ticket`

**Request Headers**:
```
Content-Type: application/json
Authorization: Bearer <access_token>
apikey: <anon_key>
```

**Request Body**:
```json
{
  "fortune_id": "uuid-del-fortune",
  "mime": "image/jpeg"
}
```

**Response (200 OK)**:
```json
{
  "url": "https://storage.supabase.co/object/signed-url-here?token=...",
  "bucketRelativePath": "userId/filename.jpg",
  "bucket": "photos",
  "requiredHeaders": {
    "x-upsert": "true"
  }
}
```

**Campos Requeridos**:
- `url`: URL firmada para hacer PUT del archivo
- `bucketRelativePath`: Ruta relativa al bucket (sin prefijo "photos/")

**Campos Opcionales**:
- `bucket`: Nombre del bucket (default: "photos")
- `requiredHeaders`: Objeto con headers adicionales (se convierte a strings)

**Errores**:
- `400`: Request inválido
- `401`: No autenticado
- `500`: Error del servidor

**Cómo modificar en el Edge Function**:

```typescript
// En tu edge function
export async function handler(req: Request) {
  const { fortune_id, mime } = await req.json();
  
  // Genera signed URL para PUT
  const { data, error } = await supabase.storage
    .from('photos')
    .createSignedUploadUrl(bucketRelativePath, {
      upsert: true
    });
  
  return new Response(JSON.stringify({
    url: data.signedUrl,  // DEBE ser "url"
    bucketRelativePath: bucketRelativePath,  // DEBE ser "bucketRelativePath"
    bucket: 'photos',
    requiredHeaders: {
      'x-upsert': 'true'  // Opcional, pero recomendado
    }
  }), {
    headers: { 'Content-Type': 'application/json' }
  });
}
```

---

### 2. `finalize-fortune-photo`

**Endpoint**: `POST /functions/v1/finalize-fortune-photo`

**Request Headers**:
```
Content-Type: application/json
Authorization: Bearer <access_token>
apikey: <anon_key>
```

**Request Body**:
```json
{
  "fortune_id": "uuid-del-fortune",
  "bucket": "photos",
  "path": "userId/filename.jpg",
  "mime": "image/jpeg",
  "width": 1920,
  "height": 1080,
  "size_bytes": 1234567
}
```

**Nota**: `path` es **bucket-relative**, NO incluye el prefijo "photos/".

**Response (200 OK)**:
```json
{
  "signedUrl": "https://storage.supabase.co/object/public/photos/userId/filename.jpg",
  "replaced": false
}
```

**Retry Logic**:
- El cliente reintenta hasta 3 veces
- Backoff exponencial: 1s, 2s
- Solo reintenta si status NO es 200/201

**Cómo modificar en el Edge Function**:

```typescript
export async function handler(req: Request) {
  const { fortune_id, bucket, path, mime, width, height, size_bytes } = await req.json();
  
  // path es bucket-relative: "userId/filename.jpg"
  // NO incluye "photos/" prefix
  
  // Actualiza la base de datos
  const { data, error } = await supabase
    .from('fortunes')
    .update({
      photo_path: path,
      photo_mime: mime,
      photo_width: width,
      photo_height: height,
      photo_size_bytes: size_bytes
    })
    .eq('id', fortune_id);
  
  // Genera signed URL pública
  const { data: urlData } = await supabase.storage
    .from(bucket)
    .createSignedUrl(path, 3600);
  
  return new Response(JSON.stringify({
    signedUrl: urlData.signedUrl,
    replaced: false  // o true si reemplazó una foto existente
  }), {
    headers: { 'Content-Type': 'application/json' }
  });
}
```

---

## Debugging y Logging

### Cómo Leer los Logs de iOS

Los logs de iOS aparecen en la consola de Xcode. Hay dos tipos de logs:

1. **Logs nativos de Swift**: Aparecen directamente sin prefijo
2. **Logs de JavaScript**: Aparecen con el prefijo `⚡️  [log]`

**Ubicación de los logs**:
- Abre Xcode
- Ve a `View > Debug Area > Activate Console` (o presiona `Cmd+Shift+Y`)
- Los logs aparecen en tiempo real mientras la app corre

### Logs Clave para Debugging

#### 1. Inyección de JavaScript

**Éxito esperado**:
```
NativeUploaderBridge: JavaScript bridge injected
⚡️  [log] - [NATIVE-UPLOADER][INJECTED] installed ios-injected-v3-2026-01-18
```

**Error común**:
```
NativeUploaderBridge: Failed to inject JavaScript: A JavaScript exception occurred
```
**Diagnóstico**: El JavaScript tiene un error de sintaxis o el WebView no está listo. Revisa la consola para más detalles del error.

#### 2. Llamada a la Función

**Éxito esperado**:
```
⚡️  [log] - [NATIVE-UPLOADER][INJECTED] FUNCTION CALLED - pickAndUploadFortunePhoto entry point
[NATIVE-UPLOADER] iOS handler hit (main), reqId=1
```

**Si no aparece**: El código web no está llamando correctamente a `window.NativeUploader.pickAndUploadFortunePhoto()`.

#### 3. Ticket de Upload

**Éxito esperado**:
```
[NATIVE-UPLOADER] ticket: POST https://...supabase.co/functions/v1/issue-fortune-upload-ticket
[NATIVE-UPLOADER] ticket: status=200
```

**Error común**:
```
[NATIVE-UPLOADER] ticket: status=401
```
**Diagnóstico**: Token de acceso inválido o expirado. Verifica que `window.__SUPABASE_ACCESS_TOKEN__` esté definido y sea válido.

#### 4. Upload a Storage

**⚠️ CRÍTICO: Verificar el Método HTTP**

**PUT (correcto para signed URLs con token)**:
```
[NATIVE-UPLOADER] upload PUT: https://...supabase.co/storage/v1/object/upload/sign/...
[NativeUploader] UPLOAD_START method=PUT path=userId/file.jpg mime=image/jpeg
[NATIVE-UPLOADER] upload: status=200
UPLOAD_OK status=200 method=PUT
```

**POST (incorrecto para signed URLs con token)**:
```
[NATIVE-UPLOADER] upload POST: https://...supabase.co/storage/v1/object/upload/sign/...
[NativeUploader] UPLOAD_START method=POST path=userId/file.jpg
[NATIVE-UPLOADER] upload: status=200
```
**⚠️ PROBLEMA**: Si ves `upload POST:` o `method=POST`, el código NO está respetando `uploadMethod: 'PUT'` del ticket. El upload puede retornar 200 pero el archivo no persistirá.

**Cómo verificar qué método se está usando**:
1. Busca en los logs: `[NATIVE-UPLOADER] upload PUT:` o `[NATIVE-UPLOADER] upload POST:`
2. Busca: `UPLOAD_START method=PUT` o `UPLOAD_START method=POST`
3. Busca: `UPLOAD_OK status=200 method=PUT` o `method=POST`

**Si ves POST cuando debería ser PUT**:
- El edge function debe retornar `uploadMethod: 'PUT'` en el ticket
- El código JavaScript debe leer `uploadMethod` del ticket
- El código debe usar PUT cuando `uploadMethod === 'PUT'`

**Errores comunes del upload**:
```
[NATIVE-UPLOADER] upload: status=403
```
**Diagnóstico**: Signed URL expirado o token inválido. El edge function debe generar URLs con TTL suficiente (5-10 minutos).

```
[NATIVE-UPLOADER] upload: status=400
```
**Diagnóstico**: Request malformado. Verifica que los headers sean correctos y el body sea raw bytes (no FormData) cuando uses PUT.

#### 5. Verificación de Upload

**Éxito esperado**:
```
[NativeUploader] Verifying upload in storage...
VERIFY_OK matches=1
```

**Error común**:
```
VERIFY_FAIL matches=0
```
**Diagnóstico**: El archivo no se encuentra en storage después del upload. Esto puede pasar si:
- Se usó POST en lugar de PUT con signed URLs que requieren PUT
- El archivo se subió a una ruta diferente
- Hay un delay en Storage (raro pero posible)

#### 6. Finalización

**Éxito esperado**:
```
[NATIVE-UPLOADER] finalize: POST https://...supabase.co/functions/v1/finalize-fortune-photo
[NATIVE-UPLOADER] finalize: status=200
[NATIVE-UPLOADER] finalize: body={"signedUrl":"https://...","replaced":false}
```

**Error crítico - UPLOAD_NOT_PERSISTED**:
```
[NATIVE-UPLOADER] finalize: status=500
[NATIVE-UPLOADER] finalize: body={"error":"UPLOAD_NOT_PERSISTED","message":"The uploaded file was not found in storage. Upload may have failed or used incorrect method."}
```
**⚠️ DIAGNÓSTICO CRÍTICO**: Este error significa que:
1. El upload retornó 200 pero el archivo NO se guardó en Storage
2. **Causa más común**: Se usó POST multipart cuando el signed URL requiere PUT con raw bytes
3. **Solución**: Verifica que el código use PUT cuando `uploadMethod === 'PUT'`

**Cómo diagnosticar UPLOAD_NOT_PERSISTED**:
1. Revisa los logs anteriores al finalize
2. Busca `[NATIVE-UPLOADER] upload POST:` o `upload PUT:`
3. Si ves POST pero el ticket tiene `uploadMethod: 'PUT'`, el código no está respetando el método
4. Verifica que el ticket response incluya `uploadMethod: 'PUT'`

**Otros errores de finalize**:
```
[NATIVE-UPLOADER] finalize: status=401
```
**Diagnóstico**: Token de acceso inválido o expirado.

```
[NATIVE-UPLOADER] finalize: status=404
```
**Diagnóstico**: El `path` enviado a finalize no coincide con el `bucketRelativePath` del ticket, o el archivo realmente no existe.

### Flujo de Logs Esperado (Éxito Completo)

```
1. NativeUploaderBridge: JavaScript bridge injected
2. ⚡️  [log] - [NATIVE-UPLOADER][INJECTED] installed ios-injected-v3-2026-01-18
3. [NATIVE-UPLOADER] iOS handler hit (main), reqId=1
4. [NATIVE-UPLOADER] ticket: POST https://.../issue-fortune-upload-ticket
5. [NATIVE-UPLOADER] ticket: status=200
6. [NATIVE-UPLOADER] upload PUT: https://.../storage/v1/object/upload/sign/...
7. [NativeUploader] UPLOAD_START method=PUT path=userId/file.jpg mime=image/jpeg
8. [NATIVE-UPLOADER] upload: status=200
9. UPLOAD_OK status=200 method=PUT
10. [NativeUploader] Verifying upload in storage...
11. VERIFY_OK matches=1
12. [NATIVE-UPLOADER] finalize: POST https://.../finalize-fortune-photo
13. [NATIVE-UPLOADER] finalize: status=200
14. [NATIVE-UPLOADER] finalize: body={"signedUrl":"https://...","replaced":false}
```

### Identificar Qué Código Está Ejecutándose

**⚠️ IMPORTANTE**: Puede haber DOS implementaciones diferentes:

1. **JavaScript Inyectado (NativeUploaderBridge.swift)**: 
   - Logs empiezan con `[NATIVE-UPLOADER][INJECTED]` o `[NativeUploader]`
   - Usa `Capacitor.Plugins.Camera.getPhoto()`
   - Ejecuta todo el flujo en JavaScript dentro del WebView

2. **Código Web de Lovable**:
   - Logs pueden empezar con `[NATIVE-UPLOADER]` pero sin `[INJECTED]`
   - Puede tener su propia implementación que sobrescribe `window.NativeUploader`
   - Puede hacer el upload directamente sin usar el código inyectado

**Cómo identificar qué código se ejecuta**:

**Si ves estos logs, está usando el código INYECTADO**:
```
[NATIVE-UPLOADER][INJECTED] FUNCTION CALLED - pickAndUploadFortunePhoto entry point
[NativeUploader] Opening photo picker...
[NativeUploader] PICKER_OK w=2048 h=1152 bytes=358336
[NativeUploader] UPLOAD_START method=PUT path=...
```

**Si ves estos logs, está usando código de LOVABLE**:
```
[NATIVE-UPLOADER] iOS handler hit (main), reqId=1
[NATIVE-UPLOADER] processAndUpload: fortuneId=...
[NATIVE-UPLOADER] image prepared: 2048x1152 bytes=358336
[NATIVE-UPLOADER] ticket: POST https://...
[NATIVE-UPLOADER] upload POST: https://...
```

**Si Lovable tiene su propia implementación**:
- El código web puede haber definido `window.NativeUploader.pickAndUploadFortunePhoto` antes de que se inyecte el código
- El código inyectado NO sobrescribe si detecta `window.NativeUploader.__impl` existente
- Lovable debe usar el código inyectado O implementar correctamente PUT cuando `uploadMethod === 'PUT'`

**Solución si Lovable tiene código propio**:
1. Verificar que el código de Lovable respete `uploadMethod: 'PUT'` del ticket
2. Si usa POST multipart cuando el ticket dice PUT, cambiar a PUT con raw bytes
3. O eliminar el código de Lovable y usar solo el código inyectado

### Checklist de Diagnóstico para Lovable

Cuando el upload falla, revisa estos puntos en orden:

#### ✅ Paso 1: Verificar Inyección
- [ ] ¿Aparece `NativeUploaderBridge: JavaScript bridge injected`?
- [ ] ¿Aparece `[NATIVE-UPLOADER][INJECTED] installed`?
- [ ] Si NO: El JavaScript no se inyectó. Revisa errores de sintaxis.

#### ✅ Paso 2: Verificar Llamada
- [ ] ¿Aparece `[NATIVE-UPLOADER] iOS handler hit`?
- [ ] ¿Aparece `FUNCTION CALLED - pickAndUploadFortunePhoto`?
- [ ] Si NO: El código web no está llamando la función correctamente.

#### ✅ Paso 3: Verificar Ticket
- [ ] ¿El ticket retorna `status=200`?
- [ ] ¿El ticket incluye `uploadMethod: 'PUT'`?
- [ ] ¿El ticket incluye `url` y `bucketRelativePath`?
- [ ] Si NO: El edge function `issue-fortune-upload-ticket` tiene problemas.

#### ✅ Paso 4: Verificar Método de Upload (CRÍTICO)
- [ ] ¿Los logs muestran `upload PUT:` o `upload POST:`?
- [ ] ¿Los logs muestran `UPLOAD_START method=PUT` o `method=POST`?
- [ ] **Si ves POST pero el ticket tiene `uploadMethod: 'PUT'`**: El código JavaScript NO está respetando `uploadMethod`
- [ ] **Solución**: Verifica que el código en `NativeUploaderBridge.swift` líneas ~659-735 use `uploadMethod` para decidir PUT vs POST

#### ✅ Paso 5: Verificar Upload
- [ ] ¿El upload retorna `status=200`?
- [ ] ¿Los logs muestran `UPLOAD_OK`?
- [ ] Si NO: Revisa el error específico (403 = URL expirada, 400 = request malformado)

#### ✅ Paso 6: Verificar Verificación
- [ ] ¿Los logs muestran `VERIFY_OK matches=1`?
- [ ] Si NO: El archivo no se encuentra en storage. Esto puede indicar que se usó POST en lugar de PUT.

#### ✅ Paso 7: Verificar Finalize
- [ ] ¿El finalize retorna `status=200`?
- [ ] ¿El body incluye `signedUrl`?
- [ ] Si retorna `500` con `UPLOAD_NOT_PERSISTED`: El archivo no se encuentra. **Causa más común**: Se usó POST cuando debería ser PUT.

### Ejemplo de Logs con Problema (UPLOAD_NOT_PERSISTED)

**Logs reales de un caso fallido**:

```
[NATIVE-UPLOADER] iOS handler hit (main), reqId=1
[NATIVE-UPLOADER] processAndUpload: fortuneId=78b21208-67cc-4d6c-b5a5-70053da3a7b6
[NATIVE-UPLOADER] image prepared: 2048x1152 bytes=358336
[NATIVE-UPLOADER] ticket: POST https://.../issue-fortune-upload-ticket
[NATIVE-UPLOADER] ticket: status=200  ← ✅ Ticket OK
[NATIVE-UPLOADER] upload POST: https://.../storage/v1/object/upload/sign/...  ← ⚠️ PROBLEMA: Dice POST
[NATIVE-UPLOADER] upload: status=200  ← Parece exitoso pero...
[NATIVE-UPLOADER] upload: body={"url":"/object/upload/sign/..."}  ← Retorna URL relativa
[NATIVE-UPLOADER] finalize: POST https://.../finalize-fortune-photo
[NATIVE-UPLOADER] finalize: status=500  ← ❌ FALLO
[NATIVE-UPLOADER] finalize: body={"error":"UPLOAD_NOT_PERSISTED","message":"The uploaded file was not found in storage. Upload may have failed or used incorrect method."}
[NATIVE-UPLOADER] finalize: retrying in 48.00s (left=2)  ← ⚠️ Retry con tiempo incorrecto
```

**Análisis de los logs**:

1. **`[NATIVE-UPLOADER] iOS handler hit`**: Indica que está usando código de Lovable, NO el código inyectado
2. **`upload POST:`**: ⚠️ **PROBLEMA CRÍTICO** - Está usando POST cuando debería usar PUT
3. **`upload: status=200`**: El HTTP retorna éxito, pero Storage no persiste el archivo
4. **`finalize: status=500` con `UPLOAD_NOT_PERSISTED`**: Confirma que el archivo no existe
5. **`retrying in 48.00s`**: ⚠️ El retry tiene tiempos incorrectos (debería ser 1s, 2s, no 48s, 96s)

**Diagnóstico**:
- El código de Lovable está haciendo el upload directamente
- Está usando POST multipart cuando el signed URL requiere PUT con raw bytes
- El código de Lovable NO está respetando `uploadMethod: 'PUT'` del ticket

**Solución para Lovable**:

1. **Verificar el ticket response incluye `uploadMethod`**:
   ```javascript
   const ticketData = await ticket.json();
   console.log('Ticket uploadMethod:', ticketData.uploadMethod);  // Debe ser 'PUT'
   ```

2. **Modificar el código de upload en Lovable para usar PUT cuando corresponda**:
   ```javascript
   const uploadMethod = ticketData.uploadMethod || 'POST_MULTIPART';
   
   if (uploadMethod === 'PUT') {
     // PUT con raw bytes
     const response = await fetch(ticketData.url, {
       method: 'PUT',
       headers: {
         'Content-Type': mimeType  // Detectado desde los bytes de la imagen
       },
       body: imageBytes  // Uint8Array, NO FormData
     });
   } else {
     // POST multipart (solo para compatibilidad legacy)
     const formData = new FormData();
     formData.append('file', imageBlob);
     const response = await fetch(ticketData.url, {
       method: 'POST',
       body: formData
     });
   }
   ```

3. **Añadir logging para verificar**:
   ```javascript
   console.log('[NATIVE-UPLOADER] upload ' + uploadMethod + ':', ticketData.url.substring(0, 100));
   console.log('[NATIVE-UPLOADER] UPLOAD_START method=' + uploadMethod + ' path=' + ticketData.bucketRelativePath);
   ```

**Logs esperados después del fix**:

```
[NATIVE-UPLOADER] ticket: status=200
[NATIVE-UPLOADER] upload PUT: https://.../storage/v1/object/upload/sign/...  ← ✅ Debe decir PUT
[NATIVE-UPLOADER] UPLOAD_START method=PUT path=userId/file.jpg mime=image/jpeg  ← ✅ Método correcto
[NATIVE-UPLOADER] upload: status=200
[NATIVE-UPLOADER] finalize: status=200  ← ✅ Debe ser 200, no 500
[NATIVE-UPLOADER] finalize: body={"signedUrl":"https://...","replaced":false}  ← ✅ Éxito
```

### Problema: Retry Times Incorrectos

**Síntoma**:
```
[NATIVE-UPLOADER] finalize: retrying in 48.00s (left=2)
[NATIVE-UPLOADER] finalize: retrying in 96.00s (left=1)
```

**Problema**: Los tiempos de retry son incorrectos. Deberían ser:
- Primer retry: 1 segundo
- Segundo retry: 2 segundos

**Causa**: El código de retry está usando una fórmula incorrecta o hay un bug en el cálculo del tiempo de espera.

**Solución**: Verificar el código de retry en Lovable y corregir la fórmula:
```javascript
// ✅ CORRECTO
var waitTime = 1000 * (retryAttempt + 1);  // 1s, 2s, 3s

// ❌ INCORRECTO (ejemplo de lo que podría estar mal)
var waitTime = 1000 * Math.pow(2, retryAttempt) * (retryAttempt + 1);  // Genera tiempos muy largos
```

### Helper de Logging

```javascript
window.__nativeLogToXcode = function(message) {
  console.log('[NATIVE-LOG] ' + message);
  // También envía a servidor de debug (opcional)
};
```

**Servidor de Debug**: El código envía logs a `http://127.0.0.1:7243` durante desarrollo. Este servidor NO es necesario para producción y se puede eliminar o hacer condicional.

**Uso en el código**:

```javascript
if (typeof window.__nativeLogToXcode === 'function') {
  window.__nativeLogToXcode('TICKET_PARSED keys: ' + ticketKeys.join(', '));
}
```

### Debugging en el Código Web

**Verifica que el uploader está disponible**:

```javascript
if (window.NativeUploader && window.NativeUploader.pickAndUploadFortunePhoto) {
  console.log('Native uploader disponible');
  console.log('Versión:', window.NativeUploader.__impl);
} else {
  console.error('Native uploader NO disponible');
}
```

**Escucha eventos**:

```javascript
window.addEventListener('native-uploader:availability', (event) => {
  console.log('Native uploader disponible:', event.detail.available);
});
```

---

## Cómo Modificar el Código

### Cambiar la Lógica de Upload

**Ubicación**: `NativeUploaderBridge.swift`, dentro del string `bootstrapJS` (línea ~21)

**Ejemplo: Cambiar el método de upload de PUT a POST multipart**:

1. Busca la sección de upload (línea ~659)
2. Cambia `method: 'PUT'` a `method: 'POST'`
3. Cambia `body: imageBytes` a usar `FormData`:

```javascript
// ANTES (PUT)
var uploadResponse = await fetch(uploadUrl, {
  method: 'PUT',
  headers: uploadHeaders,
  body: imageBytes
});

// DESPUÉS (POST multipart)
var formData = new FormData();
formData.append('file', imageBlob, 'photo.jpg');
var uploadResponse = await fetch(uploadUrl, {
  method: 'POST',
  headers: uploadHeaders,  // NO incluir Content-Type, fetch lo añade con boundary
  body: formData
});
```

### Añadir Retry al Upload

**Ubicación**: Líneas 702-735

```javascript
// Envuelve el fetch en un loop con retry
var maxUploadRetries = 3;
var uploadSuccess = false;

for (var retryAttempt = 0; retryAttempt < maxUploadRetries; retryAttempt++) {
  try {
    var uploadResponse = await fetch(uploadUrl, {
      method: 'PUT',
      headers: uploadHeaders,
      body: imageBytes
    });
    
    if (uploadResponse.status === 200 || uploadResponse.status === 201 || uploadResponse.status === 204) {
      uploadSuccess = true;
      break;
    }
  } catch (e) {
    if (retryAttempt === maxUploadRetries - 1) {
      throw e;
    }
    await new Promise(resolve => setTimeout(resolve, 1000 * (retryAttempt + 1)));
  }
}
```

### Añadir Cancelación de Upload

**Ubicación**: Líneas 702-735

```javascript
// Crea AbortController antes del upload
var uploadController = new AbortController();

var uploadResponse = await fetch(uploadUrl, {
  method: 'PUT',
  headers: uploadHeaders,
  body: imageBytes,
  signal: uploadController.signal  // Permite cancelar
});

// Para cancelar desde el código web:
// uploadController.abort();
```

### Añadir Timeout a Requests

**Ubicación**: Cualquier `fetch()` call

```javascript
// Usa AbortController con timeout
var controller = new AbortController();
var timeoutId = setTimeout(() => controller.abort(), 30000); // 30s

var response = await fetch(url, {
  method: 'PUT',
  body: imageBytes,
  signal: controller.signal
});

clearTimeout(timeoutId);
```

### Cambiar los Headers del Upload

**Ubicación**: Líneas 686-698

```javascript
// Modifica cómo se construyen los headers
var uploadHeaders = {
  'Content-Type': detectedMimeType,
  'x-custom-header': 'custom-value'  // Añade headers personalizados
};
```

### Cambiar el Formato del Ticket Response

**Ubicación**: Líneas 377-383 (extracción de campos del ticket)

Si tu edge function retorna campos diferentes:

```javascript
// Añade soporte para nuevos campos
var uploadUrl = ticketData.url 
  || ticketData.uploadUrl 
  || ticketData.newFieldName  // ← Añade aquí
  || null;
```

### Cambiar la Lógica de Retry

**Ubicación**: Líneas 816-900 (finalize con retry)

```javascript
// Cambia número de reintentos
var maxFinalizeRetries = 5;  // Era 3

// Cambia backoff
var waitTime = 2000 * (retryAttempt + 1);  // Era 1000
```

### Cambiar Cómo se Obtienen las Credenciales

**Ubicación**: Líneas 190-226

```javascript
// Añade nuevas fuentes de credenciales
if (window.myCustomAuth && window.myCustomAuth.token) {
  supabaseToken = window.myCustomAuth.token;
}
```

### Cambiar el Flujo de Verificación

**Ubicación**: Líneas 737-799

Si quieres cambiar cómo se verifica el upload:

```javascript
// En lugar de LIST, podrías usar HEAD
var headResponse = await fetch(
  supabaseUrl + '/storage/v1/object/' + bucket + '/' + bucketRelativePath,
  { method: 'HEAD', headers: listHeaders }
);

if (headResponse.status === 200) {
  // Archivo existe
} else {
  // Archivo no existe
}
```

---

## Troubleshooting

### Resumen Ejecutivo para Lovable

**Problema más común**: `UPLOAD_NOT_PERSISTED` - El upload retorna 200 pero el archivo no se guarda.

**Causa raíz**: Se está usando **POST multipart** cuando el signed URL requiere **PUT con raw bytes**.

**Cómo identificar**:
1. Busca en los logs: `[NATIVE-UPLOADER] upload POST:` ← ⚠️ Incorrecto
2. Debe decir: `[NATIVE-UPLOADER] upload PUT:` ← ✅ Correcto
3. Busca: `UPLOAD_START method=POST` ← ⚠️ Incorrecto
4. Debe decir: `UPLOAD_START method=PUT` ← ✅ Correcto

**Solución rápida**:
1. Verifica que el ticket incluya `uploadMethod: 'PUT'`
2. Modifica el código de upload para usar PUT cuando `uploadMethod === 'PUT'`
3. Envía raw bytes (`Uint8Array`) en el body, NO `FormData`
4. Añade header `Content-Type` con el MIME type detectado

**Ver sección completa**: [Problema: UPLOAD_NOT_PERSISTED](#problema-upload_not_persisted)

---

### Problema: "Native uploader NO disponible"

**Causas posibles**:
1. El JavaScript no se inyectó correctamente
2. El WebView no está listo cuando se intenta usar

**Solución**:
```javascript
// Espera a que esté disponible
function waitForNativeUploader() {
  return new Promise((resolve) => {
    if (window.NativeUploader && window.NativeUploader.pickAndUploadFortunePhoto) {
      resolve();
    } else {
      window.addEventListener('native-uploader:availability', resolve, { once: true });
    }
  });
}

await waitForNativeUploader();
const result = await window.NativeUploader.pickAndUploadFortunePhoto({ fortuneId: '...' });
```

---

### Problema: "Missing fortuneId"

**Causa**: No se pasó `fortuneId` en las opciones

**Solución**:
```javascript
const result = await window.NativeUploader.pickAndUploadFortunePhoto({
  fortuneId: 'tu-fortune-id-aqui'  // ← REQUERIDO
});
```

---

### Problema: "Failed to issue upload ticket"

**Causas posibles**:
1. Token de acceso inválido/expirado
2. Edge function retorna error
3. Network error

**Debugging**:
- Revisa los logs en Xcode: `TICKET_RESPONSE_RECEIVED status=...`
- Verifica que `window.__SUPABASE_ACCESS_TOKEN__` esté definido
- Verifica que el edge function esté desplegado y funcionando

**Solución**:
```javascript
// Asegúrate de exponer el token
window.__SUPABASE_ACCESS_TOKEN__ = session.access_token;

// O usa el cliente Supabase (se detecta automáticamente)
```

---

### Problema: "Invalid upload ticket response: url is missing"

**Causa**: El edge function no retorna `url` o `bucketRelativePath`

**Solución en Edge Function**:
```typescript
// Asegúrate de retornar estos campos exactos:
return {
  url: signedUrl,  // ← DEBE ser "url"
  bucketRelativePath: path,  // ← DEBE ser "bucketRelativePath"
  bucket: 'photos'
};
```

---

### Problema: "Upload verification failed: file not found"

**Causas posibles**:
1. El PUT no se completó correctamente
2. El archivo se subió a una ruta diferente
3. Hay un delay en Storage (raro pero posible)

**Solución**:
- Revisa los logs: `UPLOAD_OK status=200`
- Verifica que `bucketRelativePath` sea correcto
- Considera añadir un pequeño delay antes de verificar

---

### Problema: "Failed to finalize photo after 3 attempts"

**Causas posibles**:
1. Edge function está fallando
2. El `path` en finalize no coincide con el upload
3. Problemas de permisos en la base de datos

**Debugging**:
- Revisa los logs: `FINALIZE_FAIL status=...`
- Verifica el payload que se envía a finalize
- Revisa los logs del edge function

**Solución**:
- Asegúrate de que `path` en finalize sea exactamente igual a `bucketRelativePath` del ticket
- Verifica permisos RLS en Supabase
- Revisa que el edge function maneje errores correctamente

---

### Problema: El upload funciona pero finalize falla

**Causa común**: El `path` enviado a finalize incluye el prefijo del bucket

**Solución**:
```javascript
// ❌ INCORRECTO
path: 'photos/userId/file.jpg'

// ✅ CORRECTO
path: 'userId/file.jpg'  // bucket-relative
```

---

<a id="problema-upload_not_persisted"></a>
### Problema: `UPLOAD_NOT_PERSISTED` - El archivo no se encuentra después del upload

**Síntoma**:
```
[NATIVE-UPLOADER] upload: status=200
UPLOAD_OK status=200 method=POST  ← ⚠️ Nota: method=POST
[NATIVE-UPLOADER] finalize: status=500
[NATIVE-UPLOADER] finalize: body={"error":"UPLOAD_NOT_PERSISTED","message":"The uploaded file was not found in storage. Upload may have failed or used incorrect method."}
```

**Diagnóstico**:

Este error significa que:
1. El upload HTTP retornó `200 OK` (parece exitoso)
2. PERO el archivo NO se guardó en Storage
3. Cuando finalize intenta verificar el archivo, no lo encuentra

**Causa más común**: **Se usó POST multipart cuando el signed URL requiere PUT con raw bytes**

**Cómo verificar**:

1. **Revisa los logs del upload**:
   ```
   [NATIVE-UPLOADER] upload POST: https://...  ← ⚠️ Si dice POST, es el problema
   [NATIVE-UPLOADER] upload PUT: https://...   ← ✅ Debe decir PUT
   ```

2. **Revisa el método usado**:
   ```
   UPLOAD_START method=POST  ← ⚠️ Incorrecto para signed URLs con token
   UPLOAD_START method=PUT   ← ✅ Correcto
   ```

3. **Revisa el ticket response**:
   - El edge function debe retornar `uploadMethod: 'PUT'`
   - El código debe leer este valor y usarlo

**Solución según el código que se ejecuta**:

#### Si usa código INYECTADO (NativeUploaderBridge.swift):

1. Verifica que el ticket incluya `uploadMethod: 'PUT'`:
   ```json
   {
     "url": "https://...",
     "bucketRelativePath": "userId/file.jpg",
     "uploadMethod": "PUT"  ← DEBE estar presente
   }
   ```

2. Verifica que el código respete `uploadMethod`:
   - Busca en `NativeUploaderBridge.swift` líneas ~659-735
   - Debe haber lógica que verifica `if (normalizedUploadMethod === 'PUT')`
   - Si falta esta lógica, añádela (ver sección "Cómo Modificar el Código")

3. Verifica los logs muestran PUT:
   ```
   [NATIVE-UPLOADER] upload PUT: https://...
   [NativeUploader] UPLOAD_START method=PUT path=... mime=image/jpeg
   ```

#### Si usa código de LOVABLE:

1. El código web de Lovable debe:
   - Leer `uploadMethod` del ticket response
   - Usar PUT cuando `uploadMethod === 'PUT'`
   - Enviar raw bytes (`Uint8Array`) en el body, NO `FormData`

2. Ejemplo de código correcto en Lovable:
   ```javascript
   const ticket = await fetch('/functions/v1/issue-fortune-upload-ticket', {...});
   const ticketData = await ticket.json();
   
   const uploadMethod = ticketData.uploadMethod || 'POST_MULTIPART';
   
   if (uploadMethod === 'PUT') {
     // PUT con raw bytes
     await fetch(ticketData.url, {
       method: 'PUT',
       headers: {
         'Content-Type': mimeType  // image/jpeg, image/png, etc.
       },
       body: imageBytes  // Uint8Array, NO FormData
     });
   } else {
     // POST multipart (legacy)
     const formData = new FormData();
     formData.append('file', imageBlob);
     await fetch(ticketData.url, {
       method: 'POST',
       body: formData
     });
   }
   ```

**Verificación después del fix**:

Los logs deben mostrar:
```
[NATIVE-UPLOADER] upload PUT: https://...
[NativeUploader] UPLOAD_START method=PUT path=userId/file.jpg mime=image/jpeg
[NATIVE-UPLOADER] upload: status=200
UPLOAD_OK status=200 method=PUT  ← ✅ Debe decir PUT
[NATIVE-UPLOADER] finalize: status=200  ← ✅ Debe ser 200, no 500
```

**Por qué POST falla con signed URLs que requieren PUT**:

- Los signed URLs de Supabase Storage con token requieren PUT con raw bytes
- POST multipart envía datos en formato diferente que Storage no puede procesar correctamente
- Storage retorna 200 pero no persiste el archivo porque el formato es incorrecto
- Finalize falla porque el archivo nunca se guardó realmente

---

## Preguntas Frecuentes

### ¿Qué pasa si el usuario cancela el selector de fotos?

El código maneja la cancelación en múltiples puntos. Cuando `Capacitor.Plugins.Camera.getPhoto()` se cancela, retorna `null` o `undefined`. El código verifica esto explícitamente y retorna `{ cancelled: true }`. También verifica si falta `webPath` o `path`, y si el error contiene "cancel" o "cancelled". **Importante**: Solo se considera cancelación si es explícita; otros errores se tratan como fallos.

### ¿Hay un límite de tamaño de archivo?

No hay límite explícito en el código JavaScript. Sin embargo, hay límites prácticos:
- **Memoria del dispositivo**: Las imágenes se cargan completamente en memoria
- **Timeout de red**: Las requests HTTP pueden timeout si son muy grandes
- **Límites de Supabase Storage**: Supabase tiene límites por plan
- **Límites del edge function**: Pueden tener timeouts (típicamente 60s)

**Recomendación**: Comprimir imágenes antes de subirlas. El código usa `quality: 90` en Camera.getPhoto(), pero para imágenes muy grandes, considera comprimir en el cliente antes del upload.

### ¿Qué formatos de imagen se soportan?

El código detecta automáticamente estos formatos desde los bytes:
- **JPEG**: Detectado por los primeros bytes `FF D8 FF`
- **PNG**: Detectado por `89 50 4E 47`
- **WebP**: Detectado por `RIFF` (52 49 46 46)

**Limitación**: Solo estos 3 formatos están soportados explícitamente. Si el usuario selecciona un HEIC, GIF, o otro formato, se tratará como JPEG (fallback). El edge function puede rechazar formatos no soportados.

### ¿Se puede cancelar un upload en progreso?

**NO hay forma de cancelar un upload en progreso**. Una vez que comienza el PUT, no hay mecanismo de cancelación. El guard `__nativeUploadActive` previene nuevos uploads, pero no cancela uno existente. Para añadir cancelación, necesitarías usar `AbortController` (ver sección "Cómo Modificar el Código").

### ¿Por qué se usa PUT en lugar de POST?

**PUT es idempotente y más simple para uploads directos**:
- **PUT**: Reemplaza el recurso completo en la URL especificada. No necesita multipart/form-data, solo envías los bytes raw con Content-Type.
- **POST multipart**: Requiere boundary, FormData, y es más complejo.

**Ventajas de PUT**:
- Código más simple (solo bytes raw)
- Headers más limpios (solo Content-Type)
- Idempotente (puedes repetir la misma request sin efectos secundarios)
- Mejor para signed URLs de Storage

### ¿Por qué se verifica el upload después de subirlo?

**La verificación es una capa extra de seguridad** porque:
1. **Eventual consistency**: Storage puede retornar 200 pero el archivo puede no estar disponible inmediatamente
2. **Errores silenciosos**: Algunos sistemas retornan 200 incluso si el upload falla internamente
3. **Validación de ruta**: Confirma que el archivo está en la ruta esperada
4. **Prevención de finalize prematuro**: Evita que finalize se ejecute si el archivo realmente no existe

**Trade-off**: Añade una request HTTP adicional, pero previene errores más costosos en finalize.

### ¿Cómo se manejan los errores de CORS?

**CORS típicamente NO es un problema** porque:
1. El código corre en un WebView nativo, no en un navegador con políticas CORS estrictas
2. Las requests van a Supabase (mismo dominio lógico)
3. Capacitor maneja CORS automáticamente

**Sin embargo**, si hay problemas:
- **Síntoma**: Request falla con error de red sin status code
- **Causa**: Configuración incorrecta de CORS en Supabase
- **Solución**: Verificar que Supabase permite requests desde el origen de la app

### ¿Cómo se puede hacer testing de este sistema?

**Testing es complicado** porque:
1. El código JavaScript está embebido en un string Swift
2. Depende de Capacitor plugins (difíciles de mockear)
3. Requiere WebView real para ejecutar

**Estrategias de testing**:
1. **Unit tests del JavaScript**: Extraer el JavaScript a un archivo separado y testearlo con Jest/Jasmine
2. **Integration tests**: Usar Capacitor testing tools para probar en WebView simulado
3. **E2E tests**: Probar en dispositivo/simulador real
4. **Mock del edge function**: Usar herramientas como MSW (Mock Service Worker) para mockear las APIs

**Mejora sugerida**: Extraer el JavaScript a un archivo `.js` separado y cargarlo en runtime, facilitando testing y mantenimiento.

---

## Resumen de Campos Críticos

### Ticket Response (issue-fortune-upload-ticket)

**Requeridos**:
- `url`: URL firmada para PUT
- `bucketRelativePath`: Ruta relativa al bucket

**Opcionales**:
- `bucket`: Nombre del bucket (default: "photos")
- `requiredHeaders`: Headers adicionales

### Finalize Request

**Requeridos**:
- `fortune_id`: UUID del fortune
- `bucket`: Nombre del bucket
- `path`: Ruta bucket-relative (SIN prefijo "photos/")

**Opcionales**:
- `mime`: MIME type
- `width`: Ancho en pixels
- `height`: Alto en pixels
- `size_bytes`: Tamaño en bytes

### Finalize Response

**Campos**:
- `signedUrl`: URL pública firmada de la imagen
- `replaced`: Boolean indicando si reemplazó una foto existente

---

## Conclusión

Este sistema permite que el código web use funcionalidades nativas de iOS para seleccionar y subir fotos, mientras mantiene toda la lógica de negocio en JavaScript. La clave es entender que:

1. **Swift solo inyecta JavaScript** - No maneja la lógica de upload
2. **JavaScript corre en el WebView** - Tiene acceso a Capacitor plugins y fetch API
3. **Edge functions deben retornar campos específicos** - `url` y `bucketRelativePath` son críticos
4. **El flujo es: Ticket → Upload → Verify → Finalize**
5. **Capacitor Camera maneja la selección nativa** - iOS muestra una pantalla de confirmación incluso con `allowEditing: false`

Cualquier cambio en la lógica de upload debe hacerse en el string JavaScript dentro de `NativeUploaderBridge.swift`.
