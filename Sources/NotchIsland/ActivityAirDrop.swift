import Foundation

/// Reconoce los archivos que acaban de llegar por AirDrop.
///
/// macOS marca cada archivo recibido con `com.apple.quarantine`, y el tercer campo es la app que lo
/// trajo: `sharingd` para AirDrop (los navegadores ponen su nombre). La fecha de ese atributo es la
/// de recepción, no la del archivo, así que un archivo antiguo que se mueve a Descargas no cuenta.
/// Funciona sobre la cola de `DownloadWatcher`.
final class AirDropDetector {
    /// Se llama en la cola de `DownloadWatcher` con los archivos de una misma tanda.
    var onArrival: (([URL]) -> Void)?

    private let queue: DispatchQueue
    private var batch: [URL] = []
    private var flush: DispatchWorkItem?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func consider(_ urls: [URL]) {
        for url in urls where !url.lastPathComponent.contains(".sb-") {
            check(url, attempt: 0)
        }
    }

    /// El atributo puede escribirse un instante después de que aparezca el archivo.
    private func check(_ url: URL, attempt: Int) {
        if let origin = Quarantine.read(url) {
            if origin.agent == "sharingd", abs(origin.date.timeIntervalSinceNow) < 120 {
                add(url)
            }
            return
        }
        guard attempt < 4 else { return }
        queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.check(url, attempt: attempt + 1)
        }
    }

    /// Los archivos que llegan juntos se avisan juntos.
    private func add(_ url: URL) {
        guard !batch.contains(url) else { return }
        batch.append(url)
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let urls = self.batch
            self.batch = []
            self.flush = nil
            self.onArrival?(urls)
        }
        flush = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
