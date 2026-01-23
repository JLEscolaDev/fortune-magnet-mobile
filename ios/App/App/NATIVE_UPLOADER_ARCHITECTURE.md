# Native Uploader Architecture - iOS Implementation

> **📅 Última Actualización**: 2026-01-23
> 
> **⚠️ Cambio Importante**: Se ha añadido `NativePhotoPicker` (API simplificada) que resuelve el problema de POST vs PUT. 
> El código TypeScript de Lovable ahora maneja el upload usando `supabase.storage.uploadToSignedUrl()` que correctamente usa PUT.
> 
> **Recomendación**: Usar `NativePhotoPicker` + código TypeScript de Lovable en lugar del legacy `NativeUploader`.

## Tabla de Contenidos

1. [Visión General](#visión-general)
2. [Arquitectura del Sistema](#arquitectura-del-sistema)
3. [Clases Clave](#clases-clave)
4. [NativePhotoPicker - API Simplificada (NUEVO)](#nativephotopicker---api-simplificada-nuevo)
5. [NativeUploader - API Legacy (Compatibilidad)](#nativeuploader---api-legacy-compatibilidad)
6. [Flujo Completo de Upload](#flujo-completo-de-upload)
7. [Selección de Fotos: Capacitor Camera Plugin](#selección-de-fotos-capacitor-camera-plugin)
8. [Inyección de JavaScript](#inyección-de-javascript)
9. [Comunicación Web ↔ Native](#comunicación-web--native)
10. [Edge Functions - Contratos de API](#edge-functions---contratos-de-api)
11. [Manejo de Memoria y Performance](#manejo-de-memoria-y-performance)
12. [Manejo de Errores y Edge Cases](#manejo-de-errores-y-edge-cases)
13. [Debugging y Logging](#debugging-y-logging)
    - [Cómo Leer los Logs de iOS](#cómo-leer-los-logs-de-ios)
    - [Logs Clave para Debugging](#logs-clave-para-debugging)
    - [Identificar Qué Código Está Ejecutándose](#identificar-qué-código-está-ejecutándose)
    - [Checklist de Diagnóstico para Lovable](#checklist-de-diagnóstico-para-lovable)
14. [Cómo Modificar el Código](#cómo-modificar-el-código)
15. [Troubleshooting](#troubleshooting)
    - [Resumen Ejecutivo para Lovable](#resumen-ejecutivo-para-lovable)
    - [Problema: UPLOAD_NOT_PERSISTED](#problema-upload_not_persisted---el-archivo-no-se-encuentra-después-del-upload)
16. [Preguntas Frecuentes](#preguntas-frecuentes)

---

## Visión General

El sistema de **Native Uploader** permite que la aplicación web (que corre en un WebView de Capacitor) pueda usar funcionalidades nativas de iOS para seleccionar y subir fotos.

### Arquitectura Dual (2026-01-23)

El sistema ahora expone **dos APIs**:

1. **`NativePhotoPicker` (NUEVO - Recomendado)**:
   - Solo maneja la selección de fotos nativa
   - Retorna bytes + metadata al código TypeScript de Lovable
   - El upload lo maneja Lovable usando `supabase.storage.uploadToSignedUrl()` (PUT correcto)
   - **Ventaja**: Código compartido entre Web/iOS/Android, más fácil de mantener

2. **`NativeUploader` (LEGACY - Compatibilidad)**:
   - Maneja el pipeline completo: pick → upload → finalize
   - Se mantiene para compatibilidad hacia atrás
   - Será deprecado cuando todos los clientes usen el nuevo picker

**Componentes**:
- **Swift (iOS Native)**: Inyecta JavaScript en el WebView
- **JavaScript (Inyectado)**: Expone APIs nativas al código web
- **Capacitor Camera Plugin**: Para acceder al selector de fotos nativo de iOS
- **Lovable TypeScript**: Maneja el upload usando Supabase SDK (`processAndUpload`)
- **Supabase Edge Functions**: Para obtener tickets de upload y finalizar el proceso

---

## Arquitectura del Sistema

### Arquitectura Nueva (Recomendada): NativePhotoPicker

```
┌─────────────────────────────────────────────────────────────┐
│                    iOS App (Swift)                          │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  NativeUploaderBridge.swift                           │  │
│  │  - Inyecta window.NativePhotoPicker                   │  │
│  │  - Solo maneja picking (Capacitor Camera)             │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                        │
                        │ Retorna bytes + metadata
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              WebView (Lovable TypeScript)                    │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  FortuneModal.tsx + nativeUploader.ts                │  │
│  │                                                       │  │
│  │  1. NativePhotoPicker.pickPhoto()                    │  │
│  │     └─ Retorna: { bytes, mimeType, width, height }   │  │
│  │                                                       │  │
│  │  2. processAndUpload(file, options)                  │  │
│  │     ├─ POST /functions/v1/issue-fortune-upload-ticket│  │
│  │     ├─ supabase.storage.uploadToSignedUrl() ✓       │  │
│  │     │   └─ PUT con raw bytes (correcto)              │  │
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

### Arquitectura Legacy: NativeUploader (Compatibilidad)

```
┌─────────────────────────────────────────────────────────────┐
│                    iOS App (Swift)                          │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  NativeUploaderBridge.swift                           │  │
│  │  - Inyecta window.NativeUploader                      │  │
│  │  - Maneja pipeline completo                           │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                        │
                        │ Inyecta JavaScript
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              WebView (JavaScript Inyectado)                │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  window.NativeUploader.pickAndUploadFortunePhoto()   │  │
│  │                                                       │  │
│  │  1. Capacitor.Plugins.Camera.getPhoto()              │  │
│  │  2. POST /functions/v1/issue-fortune-upload-ticket   │  │
│  │  3. PUT uploadUrl (raw bytes)                       │  │
│  │  4. GET /storage/v1/object/list (verify)             │  │
│  │  5. POST /functions/v1/finalize-fortune-photo         │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                        │
                        │ HTTP Requests
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              Supabase Backend                               │
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
- Inyecta **dos APIs** en el WebView:
  1. **`window.NativePhotoPicker`** (NUEVO): Picker simplificado que solo maneja selección
  2. **`window.NativeUploader`** (LEGACY): API completa para compatibilidad hacia atrás
- Contiene el código JavaScript como strings literales
- Lo inyecta en el WebView usando `evaluateJavaScript()`
- Verifica que la inyección fue exitosa

**Estructura**:

```swift
@objc class NativeUploaderBridge: NSObject {
    private static let TAG = "NativeUploaderBridge"
    private static let NATIVE_UPLOADER_IMPL_VERSION = "ios-injected-v3-2026-01-18"
    private static let NATIVE_PHOTO_PICKER_VERSION = "ios-picker-v1-2026-01-23"
    
    weak var bridgeViewController: CAPBridgeViewController?
    
    func injectJavaScript() {
        // Inyecta ambos sistemas
        injectSimplePhotoPicker()  // Nuevo picker simplificado
        injectLegacyUploader()     // Legacy para compatibilidad
    }
    
    private func injectSimplePhotoPicker() {
        // Inyecta window.NativePhotoPicker.pickPhoto()
        // Usa Capacitor Camera plugin directamente en JavaScript
        // Solo maneja selección, retorna bytes + metadata
        // NO requiere handlers Swift adicionales
    }
    
    private func injectLegacyUploader() {
        // Inyecta window.NativeUploader.pickAndUploadFortunePhoto()
        // Maneja pipeline completo: pick → upload → finalize
        // Se mantiene para compatibilidad hacia atrás
    }
}
```

**Versión de Implementación**: 
- `NATIVE_PHOTO_PICKER_VERSION`: Versión del nuevo picker simplificado (`"ios-picker-v1-2026-01-23"`)
- `NATIVE_UPLOADER_IMPL_VERSION`: Versión del legacy uploader (`"ios-injected-v3-2026-01-18"`)
- Si `window.NativeUploader.__impl` o `window.NativePhotoPicker.__impl` ya existen, NO se sobrescriben
- Esto permite que el código web pueda definir su propia implementación si es necesario

**Cuándo modificar**:
- **Nuevo picker**: Modificar `injectSimplePhotoPicker()` si necesitas cambiar la lógica de selección
  - El código JavaScript usa `Capacitor.Plugins.Camera.getPhoto()` directamente
  - No requiere cambios en Swift nativo
- **Legacy uploader**: Modificar `injectLegacyUploader()` si necesitas cambiar el pipeline completo
  - Contiene toda la lógica de upload en JavaScript inyectado
- **⚠️ Recomendación**: Preferir modificar el código TypeScript de Lovable antes que el legacy uploader

**Diferencias clave entre las dos APIs**:

| Aspecto | NativePhotoPicker (Nuevo) | NativeUploader (Legacy) |
|---------|---------------------------|-------------------------|
| **Selección** | Capacitor Camera en JS | Capacitor Camera en JS |
| **Upload** | Lovable TypeScript (`processAndUpload`) | JavaScript inyectado |
| **Método HTTP** | PUT (via `uploadToSignedUrl()`) | PUT (corregido recientemente) |
| **Código Swift** | Solo inyección JS | Solo inyección JS |
| **Handlers Swift** | No requiere | No requiere |
| **Mantenibilidad** | Código compartido Web/iOS/Android | Código específico iOS |
| **Recomendación** | ✅ Usar este | ⚠️ Solo para compatibilidad |

---

## NativePhotoPicker - API Simplificada (NUEVO)

### Visión General

`NativePhotoPicker` es la nueva API simplificada que **solo maneja la selección de fotos**. El upload lo maneja el código TypeScript de Lovable usando `supabase.storage.uploadToSignedUrl()`, que correctamente usa PUT con raw bytes.

**Ventajas**:
- ✅ Código compartido entre Web/iOS/Android
- ✅ Upload correcto usando Supabase SDK (PUT automático)
- ✅ Más fácil de mantener y debuggear
- ✅ Consistente con el código web

### API

```javascript
// Verificar disponibilidad
if (window.NativePhotoPickerAvailable && window.NativePhotoPicker) {
  // Usar nuevo picker
}

// Llamar al picker
const result = await window.NativePhotoPicker.pickPhoto();

// Resultado
{
  bytes: Uint8Array,      // Bytes raw de la imagen
  mimeType: string,       // "image/jpeg", "image/png", etc.
  width: number,          // Ancho en píxeles
  height: number,         // Alto en píxeles
  cancelled?: boolean     // true si el usuario canceló
}
```

### Implementación en Swift

**Ubicación**: `NativeUploaderBridge.swift` - método `injectSimplePhotoPicker()`

**Código JavaScript Inyectado**:
```javascript
window.NativePhotoPicker = {
  __impl: IMPL_VERSION,
  
  pickPhoto: function() {
    console.log("[NativePhotoPicker] pickPhoto called");
    
    return new Promise(async function(resolve, reject) {
      try {
        // 1. Usa Capacitor Camera plugin para seleccionar foto
        if (typeof Capacitor === 'undefined' || !Capacitor.Plugins || !Capacitor.Plugins.Camera) {
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
        
        // 2. Verificar si fue cancelado
        if (cameraResult === null || cameraResult === undefined) {
          resolve({ cancelled: true });
          return;
        }
        
        var webPath = cameraResult.webPath || cameraResult.path || '';
        if (!webPath) {
          resolve({ cancelled: true });
          return;
        }
        
        // 3. Carga la imagen desde webPath para obtener bytes
        var fileResp = await fetch(webPath);
        var blob = await fileResp.blob();
        var mimeType = blob.type || 'image/jpeg';
        var buf = await blob.arrayBuffer();
        var imageBytes = new Uint8Array(buf);
        
        // 4. Obtener dimensiones (del resultado o cargando la imagen)
        var width = cameraResult.width || 0;
        var height = cameraResult.height || 0;
        
        if (!width || !height) {
          var img = new Image();
          img.src = webPath;
          await new Promise(function(imgResolve) {
            img.onload = function() {
              width = img.width;
              height = img.height;
              imgResolve();
            };
            img.onerror = function() {
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
        
        // 5. Retorna bytes + metadata
        resolve({
          bytes: imageBytes,
          mimeType: mimeType,
          width: width,
          height: height,
          cancelled: false
        });
        
      } catch (error) {
        // Manejar cancelación vs errores reales
        var errorMsg = error && (error.message || String(error)) || 'Unknown error';
        if (errorMsg.toLowerCase().indexOf('cancel') !== -1) {
          resolve({ cancelled: true });
        } else {
          reject(error);
        }
      }
    });
  }
};

window.NativePhotoPickerAvailable = true;
```

**Características**:
- ✅ Usa `Capacitor.Plugins.Camera.getPhoto()` directamente (no requiere handlers Swift adicionales)
- ✅ Maneja cancelación correctamente (retorna `{ cancelled: true }`)
- ✅ Obtiene dimensiones automáticamente si no están disponibles en el resultado
- ✅ Convierte la imagen a `Uint8Array` para retornar bytes raw
- ✅ Detecta MIME type automáticamente desde el blob
- ✅ Usa `resultType: 'Uri'` para obtener webPath y luego carga los bytes
- ✅ Maneja errores y los diferencia de cancelaciones

**Ventajas de esta implementación**:
- **No requiere código Swift adicional**: Todo se maneja en JavaScript usando Capacitor Camera
- **Más simple**: No necesita message handlers ni delegates
- **Consistente**: Usa el mismo plugin que el legacy uploader
- **Mantenible**: Todo el código está en un solo lugar (JavaScript inyectado)

### Uso en Lovable (TypeScript)

```typescript
// En FortuneModal.tsx
if (window.NativePhotoPickerAvailable && window.NativePhotoPicker) {
  // 1. Seleccionar foto
  const pickerResult = await window.NativePhotoPicker.pickPhoto();
  
  if (pickerResult.cancelled) {
    return;
  }
  
  // 2. Convertir bytes a File
  // Uint8Array es compatible directamente con File constructor
  const extension = pickerResult.mimeType === 'image/png' ? 'png' : 'jpg';
  const file = new File(
    [pickerResult.bytes],  // Uint8Array es un BlobPart válido
    `photo-${Date.now()}.${extension}`,
    { type: pickerResult.mimeType }
  );
  
  // 3. Usar código compartido de Lovable para upload
  const uploadOptions: NativeUploaderOptions = {
    supabaseUrl: 'https://pegiensgnptpdnfopnoj.supabase.co',
    accessToken: accessToken,
    userId: user.id,
    fortuneId: fortuneId
  };
  
  // processAndUpload usa supabase.storage.uploadToSignedUrl() correctamente
  // Esto automáticamente usa PUT con raw bytes (correcto para signed URLs)
  const result = await new Promise<NativeUploaderResult>((resolve) => {
    processAndUpload(uploadOptions, file, resolve);
  });
  
  // Manejar resultado
  if (result.signedUrl) {
    setFortunePhoto(result.signedUrl);
    // ... resto del manejo
  }
}
```

**Nota sobre Uint8Array**: 
- `Uint8Array` es directamente compatible con el constructor `File`
- No necesita conversión adicional - `File` acepta `BlobPart[]` y `Uint8Array` es un `BlobPart` válido
- El código JavaScript inyectado ya retorna `Uint8Array` correctamente formateado

### Logs Esperados

**En iOS Console (Xcode)**:
```
[NativePhotoPicker] Initializing simple photo picker bridge
[NativePhotoPicker] Bridge initialized - simplified picker ready
[NativePhotoPicker] pickPhoto called
[NativePhotoPicker] Opening photo picker...
[NativePhotoPicker] Camera result received
[NativePhotoPicker] Photo selected, loading from: capacitor://localhost/_capacitor_file_/...
[NativePhotoPicker] Photo converted: 358336 bytes, 2048x1536
```

**En Lovable WebView Console**:
```
[PHOTO] Using new NativePhotoPicker (simplified flow)
[NativePhotoPicker] pickPhoto called
[NativePhotoPicker] Opening photo picker...
[NativePhotoPicker] Camera result received
[NativePhotoPicker] Photo selected, loading from: capacitor://...
[NativePhotoPicker] Photo converted: 358336 bytes, 2048x1536
[PHOTO] Photo picked: { mimeType: "image/jpeg", bytesLength: 358336, width: 2048, height: 1536 }
[NATIVE-UPLOADER] STAGE=pick
[NATIVE-UPLOADER] STAGE=ticket { bucket: "photos", uploadMethod: "PUT" }
[NATIVE-UPLOADER] STAGE=upload { hasSignedUploadToken: true }
[NATIVE-UPLOADER] STAGE=upload_ok
[NATIVE-UPLOADER] STAGE=finalize
[NATIVE-UPLOADER] STAGE=done
[PHOTO] Upload result from processAndUpload: { signedUrl: "https://...", replaced: false }
```

**Nota**: 
- Los logs de `[NativePhotoPicker]` vienen del código JavaScript inyectado en iOS
- Los logs de `[NATIVE-UPLOADER]` vienen del código TypeScript de Lovable (`nativeUploader.ts`)
- Los logs de `[PHOTO]` vienen de `FortuneModal.tsx`

---

## NativeUploader - API Legacy (Compatibilidad)

### Visión General

`NativeUploader` es la API legacy que maneja el pipeline completo: selección → upload → finalización. Se mantiene para compatibilidad hacia atrás pero **será deprecado** cuando todos los clientes migren a `NativePhotoPicker`.

**⚠️ Nota**: Esta API tiene el problema conocido de usar POST en lugar de PUT para signed URLs. Por eso se recomienda usar `NativePhotoPicker` + código TypeScript de Lovable.

### API

```javascript
// Verificar disponibilidad
if (window.NativeUploaderAvailable && window.NativeUploader) {
  // Usar legacy uploader
}

// Llamar al uploader
const result = await window.NativeUploader.pickAndUploadFortunePhoto({
  supabaseUrl: 'https://...',
  accessToken: '...',
  userId: '...',
  fortuneId: '...'
});

// Resultado
{
  success: boolean,
  signedUrl?: string,
  path?: string,
  bucket?: string,
  width?: number,
  height?: number,
  cancelled?: boolean,
  error?: string,
  stage?: 'ticket' | 'upload' | 'verify' | 'finalize'
}
```

### Implementación

**Ubicación**: `NativeUploaderBridge.swift` - método `injectLegacyUploader()`

El código JavaScript inyectado maneja todo el flujo:
1. Selección de foto (Capacitor Camera)
2. Obtención de ticket (edge function)
3. Upload a Storage (PUT con raw bytes - corregido)
4. Verificación de upload
5. Finalización (edge function con retry)

---

## Flujo Completo con NativePhotoPicker (Nuevo)

### Paso 1: Detección y Llamada desde Lovable

```typescript
// En FortuneModal.tsx
const hasNewPicker = window.NativePhotoPickerAvailable && window.NativePhotoPicker;

if (hasNewPicker) {
  // Usar nuevo picker simplificado
  const pickerResult = await window.NativePhotoPicker.pickPhoto();
}
```

**Logs esperados**:
```
[PHOTO] Using new NativePhotoPicker (simplified flow)
[NativePhotoPicker] pickPhoto called
```

### Paso 2: Selección de Foto (JavaScript Inyectado)

El código JavaScript inyectado usa Capacitor Camera:

```javascript
var cameraResult = await Capacitor.Plugins.Camera.getPhoto({
  quality: 90,
  allowEditing: false,
  source: 'PHOTOS',
  resultType: 'Uri',
  correctOrientation: true
});
```

**Qué ocurre**:
1. Capacitor abre el selector nativo de iOS (`UIImagePickerController`)
2. Usuario selecciona una foto
3. iOS muestra pantalla de confirmación (comportamiento nativo)
4. Usuario confirma → Capacitor procesa la foto y retorna `webPath`

**Logs esperados**:
```
[NativePhotoPicker] Opening photo picker...
[NativePhotoPicker] Camera result received
```

### Paso 3: Conversión a Bytes (JavaScript Inyectado)

```javascript
// Cargar imagen desde webPath
var fileResp = await fetch(webPath);
var blob = await fileResp.blob();
var buf = await blob.arrayBuffer();
var imageBytes = new Uint8Array(buf);
```

**Logs esperados**:
```
[NativePhotoPicker] Photo selected, loading from: capacitor://...
[NativePhotoPicker] Photo converted: 358336 bytes, 2048x1536
```

### Paso 4: Retorno a Lovable

El JavaScript retorna el resultado a Lovable:

```javascript
resolve({
  bytes: imageBytes,        // Uint8Array
  mimeType: 'image/jpeg',   // Detectado del blob
  width: 2048,              // Del resultado o cargado
  height: 1536,              // Del resultado o cargado
  cancelled: false
});
```

**Logs esperados**:
```
[PHOTO] Photo picked: { mimeType: "image/jpeg", bytesLength: 358336, width: 2048, height: 1536 }
```

### Paso 5: Creación de File y Upload (Lovable TypeScript)

```typescript
// Crear File desde bytes
const file = new File(
  [pickerResult.bytes],
  `photo-${Date.now()}.jpg`,
  { type: pickerResult.mimeType }
);

// Usar código compartido de Lovable
const result = await new Promise((resolve) => {
  processAndUpload(uploadOptions, file, resolve);
});
```

**Qué hace `processAndUpload()`**:
1. Obtiene ticket del edge function (`issue-fortune-upload-ticket`)
2. Usa `supabase.storage.uploadToSignedUrl()` con el token
3. Esto internamente hace **PUT con raw bytes** (correcto)
4. Llama a `finalize-fortune-photo` para completar

**Logs esperados**:
```
[NATIVE-UPLOADER] STAGE=ticket { bucket: "photos", uploadMethod: "PUT" }
[NATIVE-UPLOADER] STAGE=upload { hasSignedUploadToken: true }
[NATIVE-UPLOADER] STAGE=upload_ok
[NATIVE-UPLOADER] STAGE=finalize
[NATIVE-UPLOADER] STAGE=done
```

### Ventajas del Nuevo Flujo

1. **Código compartido**: El upload lo maneja Lovable, funciona igual en Web/iOS/Android
2. **PUT correcto**: `uploadToSignedUrl()` usa PUT automáticamente
3. **Más simple**: iOS solo maneja la selección, no el upload
4. **Más fácil de debuggear**: Todo el código de upload está en TypeScript
5. **Mantenible**: Un solo lugar para cambios de upload

---

## Flujo Completo de Upload (Legacy - NativeUploader)

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

**⚠️ FORZADO AUTOMÁTICO DE PUT**: El código **SIEMPRE usa PUT** cuando detecta un signed URL (URLs que contienen `/upload/sign/`), incluso si el ticket especifica `uploadMethod: 'POST_MULTIPART'`. Esto es crítico porque los signed URLs de Supabase Storage **requieren PUT** y no funcionan con POST multipart.

**Lógica de decisión**:
```javascript
// Detecta si es signed URL
var isSignedUrl = uploadUrl && uploadUrl.indexOf('/upload/sign/') !== -1;

// FORCE PUT for signed URLs - they don't work with POST multipart
var finalUploadMethod;
if (isSignedUrl) {
  finalUploadMethod = 'PUT';  // SIEMPRE PUT para signed URLs
  if (uploadMethod && uploadMethod.toUpperCase() !== 'PUT') {
    console.warn('⚠️ WARNING: Ticket specifies POST_MULTIPART but URL is signed URL. Forcing PUT.');
  }
} else {
  // Para URLs no-signed, usa el método del ticket o POST_MULTIPART por defecto
  finalUploadMethod = (uploadMethod || 'POST_MULTIPART').toUpperCase();
}
```

**Por qué PUT en lugar de POST**:
- **PUT es idempotente**: Puedes repetir la misma request sin efectos secundarios
- **Más simple**: No necesita multipart/form-data, solo envías los bytes raw con Content-Type
- **Requerido para signed URLs**: Los signed URLs de Supabase Storage con token **requieren PUT** - POST multipart retorna 200 pero no persiste el archivo
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

**⚠️ CRÍTICO**: Puede haber DOS implementaciones diferentes ejecutándose. Los logs muestran claramente cuál se está usando.

#### 1. JavaScript Inyectado (NativeUploaderBridge.swift)

**Características**:
- Logs empiezan con `[NATIVE-UPLOADER][INJECTED]` o `[NativeUploader]`
- Usa `Capacitor.Plugins.Camera.getPhoto()` para seleccionar fotos
- Ejecuta TODO el flujo en JavaScript dentro del WebView
- Detecta automáticamente signed URLs y usa PUT

**Logs esperados del código INYECTADO**:
```
[NATIVE-UPLOADER][INJECTED] FUNCTION CALLED - pickAndUploadFortunePhoto entry point
[NativeUploader] Opening photo picker...
[NativeUploader] PICKER_OK w=2048 h=1152 bytes=358336
[NATIVE-UPLOADER] ticket: POST https://.../issue-fortune-upload-ticket
[NATIVE-UPLOADER] ticket: status=200
[NATIVE-UPLOADER] uploadMethod decision: ticketMethod=PUT, isSignedUrl=true, finalMethod=PUT
[NATIVE-UPLOADER] uploadMethod decision: ticketMethod=POST_MULTIPART, isSignedUrl=true, finalMethod=PUT  ← ⚠️ Forzado a PUT
[NATIVE-UPLOADER] upload PUT: https://.../storage/v1/object/upload/sign/...
[NativeUploader] UPLOAD_START method=PUT path=userId/file.jpg mime=image/jpeg
[NATIVE-UPLOADER] upload: status=200 method=PUT
```

#### 2. Código Web de Lovable

**Características**:
- Logs empiezan con `[NATIVE-UPLOADER]` pero **SIN** `[INJECTED]`
- Tiene su propia implementación que sobrescribe `window.NativeUploader`
- Puede hacer el upload directamente sin usar el código inyectado
- **PROBLEMA**: Típicamente usa POST cuando debería usar PUT

**Logs actuales del código de LOVABLE (INCORRECTO)**:
```
[NATIVE-UPLOADER] iOS handler hit (main), reqId=1  ← ⚠️ Código de Lovable
[NATIVE-UPLOADER] processAndUpload: fortuneId=...  ← ⚠️ NO es código inyectado
[NATIVE-UPLOADER] image prepared: 2048x1152 bytes=358336
[NATIVE-UPLOADER] ticket: POST https://.../issue-fortune-upload-ticket
[NATIVE-UPLOADER] ticket: status=200
[NATIVE-UPLOADER] upload POST: https://.../storage/v1/object/upload/sign/...  ← ⚠️ POST (incorrecto)
[NATIVE-UPLOADER] upload: status=200  ← Parece exitoso pero...
[NATIVE-UPLOADER] finalize: status=500  ← ❌ FALLO
[NATIVE-UPLOADER] finalize: body={"error":"UPLOAD_NOT_PERSISTED"...}
```

**Cómo identificar rápidamente**:

| Log | Significado |
|-----|-------------|
| `[NATIVE-UPLOADER][INJECTED]` | ✅ Código inyectado (correcto) |
| `[NATIVE-UPLOADER] iOS handler hit` | ⚠️ Código de Lovable (puede tener problemas) |
| `[NativeUploader] Opening photo picker...` | ✅ Código inyectado |
| `[NATIVE-UPLOADER] processAndUpload:` | ⚠️ Código de Lovable |
| `upload PUT:` | ✅ Método correcto |
| `upload POST:` con `/upload/sign/` | ❌ Método incorrecto para signed URLs |

**Por qué el código inyectado NO se ejecuta cuando Lovable tiene su propio código**:

El código inyectado verifica si ya existe una implementación:

```javascript
// En NativeUploaderBridge.swift línea ~27
if (window.NativeUploader && window.NativeUploader.__impl) {
  console.log("existing implementation detected, skipping install");
  return; // NO sobrescribe
}
```

Si Lovable define `window.NativeUploader.pickAndUploadFortunePhoto` ANTES de que se inyecte el código, o si define `window.NativeUploader.__impl`, el código inyectado NO se ejecutará.

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

**✅ SOLUCIÓN IMPLEMENTADA**: Se ha añadido `NativePhotoPicker` que resuelve el problema de POST vs PUT.

**Nueva Arquitectura (Recomendada)**:
- iOS expone `window.NativePhotoPicker.pickPhoto()` que solo maneja selección
- Lovable maneja el upload usando `processAndUpload()` → `supabase.storage.uploadToSignedUrl()`
- Esto usa PUT correctamente automáticamente (Supabase SDK lo maneja)

**⚠️ PROBLEMA LEGACY**: Los logs muestran que Lovable tiene su propio código ejecutándose que NO respeta PUT.

**Evidencia de los logs**:
```
[NATIVE-UPLOADER] iOS handler hit (main), reqId=1  ← Código de Lovable ejecutándose
[NATIVE-UPLOADER] processAndUpload: fortuneId=...  ← NO es código inyectado
[NATIVE-UPLOADER] upload POST: https://.../upload/sign/...  ← ⚠️ Usa POST (incorrecto)
[NATIVE-UPLOADER] upload: status=200  ← Parece exitoso pero...
[NATIVE-UPLOADER] finalize: status=500  ← FALLO
[NATIVE-UPLOADER] finalize: body={"error":"UPLOAD_NOT_PERSISTED"...}  ← Archivo no encontrado
```

**Causa raíz**: 
- Lovable tiene código propio que sobrescribe el código inyectado
- Ese código usa **POST multipart** cuando el signed URL requiere **PUT con raw bytes**
- La URL contiene `/upload/sign/` que es un signed URL de Supabase Storage que **SIEMPRE requiere PUT**

**✅ SOLUCIÓN RECOMENDADA (Nueva Arquitectura)**:

**Usar `NativePhotoPicker` + código TypeScript de Lovable**:
1. iOS ya expone `window.NativePhotoPicker.pickPhoto()` (implementado)
2. Lovable debe actualizar `FortuneModal.tsx` para usar el nuevo picker
3. El código TypeScript de Lovable (`processAndUpload`) ya usa `supabase.storage.uploadToSignedUrl()` correctamente
4. Esto resuelve el problema automáticamente porque Supabase SDK usa PUT correctamente

**Ver**: [NativePhotoPicker - API Simplificada](#nativephotopicker---api-simplificada-nuevo)

---

**⚠️ SOLUCIÓN LEGACY (Si necesitas mantener código propio)**:

1. **Buscar en el código de Lovable** donde se hace el upload (buscar `upload POST` o `fetch(uploadUrl`)
2. **Reemplazar POST por PUT** cuando la URL contiene `/upload/sign/`
3. **Cambiar FormData por raw bytes** (`Uint8Array`)
4. **Añadir header Content-Type** con el MIME type

**Código completo para copiar y pegar**: Ver sección [Solución Completa para Lovable](#solución-completa-para-lovable-código-de-ejemplo)

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

**⚠️ ESTE ES EL PROBLEMA MÁS COMÚN Y CRÍTICO**

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

**⚠️ DIAGNÓSTICO CRÍTICO**: Los logs muestran que **Lovable tiene su propio código ejecutándose**, NO el código inyectado.

**Evidencia en los logs**:
- `[NATIVE-UPLOADER] iOS handler hit (main), reqId=1` ← **Código de Lovable**
- `[NATIVE-UPLOADER] processAndUpload:` ← **NO es código inyectado**
- `[NATIVE-UPLOADER] upload POST:` ← **Usa POST (incorrecto)**

**Si ves estos logs, el código inyectado NO se está ejecutando**. Lovable tiene su propia implementación que está sobrescribiendo el código inyectado.

---

### Opción 1: Usar el Código Inyectado (Recomendado - Más Simple)

**El código inyectado ya tiene toda la lógica correcta**. Para asegurar que se ejecute:

1. **Buscar y eliminar código de Lovable**: 
   - Busca cualquier definición de `window.NativeUploader` en el código de Lovable
   - Busca funciones como `processAndUpload` o `upload` relacionadas con fotos
   - Elimina o comenta estas definiciones

2. **Verificar que no hay `__impl` definido**: 
   - El código inyectado NO sobrescribe si detecta `window.NativeUploader.__impl`
   - Asegúrate de que Lovable NO defina `window.NativeUploader.__impl`

3. **Verificar orden de ejecución**: 
   - El código inyectado se ejecuta al iniciar la app (0.5s después de launch)
   - Si Lovable define `window.NativeUploader` después, puede sobrescribir
   - Asegúrate de que Lovable NO defina nada en `window.NativeUploader` después del bootstrap

4. **Verificar logs después de reiniciar la app**:
   ```
   NativeUploaderBridge: JavaScript bridge injected
   [NATIVE-UPLOADER][INJECTED] installed ios-injected-v3-2026-01-18
   ```
   Si ves estos logs, el código inyectado está activo.

5. **Verificar que se ejecuta al hacer upload**:
   ```
   [NATIVE-UPLOADER][INJECTED] FUNCTION CALLED - pickAndUploadFortunePhoto entry point
   [NativeUploader] Opening photo picker...
   [NATIVE-UPLOADER] uploadMethod decision: ticketMethod=PUT, isSignedUrl=true, finalMethod=PUT
[NATIVE-UPLOADER] uploadMethod decision: ticketMethod=POST_MULTIPART, isSignedUrl=true, finalMethod=PUT  ← ⚠️ Forzado a PUT
   [NATIVE-UPLOADER] upload PUT: https://...
   ```

**Ventajas de usar el código inyectado**:
- ✅ Ya tiene toda la lógica correcta implementada
- ✅ Detecta automáticamente signed URLs y usa PUT
- ✅ Maneja todos los edge cases
- ✅ Tiene logging completo para debugging
- ✅ No requiere cambios en Lovable

---

### Opción 2: Corregir el Código de Lovable (Si Necesitas Mantenerlo)

Si por alguna razón necesitas mantener el código de Lovable, debes corregirlo para usar PUT.

## Solución Completa para Lovable - Código de Ejemplo

### Paso 1: Identificar Dónde Está el Código de Upload en Lovable

**Los logs muestran estos patrones que indican código de Lovable**:
- `[NATIVE-UPLOADER] iOS handler hit`
- `[NATIVE-UPLOADER] processAndUpload:`
- `[NATIVE-UPLOADER] upload POST:` (cuando debería ser PUT)

**Busca en el código de Lovable por estos términos**:

1. **Buscar por logs específicos**:
   ```javascript
   // Busca código que loguee estos mensajes:
   console.log('[NATIVE-UPLOADER] iOS handler hit');
   console.log('[NATIVE-UPLOADER] processAndUpload:');
   console.log('[NATIVE-UPLOADER] upload POST:');
   ```

2. **Buscar por funciones**:
   ```javascript
   // Busca funciones con estos nombres:
   function processAndUpload(...)
   async function processAndUpload(...)
   const processAndUpload = (...)
   ```

3. **Buscar por fetch con uploadUrl**:
   ```javascript
   // Busca código que haga fetch al uploadUrl:
   fetch(uploadUrl, { method: 'POST', ... })
   fetch(ticketData.url, { method: 'POST', ... })
   ```

4. **Buscar por FormData en contexto de upload**:
   ```javascript
   // Busca código que use FormData para uploads:
   const formData = new FormData();
   formData.append('file', ...);
   fetch(uploadUrl, { method: 'POST', body: formData })
   ```

5. **Buscar definiciones de window.NativeUploader**:
   ```javascript
   // Busca código que defina:
   window.NativeUploader = { ... }
   window.NativeUploader.pickAndUploadFortunePhoto = function(...) { ... }
   ```

**Ubicaciones comunes en Lovable**:
- Archivos relacionados con "upload", "photo", "image"
- Componentes de formularios que manejan fotos
- Utilidades o helpers de upload
- Archivos que manejan la integración con Supabase Storage

### Paso 2: Código Correcto para Lovable

**Reemplaza TODO el código de upload con esto**:

```javascript
// DESPUÉS de obtener el ticket:
const ticketResponse = await fetch(supabaseUrl + '/functions/v1/issue-fortune-upload-ticket', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ' + supabaseToken,
    'apikey': supabaseAnonKey
  },
  body: JSON.stringify({
    fortune_id: fortuneId,
    mime: mimeType
  })
});

const ticketData = await ticketResponse.json();

// CRÍTICO: Detectar si es signed URL (siempre requiere PUT)
const uploadUrl = ticketData.url;
const isSignedUrl = uploadUrl && uploadUrl.indexOf('/upload/sign/') !== -1;

// CRÍTICO: Leer uploadMethod del ticket, o detectar automáticamente
const ticketUploadMethod = ticketData.uploadMethod;
const shouldUsePut = ticketUploadMethod === 'PUT' || isSignedUrl;

// Detectar MIME type desde los bytes de la imagen
function getMimeTypeFromBytes(bytes) {
  if (bytes.length < 4) return 'image/jpeg';
  const byte0 = bytes[0];
  const byte1 = bytes[1];
  const byte2 = bytes[2];
  const byte3 = bytes[3];
  
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

const detectedMimeType = getMimeTypeFromBytes(imageBytes);

// Logging para debugging
console.log('[NATIVE-UPLOADER] uploadMethod decision:', {
  ticketMethod: ticketUploadMethod || 'NOT_PROVIDED',
  isSignedUrl: isSignedUrl,
  shouldUsePut: shouldUsePut,
  uploadUrl: uploadUrl.substring(0, 100)
});

let uploadResponse;

if (shouldUsePut) {
  // ✅ PUT con raw bytes (REQUERIDO para signed URLs)
  console.log('[NATIVE-UPLOADER] upload PUT: ' + uploadUrl.substring(0, 100));
  console.log('[NATIVE-UPLOADER] UPLOAD_START method=PUT path=' + ticketData.bucketRelativePath + ' mime=' + detectedMimeType + ' bytes=' + imageBytes.length);
  
  uploadResponse = await fetch(uploadUrl, {
    method: 'PUT',  // CRÍTICO: PUT, no POST
    headers: {
      'Content-Type': detectedMimeType,  // image/jpeg, image/png, etc.
      // Añade headers adicionales del ticket si los hay
      ...(ticketData.requiredHeaders || {})
    },
    body: imageBytes  // CRÍTICO: Uint8Array raw bytes, NO FormData
  });
} else {
  // ⚠️ POST multipart (solo para URLs legacy que no son signed URLs)
  console.log('[NATIVE-UPLOADER] upload POST: ' + uploadUrl.substring(0, 100));
  console.log('[NATIVE-UPLOADER] UPLOAD_START method=POST path=' + ticketData.bucketRelativePath);
  
  const formData = new FormData();
  formData.append(ticketData.formFieldName || 'file', imageBlob, 'photo.jpg');
  
  const uploadHeaders = {
    'x-upsert': 'true',
    ...(ticketData.requiredHeaders || {})
  };
  // NO incluir Content-Type - fetch lo añade automáticamente con boundary
  
  uploadResponse = await fetch(uploadUrl, {
    method: 'POST',
    headers: uploadHeaders,
    body: formData
  });
}

const uploadStatus = uploadResponse.status;
const uploadResponseText = await uploadResponse.text();

if (uploadStatus === 200 || uploadStatus === 201 || uploadStatus === 204) {
  console.log('[NATIVE-UPLOADER] upload: status=' + uploadStatus + ' method=' + (shouldUsePut ? 'PUT' : 'POST'));
  console.log('[NATIVE-UPLOADER] upload success');
} else {
  console.error('[NATIVE-UPLOADER] upload: status=' + uploadStatus);
  console.error('[NATIVE-UPLOADER] upload failed: ' + uploadResponseText);
  throw new Error('Upload failed: ' + uploadStatus);
}
```

### Paso 3: Verificación Post-Cambio

Después de aplicar el cambio, los logs deben mostrar:

**✅ CORRECTO**:
```
[NATIVE-UPLOADER] uploadMethod decision: {ticketMethod: "PUT", isSignedUrl: true, shouldUsePut: true, ...}
[NATIVE-UPLOADER] upload PUT: https://.../storage/v1/object/upload/sign/...
[NATIVE-UPLOADER] UPLOAD_START method=PUT path=userId/file.jpg mime=image/jpeg bytes=358336
[NATIVE-UPLOADER] upload: status=200 method=PUT
[NATIVE-UPLOADER] upload success
[NATIVE-UPLOADER] finalize: status=200  ← ✅ Debe ser 200, no 500
```

**❌ INCORRECTO (lo que está pasando ahora)**:
```
[NATIVE-UPLOADER] upload POST: https://.../storage/v1/object/upload/sign/...
[NATIVE-UPLOADER] upload: status=200 method=POST
[NATIVE-UPLOADER] finalize: status=500  ← ❌ FALLO
[NATIVE-UPLOADER] finalize: body={"error":"UPLOAD_NOT_PERSISTED"...}
```

### Paso 4: Variables Requeridas

Asegúrate de que estas variables existan en el scope:

- `imageBytes`: `Uint8Array` con los bytes de la imagen
- `imageBlob`: `Blob` de la imagen (para POST legacy)
- `mimeType`: String como `'image/jpeg'` o `'image/png'`
- `ticketData`: Objeto con la respuesta del ticket
- `supabaseToken`: Token de acceso de Supabase
- `supabaseAnonKey`: Anon key de Supabase
- `supabaseUrl`: URL de Supabase

### Paso 5: Verificación Final

Después de aplicar el cambio, verifica los logs:

**✅ CORRECTO (debe aparecer así)**:
```
[NATIVE-UPLOADER] uploadMethod decision: {ticketMethod: "PUT", isSignedUrl: true, shouldUsePut: true, ...}
[NATIVE-UPLOADER] upload PUT: https://.../storage/v1/object/upload/sign/...
[NATIVE-UPLOADER] UPLOAD_START method=PUT path=userId/file.jpg mime=image/jpeg bytes=358336
[NATIVE-UPLOADER] upload: status=200 method=PUT
[NATIVE-UPLOADER] upload success
[NATIVE-UPLOADER] finalize: status=200  ← ✅ Debe ser 200, no 500
[NATIVE-UPLOADER] finalize: body={"signedUrl":"https://...","replaced":false}  ← ✅ Éxito
```

**❌ INCORRECTO (lo que está pasando ahora)**:
```
[NATIVE-UPLOADER] upload POST: https://.../storage/v1/object/upload/sign/...  ← ⚠️ POST (incorrecto)
[NATIVE-UPLOADER] upload: status=200 method=POST  ← Parece exitoso pero...
[NATIVE-UPLOADER] finalize: status=500  ← ❌ FALLO
[NATIVE-UPLOADER] finalize: body={"error":"UPLOAD_NOT_PERSISTED"...}  ← Archivo no encontrado
```

### Resumen: Qué Hacer Según los Logs

**Si ves `[NATIVE-UPLOADER] iOS handler hit`**:
- ✅ Lovable tiene su propio código ejecutándose
- ✅ Usa la Opción 2: Corregir el código de Lovable (arriba)
- ✅ O usa la Opción 1: Eliminar código de Lovable y usar el inyectado

**Si ves `[NATIVE-UPLOADER][INJECTED] FUNCTION CALLED`**:
- ✅ El código inyectado se está ejecutando
- ✅ Debería funcionar correctamente
- ✅ Si aún falla, verifica que el ticket incluya `uploadMethod: 'PUT'`

**Si ves `upload POST:` con URL que contiene `/upload/sign/`**:
- ❌ **PROBLEMA CRÍTICO**: Está usando POST cuando debe usar PUT
- ✅ Corrige el código para usar PUT cuando detecte `/upload/sign/`
- ✅ O elimina el código de Lovable y usa el inyectado

---

## Checklist de Acción para Lovable (Basado en Logs Reales)

### ✅ Paso 1: Confirmar el Problema

Basado en los logs proporcionados, confirma que ves:
- [ ] `[NATIVE-UPLOADER] iOS handler hit (main), reqId=1`
- [ ] `[NATIVE-UPLOADER] processAndUpload: fortuneId=...`
- [ ] `[NATIVE-UPLOADER] upload POST: https://.../storage/v1/object/upload/sign/...`
- [ ] `[NATIVE-UPLOADER] upload: status=200`
- [ ] `[NATIVE-UPLOADER] finalize: status=500`
- [ ] `[NATIVE-UPLOADER] finalize: body={"error":"UPLOAD_NOT_PERSISTED"...}`

**Si TODOS estos están presentes**: Lovable tiene código propio que usa POST incorrectamente.

### ✅ Paso 2: Decidir Estrategia

**Opción A: Usar código inyectado (Recomendado)**
- [ ] Buscar y eliminar código de Lovable que define `window.NativeUploader`
- [ ] Buscar y eliminar funciones `processAndUpload` en Lovable
- [ ] Verificar que no hay `window.NativeUploader.__impl` definido
- [ ] Reiniciar la app y verificar logs muestran `[NATIVE-UPLOADER][INJECTED]`

**Opción B: Corregir código de Lovable**
- [ ] Encontrar el código que hace `fetch(uploadUrl, { method: 'POST' })`
- [ ] Reemplazar con el código de ejemplo completo de arriba
- [ ] Asegurar que detecta `/upload/sign/` y usa PUT automáticamente
- [ ] Añadir logging para verificar qué método se usa

### ✅ Paso 3: Aplicar el Cambio

**Si eliges Opción A (código inyectado)**:
1. Elimina código de Lovable relacionado con uploads nativos
2. Reinicia la app completamente
3. Verifica logs: debe aparecer `[NATIVE-UPLOADER][INJECTED]`

**Si eliges Opción B (corregir Lovable)**:
1. Copia el código completo del "Paso 2: Código Correcto para Lovable" arriba
2. Reemplaza TODO el código de upload en Lovable
3. Asegúrate de que `imageBytes` sea `Uint8Array` (no `Blob`)
4. Asegúrate de que detecta signed URLs automáticamente

### ✅ Paso 4: Verificar el Fix

Después del cambio, los logs deben mostrar:

**✅ CORRECTO**:
```
[NATIVE-UPLOADER] uploadMethod decision: {ticketMethod: "PUT", isSignedUrl: true, shouldUsePut: true}
[NATIVE-UPLOADER] upload PUT: https://.../storage/v1/object/upload/sign/...
[NATIVE-UPLOADER] UPLOAD_START method=PUT path=userId/file.jpg mime=image/jpeg bytes=358336
[NATIVE-UPLOADER] upload: status=200 method=PUT
[NATIVE-UPLOADER] upload success
[NATIVE-UPLOADER] finalize: status=200  ← ✅ Debe ser 200
[NATIVE-UPLOADER] finalize: body={"signedUrl":"https://...","replaced":false}  ← ✅ Éxito
```

**❌ Si aún ves POST**:
- El código no se actualizó correctamente
- Hay otro lugar donde se hace el upload
- El código de Lovable se está ejecutando después del cambio

### ✅ Paso 5: Debugging Adicional

**Si el problema persiste después del cambio**:

1. **Verificar que el cambio se aplicó**:
   - Busca en el código: `method: 'PUT'` (debe estar presente)
   - Busca: `body: imageBytes` (debe ser Uint8Array, no FormData)
   - Busca: detección de `/upload/sign/`

2. **Verificar que imageBytes es Uint8Array**:
   ```javascript
   console.log('[DEBUG] imageBytes type:', imageBytes.constructor.name);
   // Debe ser "Uint8Array", NO "Blob" o "ArrayBuffer"
   ```

3. **Verificar que la URL se detecta correctamente**:
   ```javascript
   const isSignedUrl = uploadUrl.indexOf('/upload/sign/') !== -1;
   console.log('[DEBUG] isSignedUrl:', isSignedUrl, 'uploadUrl:', uploadUrl.substring(0, 100));
   ```

4. **Verificar headers**:
   ```javascript
   console.log('[DEBUG] uploadHeaders:', JSON.stringify(uploadHeaders));
   // Debe incluir 'Content-Type': 'image/jpeg' (o png, etc.)
   // NO debe incluir 'Content-Type': 'multipart/form-data'
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
