import Foundation

struct Direccion: Codable, Equatable, Hashable, Sendable {
    var nombre: String?
    var correo: String

    var visible: String {
        if let nombre, !nombre.isEmpty { return nombre }
        return correo
    }

    var cabecera: String {
        if let nombre, !nombre.isEmpty {
            return "\(MIMEConstructor.codificarCabecera(nombre)) <\(correo)>"
        }
        return correo
    }
}

/// Un mensaje real, tal y como llega por IMAP.
struct Mensaje: Identifiable, Codable, Equatable, Sendable {
    /// Message-ID de la cabecera. Si falta, se sintetiza con cuenta+UID.
    var id: String
    var uid: UInt32
    var cuentaID: String
    var buzon: String

    var de: Direccion
    var para: [Direccion]
    var cc: [Direccion]
    var asunto: String
    var fecha: Date

    var inReplyTo: String?
    var references: [String]

    /// Cuerpo en texto plano, ya decodificado.
    var texto: String
    var tieneAdjuntos: Bool

    /// Cierto si lo escribió el propio usuario de la cuenta.
    var propio: Bool

    var participantes: [Direccion] { [de] + para + cc }
}

/// Un hilo es la agrupación técnica de mensajes. No es la unidad de la interfaz:
/// la unidad es el asunto. El hilo queda a un toque.
struct Hilo: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var cuentaID: String
    var asunto: String
    var mensajes: [Mensaje]

    var ultimo: Mensaje? { mensajes.last }
    var primero: Mensaje? { mensajes.first }
    var fecha: Date { mensajes.last?.fecha ?? .distantPast }

    /// Todo el texto del hilo, para comprobar que una cita es literal.
    var textoCompleto: String {
        mensajes.map(\.texto).joined(separator: "\n")
    }

    /// El último mensaje que no escribió el usuario.
    var ultimoAjeno: Mensaje? {
        mensajes.last(where: { !$0.propio })
    }

    /// Cierto si el último mensaje ajeno contiene una pregunta y el usuario no
    /// ha escrito después. Regla dura: nunca CERRADO en ese caso.
    var tienePreguntaSinResponder: Bool {
        guard let indice = mensajes.lastIndex(where: { !$0.propio }) else { return false }
        let ajeno = mensajes[indice]
        guard ajeno.texto.contains("?") || ajeno.texto.contains("¿") else { return false }
        let posteriores = mensajes[(indice + 1)...]
        return !posteriores.contains(where: { $0.propio })
    }

    /// Personas distintas del usuario que participan en el hilo.
    var otros: [Direccion] {
        var vistos = Set<String>()
        var salida: [Direccion] = []
        for mensaje in mensajes where !mensaje.propio {
            let clave = mensaje.de.correo.lowercased()
            if vistos.insert(clave).inserted { salida.append(mensaje.de) }
        }
        return salida
    }
}
