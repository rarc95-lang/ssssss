import Foundation
import Security

/// Credenciales de una cuenta. Sólo viven en el llavero del dispositivo.
struct Credencial: Codable, Sendable {
    /// Contraseña o contraseña de aplicación.
    var contrasena: String?
    /// Token de acceso OAuth 2.0.
    var accessToken: String?
    var refreshToken: String?
    var expira: Date?

    var accessTokenVigente: String? {
        guard let accessToken else { return nil }
        if let expira, expira <= Date().addingTimeInterval(60) { return nil }
        return accessToken
    }
}

/// Acceso al llavero, con una entrada por cuenta.
enum Llavero {

    static let servicio = "app.sinmail.credenciales"

    enum Fallo: Error {
        case estado(OSStatus)
        case noEncontrado
    }

    static func guardar(_ credencial: Credencial, cuentaID: String) throws {
        let datos = try JSONEncoder().encode(credencial)
        var consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio,
            kSecAttrAccount as String: cuentaID
        ]
        SecItemDelete(consulta as CFDictionary)
        consulta[kSecValueData as String] = datos
        consulta[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let estado = SecItemAdd(consulta as CFDictionary, nil)
        guard estado == errSecSuccess else { throw Fallo.estado(estado) }
    }

    static func leer(cuentaID: String) throws -> Credencial {
        let consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio,
            kSecAttrAccount as String: cuentaID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var resultado: CFTypeRef?
        let estado = SecItemCopyMatching(consulta as CFDictionary, &resultado)
        guard estado != errSecItemNotFound else { throw Fallo.noEncontrado }
        guard estado == errSecSuccess, let datos = resultado as? Data else {
            throw Fallo.estado(estado)
        }
        return try JSONDecoder().decode(Credencial.self, from: datos)
    }

    static func borrar(cuentaID: String) {
        let consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio,
            kSecAttrAccount as String: cuentaID
        ]
        SecItemDelete(consulta as CFDictionary)
    }
}
