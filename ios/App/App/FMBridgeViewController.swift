import Foundation
import Capacitor
import WebKit

@objc(FMBridgeViewController)
class FMBridgeViewController: CAPBridgeViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        injectFMNativeBridge()
    }

    private func injectFMNativeBridge() {
        let bridgeJS = """
        (function () {
          try {
            var Cap = window.Capacitor || {};
            var Plugins = Cap.Plugins || {};
            var Camera = Plugins.Camera || {};
            var CameraResultType = Camera.CameraResultType || (Plugins.Camera && Plugins.CameraResultType) || {};
            var CameraSource = Camera.CameraSource || (Plugins.Camera && Plugins.CameraSource) || {};

            async function pickImage(opts) {
              try {
                var sourceMap = { prompt: CameraSource.Prompt, camera: CameraSource.Camera, photos: CameraSource.Photos };
                var photo = await Camera.getPhoto({
                  resultType: CameraResultType.DataUrl,
                  quality: (opts && opts.quality) ?? 80,
                  allowEditing: (opts && opts.allowEditing) ?? false,
                  source: sourceMap[(opts && opts.source) || 'prompt']
                });
                return (photo && photo.dataUrl) ? { dataUrl: photo.dataUrl } : null;
              } catch (e) { return null; }
            }

            window.FMNative = {
              isNative: function () { return true; },
              pickImage: pickImage
            };
          } catch (e) {
            // swallow
          }
        })();
        """

        if let wk = self.bridge?.webView {
            let userScript = WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            wk.configuration.userContentController.addUserScript(userScript)
        } else if let wk = self.webView {
            let userScript = WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            wk.configuration.userContentController.addUserScript(userScript)
        }
    }
}