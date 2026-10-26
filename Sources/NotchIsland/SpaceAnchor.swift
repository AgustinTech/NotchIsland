import AppKit

/// Mantiene la ventana de la isla fija mientras cambias de escritorio (Spaces) con tres dedos.
///
/// Sin esto, la isla se desliza por la barra de arriba junto con la animación del escritorio.
/// La ventana se mete en un "espacio" propio del sistema, siempre visible y por encima, que no
/// participa en el cambio de escritorios. Usa funciones privadas de SkyLight (las mismas que
/// usan otras apps de notch); si no existen en esta versión de macOS, no hace nada.
enum SpaceAnchor {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias AddWindows = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void

    private static var spaceID: UInt64 = 0

    @discardableResult
    static func pin(_ window: NSWindow) -> Bool {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let pConnection = dlsym(lib, "SLSMainConnectionID"),
              let pCreate = dlsym(lib, "SLSSpaceCreate"),
              let pLevel = dlsym(lib, "SLSSpaceSetAbsoluteLevel"),
              let pAdd = dlsym(lib, "SLSAddWindowsToSpaces"),
              let pShow = dlsym(lib, "SLSShowSpaces") else { return false }

        let connection = unsafeBitCast(pConnection, to: MainConnection.self)
        let create = unsafeBitCast(pCreate, to: SpaceCreate.self)
        let setLevel = unsafeBitCast(pLevel, to: SetLevel.self)
        let addWindows = unsafeBitCast(pAdd, to: AddWindows.self)
        let showSpaces = unsafeBitCast(pShow, to: ShowSpaces.self)

        let cid = connection()
        if spaceID == 0 {
            // El 1 es obligatorio: con otro valor Finder empieza a dibujar iconos del escritorio.
            spaceID = create(cid, 1, nil)
            guard spaceID != 0 else { return false }
            _ = setLevel(cid, spaceID, 2_147_483_647)
        }

        let spaces = [NSNumber(value: spaceID)] as CFArray
        showSpaces(cid, spaces)
        addWindows(cid, [NSNumber(value: window.windowNumber)] as CFArray, spaces)
        return true
    }
}
