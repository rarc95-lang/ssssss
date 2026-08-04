import Foundation

/// Redacta el texto que aparecerá ya escrito al abrir el borrador.
///
/// Se compone en el dispositivo, sin pedir nada a la red, porque el borrador debe
/// abrirse al instante: sin pantalla intermedia y sin spinner. El usuario edita lo
/// que quiera y envía con un segundo toque.
enum RedactorBorrador {

    static func redactar(asunto: Asunto, hilo: Hilo?, identidad: Direccion) -> String {
        let quien = nombreDePila(asunto.responsable, hilo: hilo, identidad: identidad)
        let saludo = quien.isEmpty ? "Hola," : "Hola \(quien),"
        let cuerpo = cuerpoSegunAccion(asunto)
        let firma = nombreDePila(identidad.visible, hilo: nil, identidad: identidad)

        var lineas = [saludo, "", cuerpo, "", "Un saludo,"]
        if !firma.isEmpty { lineas.append(firma) }
        return lineas.joined(separator: "\n")
    }

    /// La primera frase nombra el acto concreto que da nombre a la acción, para
    /// que el borrador y el botón digan lo mismo.
    private static func cuerpoSegunAccion(_ asunto: Asunto) -> String {
        let objeto = objetoDeLaAccion(asunto.accion)

        switch asunto.estado {
        case .esperando:
            return "Te escribo para recordarte \(enMinuscula(asunto.falta)). "
                + "Cuando lo tengas, dime algo y seguimos."
        case .tuyo, .leer, .cerrado:
            if objeto.isEmpty {
                return "Sobre \(enMinuscula(asunto.titulo)): "
            }
            return "Aquí va \(objeto): "
        }
    }

    private static func objetoDeLaAccion(_ accion: String) -> String {
        let piezas = accion.split(separator: " ").map(String.init)
        guard piezas.count > 1 else { return "" }
        return piezas.dropFirst().joined(separator: " ").lowercased()
    }

    private static func enMinuscula(_ texto: String) -> String {
        guard let primera = texto.first else { return texto }
        return primera.lowercased() + texto.dropFirst()
    }

    /// Nombre de pila del responsable, buscándolo entre los participantes del hilo
    /// para no escribir una dirección de correo en el saludo.
    private static func nombreDePila(_ responsable: String, hilo: Hilo?, identidad: Direccion) -> String {
        var nombre = responsable.trimmingCharacters(in: .whitespaces)

        if nombre.contains("@"), let hilo {
            let coincidencia = hilo.otros.first { $0.correo.lowercased() == nombre.lowercased() }
            nombre = coincidencia?.nombre ?? String(nombre.split(separator: "@").first ?? "")
        }
        if nombre.lowercased() == identidad.visible.lowercased(), let hilo {
            nombre = hilo.otros.first?.visible ?? nombre
        }
        let pila = nombre.split(separator: " ").first.map(String.init) ?? nombre
        let limpio = pila.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        return limpio.count > 1 ? limpio : ""
    }
}
