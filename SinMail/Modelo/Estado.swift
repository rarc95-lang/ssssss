import SwiftUI

/// Los estados son exactamente cuatro. No hay más, y no hay subestados.
enum Estado: String, Codable, CaseIterable, Sendable {
    /// La siguiente acción depende del usuario.
    case tuyo = "TUYO"
    /// La siguiente acción depende de otra persona.
    case esperando = "ESPERANDO"
    /// Información sin acción.
    case leer = "LEER"
    /// No queda nada pendiente. Sólo lo confirma el usuario.
    case cerrado = "CERRADO"

    /// Orden de la bandeja: TUYO, ESPERANDO, LEER, CERRADO.
    var orden: Int {
        switch self {
        case .tuyo: return 0
        case .esperando: return 1
        case .leer: return 2
        case .cerrado: return 3
        }
    }

    /// Nunca mayúsculas en la interfaz.
    var etiqueta: String {
        switch self {
        case .tuyo: return "Tuyo"
        case .esperando: return "Esperando"
        case .leer: return "Leer"
        case .cerrado: return "Cerrado"
        }
    }

    var fondo: Color {
        switch self {
        case .tuyo: return Tokens.Color.tuyoFondo
        case .esperando: return Tokens.Color.esperandoFondo
        case .leer: return Tokens.Color.leerFondo
        case .cerrado: return Tokens.Color.cerradoFondo
        }
    }

    var color: Color {
        switch self {
        case .tuyo: return Tokens.Color.tuyoTexto
        case .esperando: return Tokens.Color.esperandoTexto
        case .leer: return Tokens.Color.leerTexto
        case .cerrado: return Tokens.Color.cerradoTexto
        }
    }

    /// El sistema jamás asigna CERRADO: sólo lo confirma el usuario.
    var asignablePorElModelo: Bool { self != .cerrado }
}
