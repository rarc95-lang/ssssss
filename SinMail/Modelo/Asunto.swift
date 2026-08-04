import Foundation

/// La unidad de SinMail es la cosa pendiente real ("cotización camilla"), no el
/// mensaje. Un asunto puede abarcar varios hilos y varias personas.
struct Asunto: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// Máximo cinco palabras.
    var titulo: String
    var estado: Estado
    var responsable: String
    /// Máximo diez palabras.
    var situacion: String
    /// Lo que falta para avanzar.
    var falta: String
    /// Verbo + objeto, máximo cuatro palabras. Jamás "Responder".
    var accion: String
    /// Frase literal del hilo que justifica el estado. Nunca parafraseada.
    var cita: String
    /// De 0 a 1.
    var confianza: Double

    /// Hilos que abarca este asunto, en orden cronológico.
    var hilos: [String]
    var cuentaID: String
    /// Mensaje del que procede la cita, para poder resaltarla en el hilo.
    var mensajeDeLaCita: String?

    /// Texto ya redactado que abre la acción primaria. Se calcula al analizar,
    /// para que el borrador se abra sin pantalla intermedia y sin spinner.
    var borrador: String
    var destinatarios: [String]
    var asuntoDelCorreo: String

    /// El modelo propuso el cierre, pero el cierre lo confirma el usuario.
    var cierreSugerido: Bool
    var recordatorio: Date?

    var creado: Date
    var actualizado: Date
    /// Fecha del mensaje más reciente que sostiene el asunto.
    var ultimoMovimiento: Date

    init(
        id: UUID = UUID(),
        titulo: String,
        estado: Estado,
        responsable: String,
        situacion: String,
        falta: String,
        accion: String,
        cita: String,
        confianza: Double,
        hilos: [String],
        cuentaID: String,
        mensajeDeLaCita: String? = nil,
        borrador: String = "",
        destinatarios: [String] = [],
        asuntoDelCorreo: String = "",
        cierreSugerido: Bool = false,
        recordatorio: Date? = nil,
        creado: Date = Date(),
        actualizado: Date = Date(),
        ultimoMovimiento: Date = Date()
    ) {
        self.id = id
        self.titulo = titulo
        self.estado = estado
        self.responsable = responsable
        self.situacion = situacion
        self.falta = falta
        self.accion = accion
        self.cita = cita
        self.confianza = confianza
        self.hilos = hilos
        self.cuentaID = cuentaID
        self.mensajeDeLaCita = mensajeDeLaCita
        self.borrador = borrador
        self.destinatarios = destinatarios
        self.asuntoDelCorreo = asuntoDelCorreo
        self.cierreSugerido = cierreSugerido
        self.recordatorio = recordatorio
        self.creado = creado
        self.actualizado = actualizado
        self.ultimoMovimiento = ultimoMovimiento
    }

    /// Clave estable para reconocer el mismo asunto entre sincronizaciones,
    /// aunque el modelo reformule el título.
    var claveDeIdentidad: String {
        (hilos.sorted().joined(separator: "|") + "#" + cuentaID)
    }

    /// La línea "Falta: …" sólo aparece cuando falta algo de verdad. En LEER no
    /// hay nada pendiente por definición, y en CERRADO ya no queda nada.
    var muestraFalta: Bool {
        (estado == .tuyo || estado == .esperando) && !falta.isEmpty
    }

    /// TUYO muestra tres acciones, ESPERANDO dos, LEER y CERRADO ninguna.
    var acciones: [AccionTarjeta] {
        switch estado {
        case .tuyo:
            return [.primaria(accion), .verHilo, .cerrar]
        case .esperando:
            return [.recordar, .verHilo]
        case .leer, .cerrado:
            return []
        }
    }
}

/// Las acciones van al pie de la tarjeta, sólo en texto, diferenciadas por
/// color y nunca con fondo.
enum AccionTarjeta: Equatable, Identifiable {
    /// Nombra el acto concreto ("Enviar el número"). Jamás dice "Responder".
    case primaria(String)
    case verHilo
    case cerrar
    case recordar

    var id: String { titulo }

    var titulo: String {
        switch self {
        case .primaria(let texto): return texto
        case .verHilo: return "Ver hilo"
        case .cerrar: return "Cerrar"
        case .recordar: return "Recordar"
        }
    }

    var esPrimaria: Bool {
        switch self {
        case .primaria, .recordar: return true
        case .verHilo, .cerrar: return false
        }
    }
}

// MARK: - Propuesta del modelo

/// Lo que devuelve el modelo, antes de pasar por el validador. Es deliberadamente
/// distinto de `Asunto`: nada llega a la bandeja sin validarse.
struct AsuntoPropuesto: Codable, Sendable {
    var titulo: String
    var estado: String
    var responsable: String
    var situacion: String
    var falta: String
    var accion: String
    var cita: String
    var confianza: Double
    /// Identificadores de hilo que el modelo agrupa bajo un mismo asunto.
    var hilos: [String]?

    enum CodingKeys: String, CodingKey {
        case titulo, estado, responsable, situacion, falta, accion, cita, confianza, hilos
    }
}
