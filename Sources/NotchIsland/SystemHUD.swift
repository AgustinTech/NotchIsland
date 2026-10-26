import AppKit
import AudioToolbox
import CoreAudio

// MARK: - Detecta cambios de volumen y brillo

/// Avisa cuando cambia el volumen de salida (CoreAudio) o el brillo de la pantalla integrada
/// (DisplayServices, framework privado: si no existe en esta versión de macOS, solo se pierde el brillo).
/// No usa teclas ni permisos: escucha el estado del sistema, venga el cambio de donde venga.
final class SystemHUDMonitor {
    /// Nivel (0…1) y si está silenciado. Siempre en el hilo principal.
    var onVolume: ((Double, Bool) -> Void)?
    /// Brillo (0…1). Siempre en el hilo principal.
    var onBrightness: ((Double) -> Void)?

    private var started = false

    // MARK: Volumen

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var registered: [AudioObjectPropertyAddress] = []
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var ignoreVolumeUntil = Date.distantPast

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var mainVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: Brillo

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias BrightnessCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void
    private typealias RegisterBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, BrightnessCallback) -> Int32
    private typealias UnregisterBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?) -> Int32

    private static weak var current: SystemHUDMonitor?
    private static let brightnessCallback: BrightnessCallback = { _, _, _, _, _ in
        DispatchQueue.main.async { SystemHUDMonitor.current?.brightnessChanged() }
    }

    private var getBrightness: GetBrightness?
    private var unregisterBrightness: UnregisterBrightness?
    private var brightnessDisplay: CGDirectDisplayID?
    private var brightnessHistory: [(date: Date, value: Float)] = []
    private var lastBrightnessShown = Date.distantPast

    // MARK: Arranque y parada

    func start() {
        guard !started else { return }
        started = true
        startVolume()
        startBrightness()
    }

    func stop() {
        guard started else { return }
        started = false
        stopVolume()
        stopBrightness()
    }

    // MARK: - Volumen

    private func startVolume() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // El cambio de dispositivo (enchufar unos auriculares) mueve el volumen: eso no es un aviso.
            self?.ignoreVolumeUntil = Date().addingTimeInterval(0.8)
            self?.attachDevice()
        }
        deviceBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, DispatchQueue.main, block)
        attachDevice()
    }

    private func stopVolume() {
        detachDevice()
        if let deviceBlock {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, DispatchQueue.main, deviceBlock)
        }
        deviceBlock = nil
    }

    private func attachDevice() {
        detachDevice()

        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &id) == noErr,
              id != AudioObjectID(kAudioObjectUnknown) else { return }
        device = id

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.volumeChanged() }
        volumeBlock = block
        for var address in [mainVolumeAddress, muteAddress] where AudioObjectHasProperty(id, &address) {
            if AudioObjectAddPropertyListenerBlock(id, &address, DispatchQueue.main, block) == noErr {
                registered.append(address)
            }
        }
    }

    private func detachDevice() {
        if let volumeBlock, device != AudioObjectID(kAudioObjectUnknown) {
            for var address in registered {
                AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, volumeBlock)
            }
        }
        registered.removeAll()
        volumeBlock = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func volumeChanged() {
        guard Date() >= ignoreVolumeUntil, device != AudioObjectID(kAudioObjectUnknown) else { return }

        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &mainVolumeAddress, 0, nil, &size, &level) == noErr else { return }

        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) {
            AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted)
        }
        onVolume?(Double(min(max(level, 0), 1)), muted != 0)
    }

    // MARK: - Brillo

    private func startBrightness() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let pGet = dlsym(lib, "DisplayServicesGetBrightness"),
              let pRegister = dlsym(lib, "DisplayServicesRegisterForBrightnessChangeNotifications"),
              let display = Self.builtInDisplay() else { return }

        getBrightness = unsafeBitCast(pGet, to: GetBrightness.self)
        if let pUnregister = dlsym(lib, "DisplayServicesUnregisterForBrightnessChangeNotifications") {
            unregisterBrightness = unsafeBitCast(pUnregister, to: UnregisterBrightness.self)
        }

        Self.current = self
        let register = unsafeBitCast(pRegister, to: RegisterBrightness.self)
        if register(display, nil, Self.brightnessCallback) == 0 {
            brightnessDisplay = display
            var initial: Float = 0
            if getBrightness?(display, &initial) == 0 {
                brightnessHistory = [(Date().addingTimeInterval(-10), initial)]
            }
        }
    }

    private func stopBrightness() {
        if let display = brightnessDisplay {
            _ = unregisterBrightness?(display, nil)
        }
        brightnessDisplay = nil
        brightnessHistory.removeAll()
        if Self.current === self { Self.current = nil }
    }

    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// El brillo automático (sensor de luz) también cambia el brillo, poco a poco. Solo se avisa cuando
    /// el cambio es rápido (teclas, deslizador): se compara con el valor de hace más de 0,6 s.
    /// Mientras el aviso sigue visible, cualquier cambio lo actualiza.
    private func brightnessChanged() {
        guard let display = brightnessDisplay, let getBrightness else { return }
        var value: Float = 0
        guard getBrightness(display, &value) == 0 else { return }

        let now = Date()
        let reference = brightnessHistory.last { now.timeIntervalSince($0.date) > 0.6 }?.value
            ?? brightnessHistory.first?.value
            ?? value
        brightnessHistory.append((now, value))
        // Se conservan unos segundos de muestras (y siempre la más reciente anterior a la ventana).
        while brightnessHistory.count > 2, now.timeIntervalSince(brightnessHistory[1].date) > 3 {
            brightnessHistory.removeFirst()
        }

        let fastChange = abs(value - reference) >= 0.035
        let stillShowing = now.timeIntervalSince(lastBrightnessShown) < 1.6

        guard fastChange || (stillShowing && abs(value - reference) > 0.001) else { return }
        lastBrightnessShown = now
        onBrightness?(Double(min(max(value, 0), 1)))
    }
}

// MARK: - Controles del sistema (los usa la intercepción de teclas)

enum SystemControls {
    private static var defaultOutput: AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return id
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func volume() -> Float? {
        guard let device = defaultOutput else { return nil }
        var address = volumeAddress()
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(_ value: Float) {
        guard let device = defaultOutput else { return }
        var address = volumeAddress()
        var v = min(max(value, 0), 1)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func isMuted() -> Bool {
        guard let device = defaultOutput else { return false }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = defaultOutput else { return }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // Brillo (DisplayServices, framework privado)
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func brightness() -> Float? {
        guard let lib = displayServices, let p = dlsym(lib, "DisplayServicesGetBrightness"),
              let display = builtInDisplay else { return nil }
        var value: Float = 0
        let get = unsafeBitCast(p, to: GetBrightness.self)
        return get(display, &value) == 0 ? value : nil
    }

    static func setBrightness(_ value: Float) {
        guard let lib = displayServices, let p = dlsym(lib, "DisplayServicesSetBrightness"),
              let display = builtInDisplay else { return }
        _ = unsafeBitCast(p, to: SetBrightness.self)(display, min(max(value, 0), 1))
    }
}

// MARK: - Intercepta las teclas de volumen y brillo

/// Para que el HUD del sistema no salga a la vez que el del notch, se interceptan las teclas de volumen,
/// silencio y brillo antes de que las vea macOS y se aplica el cambio aquí. Necesita el permiso de
/// Accesibilidad (se concede una vez; la firma estable de la app hace que macOS lo recuerde).
/// Sin ese permiso no hace nada y el sistema muestra su HUD como siempre.
final class MediaKeyInterceptor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var enabled = false
    private var poll: Timer?

    /// Ya se mostró una vez el aviso de macOS para pedir Accesibilidad.
    private static let askedKey = "askedAccessibilityForMediaKeys"

    var isActive: Bool { tap != nil }

    /// Pide el permiso de Accesibilidad (aviso de macOS) y abre su panel en Ajustes.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard !enabled else { return }
        enabled = true
        if AXIsProcessTrusted() {
            installTap()
        } else {
            if !UserDefaults.standard.bool(forKey: Self.askedKey) {
                UserDefaults.standard.set(true, forKey: Self.askedKey)
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
            }
            // Cuando se conceda el permiso, la intercepción se activa sola.
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
                guard let self, self.enabled else { timer.invalidate(); return }
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self.poll = nil
                    self.installTap()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
        }
    }

    func stop() {
        enabled = false
        poll?.invalidate()
        poll = nil
        removeTap()
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << 14   // NX_SYSDEFINED: teclas especiales (volumen, brillo, reproducción…)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        tap = created
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        // El sistema desactiva el tap si tarda demasiado: se vuelve a activar.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passthrough
        }
        guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
            return passthrough
        }

        let data = nsEvent.data1
        let keyCode = Int((data & 0xFFFF0000) >> 16)
        let flags = data & 0x0000FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA

        // 0 volumen +, 1 volumen −, 2 brillo +, 3 brillo −, 7 silencio
        guard [0, 1, 2, 3, 7].contains(keyCode) else { return passthrough }

        if isDown {
            let fine = nsEvent.modifierFlags.contains([.shift, .option])   // pasos más pequeños, como en macOS
            perform(keyCode, fine: fine)
        }
        return nil
    }

    private func perform(_ keyCode: Int, fine: Bool) {
        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0

        func stepped(_ value: Float, _ direction: Float) -> Float {
            let target = ((value / step).rounded() + direction) * step
            return min(max(target, 0), 1)
        }

        switch keyCode {
        case 0, 1:
            let direction: Float = keyCode == 0 ? 1 : -1
            let current = SystemControls.volume() ?? 0
            if SystemControls.isMuted() && direction > 0 { SystemControls.setMuted(false) }
            let next = stepped(current, direction)
            SystemControls.setVolume(next)
            if next > 0 && SystemControls.isMuted() { SystemControls.setMuted(false) }
        case 7:
            SystemControls.setMuted(!SystemControls.isMuted())
        case 2, 3:
            let direction: Float = keyCode == 2 ? 1 : -1
            if let current = SystemControls.brightness() {
                SystemControls.setBrightness(stepped(current, direction))
            }
        default:
            break
        }
    }
}
