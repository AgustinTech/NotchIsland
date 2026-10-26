import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt

/// Acciones rápidas de la pestaña Herramientas. Todas usan solo API públicas:
/// - Mantener despierto: aserción de energía de IOKit (no pide permisos).
/// - Modo oscuro y Dock: AppleScript a System Events (pide el permiso de Automatización la primera vez).
/// - Captura: abre la app Captura de pantalla del sistema (no pide permisos).
/// - Papelera: AppleScript al Finder, con confirmación previa (pide Automatización la primera vez).
final class QuickActions: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case awake, darkMode, dock, screenshot, trash

        var id: String { rawValue }
    }

    enum TrashStep: Equatable {
        case idle, armed, working, done
    }

    enum ScriptOutcome: Equatable {
        case done, denied, failed
    }

    @Published private(set) var awake = false
    @Published private(set) var dark = false
    @Published private(set) var dockHidden = false
    @Published private(set) var trash: TrashStep = .idle
    /// Acciones a las que macOS ha negado el permiso de Automatización.
    @Published private(set) var denied = Set<Kind>()

    /// Ejecuta un AppleScript. Corre en una cola propia (puede esperar al aviso de permiso de macOS).
    var scriptRunner: (String) -> ScriptOutcome = QuickActions.runAppleScript

    private var assertionID = IOPMAssertionID(0)
    private let scriptQueue = DispatchQueue(label: "notchisland.quickactions")
    private var disarmWork: DispatchWorkItem?
    private var tokens: [NSObjectProtocol] = []

    init() {
        refresh()
        // La aserción de energía se suelta al salir (el sistema también la suelta si la app muere).
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setAwake(false)
        })
        // El sistema avisa cuando cambia la apariencia (también por el modo automático al anochecer).
        tokens.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.refresh() }
        })
    }

    deinit {
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }

    // MARK: - Estado real del sistema (sin permisos)

    /// Lee la apariencia y el Dock tal como están ahora (al abrir la pestaña y tras cada cambio).
    func refresh() {
        let style = CFPreferencesCopyValue(
            "AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? String
        let isDark = style == "Dark"
        if dark != isDark { dark = isDark }

        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let hidden = (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool) ?? false
        if dockHidden != hidden { dockHidden = hidden }
    }

    // MARK: - Mantener despierto

    func toggleAwake() {
        setAwake(!awake)
    }

    private func setAwake(_ on: Bool) {
        if on {
            if assertionID == 0 {
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "NotchIsland: mantener despierto" as CFString,
                    &id
                )
                if result == kIOReturnSuccess { assertionID = id }
            }
        } else if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        let isOn = assertionID != 0
        if awake != isOn { awake = isOn }
    }

    // MARK: - Modo oscuro y Dock (System Events)

    func toggleDarkMode() {
        let target = !dark
        dark = target
        runScript(
            .darkMode,
            "tell application \"System Events\" to tell appearance preferences to set dark mode to \(target)"
        )
    }

    func toggleDock() {
        let target = !dockHidden
        dockHidden = target
        runScript(
            .dock,
            "tell application \"System Events\" to tell dock preferences to set autohide to \(target)"
        )
    }

    // MARK: - Captura

    /// Cierra la isla y abre la app Captura de pantalla (la barra de Mayús + Cmd + 5).
    func captureScreen(closeIsland: () -> Void) {
        closeIsland()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            let app = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
            if FileManager.default.fileExists(atPath: app.path) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            } else {
                // Respaldo: selección interactiva al portapapeles (macOS pide permiso de grabación de pantalla).
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-c"]
                try? process.run()
            }
        }
    }

    // MARK: - Papelera (dos pasos: pulsar y confirmar)

    func tapTrash() {
        switch trash {
        case .idle:
            trash = .armed
            let work = DispatchWorkItem { [weak self] in
                if self?.trash == .armed { self?.trash = .idle }
            }
            disarmWork?.cancel()
            disarmWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        case .armed:
            disarmWork?.cancel()
            trash = .working
            let source = "with timeout of 300 seconds\ntell application \"Finder\" to empty trash\nend timeout"
            scriptQueue.async { [weak self, runner = scriptRunner] in
                let outcome = runner(source)
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch outcome {
                    case .done:
                        self.trash = .done
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            if self.trash == .done { self.trash = .idle }
                        }
                    case .denied:
                        self.trash = .idle
                        self.denied.insert(.trash)
                    case .failed:
                        self.trash = .idle
                    }
                }
            }
        case .working, .done:
            break
        }
    }

    // MARK: - Permiso de Automatización

    /// Abre Ajustes del Sistema > Privacidad y seguridad > Automatización y borra el aviso de la acción.
    func openAutomationSettings(for kind: Kind) {
        denied.remove(kind)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func runScript(_ kind: Kind, _ source: String) {
        denied.remove(kind)
        scriptQueue.async { [weak self, runner = scriptRunner] in
            let outcome = runner(source)
            DispatchQueue.main.async {
                guard let self else { return }
                if outcome == .denied { self.denied.insert(kind) }
                if outcome == .done {
                    // El sistema tarda un instante en escribir el cambio: se confirma un poco después.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
                } else {
                    // Si falló, el interruptor vuelve a como está el sistema de verdad.
                    self.refresh()
                }
            }
        }
    }

    /// Ejecuta el AppleScript y distingue "permiso denegado" (-1743) de otros fallos.
    static func runAppleScript(_ source: String) -> ScriptOutcome {
        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .done }
        let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        return code == -1743 ? .denied : .failed
    }
}
