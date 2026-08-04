import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Datos del proveedor de identidad. Los identificadores de cliente se leen del
/// Info.plist para que cada compilación use los suyos; no hay secreto de cliente
/// porque la app es un cliente público y usa PKCE.
struct ConfiguracionOAuth: Sendable {
    var autorizacion: URL
    var token: URL
    var ambitos: [String]
    var claveClienteEnPlist: String
    var esquemaDeVuelta: String

    static let google = ConfiguracionOAuth(
        autorizacion: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        token: URL(string: "https://oauth2.googleapis.com/token")!,
        ambitos: ["https://mail.google.com/", "email", "profile"],
        claveClienteEnPlist: "SinMailGoogleClientID",
        esquemaDeVuelta: "sinmail-google"
    )

    static let microsoft = ConfiguracionOAuth(
        autorizacion: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        token: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        ambitos: [
            "https://outlook.office.com/IMAP.AccessAsUser.All",
            "https://outlook.office.com/SMTP.Send",
            "offline_access",
            "email",
            "profile"
        ],
        claveClienteEnPlist: "SinMailMicrosoftClientID",
        esquemaDeVuelta: "sinmail-microsoft"
    )

    var clienteID: String? {
        Bundle.main.object(forInfoDictionaryKey: claveClienteEnPlist) as? String
    }

    var urlDeVuelta: String { "\(esquemaDeVuelta)://oauth" }
}

enum FalloOAuth: LocalizedError {
    case sinClienteConfigurado(String)
    case cancelado
    case respuestaInvalida
    case sinRefresh

    var errorDescription: String? {
        switch self {
        case .sinClienteConfigurado(let clave):
            return "Falta \(clave) en el Info.plist."
        case .cancelado: return "Has cancelado el acceso."
        case .respuestaInvalida: return "El proveedor devolvió una respuesta que no se entiende."
        case .sinRefresh: return "El proveedor no entregó un token de renovación."
        }
    }
}

/// Autorización con PKCE. El navegador del sistema hace el trabajo; la app nunca
/// ve la contraseña del usuario.
@MainActor
final class ClienteOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {

    private let configuracion: ConfiguracionOAuth
    private var sesion: ASWebAuthenticationSession?

    init(configuracion: ConfiguracionOAuth) {
        self.configuracion = configuracion
    }

    struct Resultado: Sendable {
        var credencial: Credencial
        var correo: String
        var nombre: String
    }

    func autorizar() async throws -> Resultado {
        guard let clienteID = configuracion.clienteID, !clienteID.isEmpty else {
            throw FalloOAuth.sinClienteConfigurado(configuracion.claveClienteEnPlist)
        }

        let verificador = Self.generarVerificador()
        let reto = Self.reto(para: verificador)
        let estado = UUID().uuidString

        var componentes = URLComponents(url: configuracion.autorizacion, resolvingAgainstBaseURL: false)!
        componentes.queryItems = [
            URLQueryItem(name: "client_id", value: clienteID),
            URLQueryItem(name: "redirect_uri", value: configuracion.urlDeVuelta),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuracion.ambitos.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: reto),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: estado),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "access_type", value: "offline")
        ]

        let vuelta = try await presentar(url: componentes.url!)
        guard
            let items = URLComponents(url: vuelta, resolvingAgainstBaseURL: false)?.queryItems,
            let codigo = items.first(where: { $0.name == "code" })?.value,
            items.first(where: { $0.name == "state" })?.value == estado
        else {
            throw FalloOAuth.respuestaInvalida
        }

        let credencial = try await canjear(codigo: codigo, verificador: verificador, clienteID: clienteID)
        let perfil = try await perfil(credencial: credencial)
        return Resultado(credencial: credencial, correo: perfil.correo, nombre: perfil.nombre)
    }

    /// Renueva un token caducado. Devuelve la credencial actualizada.
    func renovar(_ credencial: Credencial) async throws -> Credencial {
        guard let clienteID = configuracion.clienteID else {
            throw FalloOAuth.sinClienteConfigurado(configuracion.claveClienteEnPlist)
        }
        guard let refresh = credencial.refreshToken else { throw FalloOAuth.sinRefresh }

        var peticion = URLRequest(url: configuracion.token)
        peticion.httpMethod = "POST"
        peticion.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        peticion.httpBody = Self.formulario([
            "client_id": clienteID,
            "refresh_token": refresh,
            "grant_type": "refresh_token"
        ])

        let (datos, _) = try await URLSession.shared.data(for: peticion)
        var nueva = try Self.decodificarToken(datos)
        nueva.refreshToken = nueva.refreshToken ?? refresh
        return nueva
    }

    // MARK: - Interno

    private func presentar(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuacion in
            let sesion = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: configuracion.esquemaDeVuelta
            ) { vuelta, error in
                if let vuelta {
                    continuacion.resume(returning: vuelta)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuacion.resume(throwing: FalloOAuth.cancelado)
                } else {
                    continuacion.resume(throwing: error ?? FalloOAuth.respuestaInvalida)
                }
            }
            sesion.presentationContextProvider = self
            sesion.prefersEphemeralWebBrowserSession = false
            self.sesion = sesion
            sesion.start()
        }
    }

    private func canjear(codigo: String, verificador: String, clienteID: String) async throws -> Credencial {
        var peticion = URLRequest(url: configuracion.token)
        peticion.httpMethod = "POST"
        peticion.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        peticion.httpBody = Self.formulario([
            "client_id": clienteID,
            "code": codigo,
            "code_verifier": verificador,
            "redirect_uri": configuracion.urlDeVuelta,
            "grant_type": "authorization_code"
        ])

        let (datos, _) = try await URLSession.shared.data(for: peticion)
        return try Self.decodificarToken(datos)
    }

    private struct Perfil { var correo: String; var nombre: String }

    private func perfil(credencial: Credencial) async throws -> Perfil {
        // El id_token trae correo y nombre en su carga útil; se lee sin verificar
        // firma porque llega por un canal TLS directo del proveedor y sólo se usa
        // para rellenar la ficha de la cuenta.
        guard let token = credencial.accessToken else { throw FalloOAuth.respuestaInvalida }
        let url = configuracion.autorizacion.host?.contains("google") == true
            ? URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
            : URL(string: "https://graph.microsoft.com/v1.0/me")!

        var peticion = URLRequest(url: url)
        peticion.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (datos, _) = try await URLSession.shared.data(for: peticion)
        let json = try JSONSerialization.jsonObject(with: datos) as? [String: Any] ?? [:]

        let correo = (json["email"] as? String)
            ?? (json["mail"] as? String)
            ?? (json["userPrincipalName"] as? String)
            ?? ""
        let nombre = (json["name"] as? String)
            ?? (json["displayName"] as? String)
            ?? correo
        guard !correo.isEmpty else { throw FalloOAuth.respuestaInvalida }
        return Perfil(correo: correo, nombre: nombre)
    }

    private static func decodificarToken(_ datos: Data) throws -> Credencial {
        struct Respuesta: Decodable {
            var access_token: String?
            var refresh_token: String?
            var expires_in: Double?
        }
        guard let respuesta = try? JSONDecoder().decode(Respuesta.self, from: datos),
              let acceso = respuesta.access_token else {
            throw FalloOAuth.respuestaInvalida
        }
        return Credencial(
            contrasena: nil,
            accessToken: acceso,
            refreshToken: respuesta.refresh_token,
            expira: respuesta.expires_in.map { Date().addingTimeInterval($0) }
        )
    }

    private static func formulario(_ campos: [String: String]) -> Data {
        var permitidos = CharacterSet.alphanumerics
        permitidos.insert(charactersIn: "-._~")
        return campos
            .map { clave, valor in
                let v = valor.addingPercentEncoding(withAllowedCharacters: permitidos) ?? valor
                return "\(clave)=\(v)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func generarVerificador() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    private static func reto(para verificador: String) -> String {
        let resumen = SHA256.hash(data: Data(verificador.utf8))
        return Data(resumen).base64URL
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let escenas = UIApplication.shared.connectedScenes
            let ventana = escenas
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
            return ventana ?? ASPresentationAnchor()
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
