import Foundation

/// Análisis con la API de Claude, llamada directamente desde el dispositivo con
/// la clave del propio usuario. No hay servidor de SinMail por medio.
///
/// El SDK oficial de Anthropic no cubre Swift, así que se habla HTTP con la
/// Messages API tal cual.
struct MotorClaude: MotorAnalisis {

    static let modelo = "claude-opus-5"
    private static let extremo = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let version = "2023-06-01"
    /// Ante un rechazo de las salvaguardas, la petición se reintenta sola en el
    /// modelo que Anthropic recomiende para esa categoría.
    private static let betaReserva = "server-side-fallback-2026-07-01"

    let clave: String
    var sesion: URLSession = .shared

    func analizar(hilo: Hilo, identidad: Direccion) async throws -> [AsuntoPropuesto] {
        let cuerpo: [String: Any] = [
            "model": Self.modelo,
            "max_tokens": 4096,
            "system": PromptEspanol.sistema,
            "fallbacks": "default",
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": PromptEspanol.esquema
                ]
            ],
            "messages": [
                [
                    "role": "user",
                    "content": PromptEspanol.usuario(hilo: hilo, identidad: identidad)
                ]
            ]
        ]

        var peticion = URLRequest(url: Self.extremo)
        peticion.httpMethod = "POST"
        peticion.timeoutInterval = 90
        peticion.setValue(clave, forHTTPHeaderField: "x-api-key")
        peticion.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        peticion.setValue(Self.betaReserva, forHTTPHeaderField: "anthropic-beta")
        peticion.setValue("application/json", forHTTPHeaderField: "Content-Type")
        peticion.httpBody = try JSONSerialization.data(withJSONObject: cuerpo)

        let (datos, respuesta) = try await sesion.data(for: peticion)
        if let http = respuesta as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FalloAnalisis.http(http.statusCode, String(decoding: datos, as: UTF8.self))
        }

        let json = try JSONSerialization.jsonObject(with: datos) as? [String: Any] ?? [:]

        // En Claude Opus 5 un rechazo llega como respuesta correcta con
        // stop_reason "refusal" y sin contenido: hay que mirarlo antes de leer
        // content, o el hilo se queda sin tarjeta y sin explicación.
        if json["stop_reason"] as? String == "refusal" {
            return []
        }

        let bloques = json["content"] as? [[String: Any]] ?? []
        guard let texto = bloques.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw FalloAnalisis.respuestaNoJSON(String(decoding: datos, as: UTF8.self))
        }

        return try Self.leerAsuntos(texto)
    }

    static func leerAsuntos(_ texto: String) throws -> [AsuntoPropuesto] {
        let limpio = texto
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        struct Sobre: Decodable { var asuntos: [AsuntoPropuesto] }
        guard let datos = limpio.data(using: .utf8) else {
            throw FalloAnalisis.respuestaNoJSON(texto)
        }
        do {
            return try JSONDecoder().decode(Sobre.self, from: datos).asuntos
        } catch {
            throw FalloAnalisis.respuestaNoJSON(texto)
        }
    }
}

/// La clave del modelo vive en el llavero, junto a las credenciales de correo.
enum ClaveModelo {
    private static let cuenta = "app.sinmail.modelo"

    static func guardar(_ clave: String) throws {
        try Llavero.guardar(Credencial(contrasena: clave), cuentaID: cuenta)
    }

    static func leer() -> String? {
        (try? Llavero.leer(cuentaID: cuenta))?.contrasena
    }

    static func borrar() { Llavero.borrar(cuentaID: cuenta) }
}
