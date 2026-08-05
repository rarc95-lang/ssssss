import Foundation

/// El modelo procesa cada hilo y devuelve JSON puro. Nunca es un asistente, ni un
/// chat, ni un botón: es la máquina que mantiene el estado de las tarjetas.
protocol MotorAnalisis: Sendable {
    func analizar(hilo: Hilo, identidad: Direccion) async throws -> [AsuntoPropuesto]
}

enum FalloAnalisis: LocalizedError {
    case sinClave
    case respuestaNoJSON(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .sinClave: return "Falta la clave del modelo."
        case .respuestaNoJSON: return "El modelo no devolvió JSON."
        case .http(let codigo, let texto): return "El modelo respondió \(codigo): \(texto)"
        }
    }
}
