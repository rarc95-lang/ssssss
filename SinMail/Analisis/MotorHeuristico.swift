import Foundation

/// Motor de reserva para cuando no hay clave de modelo configurada o la llamada
/// falla. Sigue la regla de oro: ante la duda, un hilo es un asunto. Y como no
/// entiende el texto, su confianza es siempre baja, lo que deja el asunto en
/// TUYO para que decida el usuario.
struct MotorHeuristico: MotorAnalisis {

    func analizar(hilo: Hilo, identidad: Direccion) async throws -> [AsuntoPropuesto] {
        let ajeno = hilo.ultimoAjeno
        let ultimo = hilo.ultimo

        let esperando = ultimo?.propio == true && !hilo.tienePreguntaSinResponder
        let estado = esperando ? "ESPERANDO" : "TUYO"

        let responsable = esperando
            ? (hilo.otros.first?.visible ?? "la otra parte")
            : identidad.visible

        return [
            AsuntoPropuesto(
                titulo: titulo(de: hilo),
                estado: estado,
                responsable: responsable,
                situacion: situacion(de: hilo, esperando: esperando),
                falta: esperando ? "Su respuesta" : "Tu respuesta",
                accion: esperando ? "Recordar el envío" : "Escribir la respuesta",
                cita: Citas.primeraFraseUtil(de: ajeno?.texto ?? hilo.textoCompleto),
                confianza: 0.4,
                hilos: [hilo.id]
            )
        ]
    }

    private func titulo(de hilo: Hilo) -> String {
        let base = Enhebrador.normalizar(hilo.asunto)
        let palabras = base.split(separator: " ").prefix(5)
        return palabras.isEmpty ? "conversación sin asunto" : palabras.joined(separator: " ")
    }

    private func situacion(de hilo: Hilo, esperando: Bool) -> String {
        let quien = hilo.otros.first?.visible ?? "la otra parte"
        return esperando ? "Enviado, sin respuesta de \(quien)" : "\(quien) espera algo tuyo"
    }
}

/// Utilidades para trabajar con citas literales. La cita nunca se escribe: se
/// recorta del hilo.
enum Citas {

    /// Comprueba que una frase aparece tal cual en el texto, comparando con los
    /// espacios normalizados para tolerar los saltos de línea del correo.
    static func esLiteral(_ cita: String, en texto: String) -> Bool {
        let c = normalizar(cita)
        guard c.count >= 8 else { return false }
        return normalizar(texto).contains(c)
    }

    /// Devuelve el fragmento exacto del texto que corresponde a la cita, para
    /// poder resaltarlo en el hilo tal y como está escrito.
    static func fragmentoExacto(de cita: String, en texto: String) -> String? {
        if texto.contains(cita) { return cita }
        let objetivo = normalizar(cita)
        guard !objetivo.isEmpty else { return nil }

        for frase in frases(de: texto) where normalizar(frase) == objetivo {
            return frase
        }
        for frase in frases(de: texto) where normalizar(frase).contains(objetivo) {
            return frase
        }
        return nil
    }

    /// Última frase con contenido del texto. Es el recurso cuando el modelo no
    /// entrega una cita utilizable: se copia, no se inventa.
    static func primeraFraseUtil(de texto: String) -> String {
        let candidatas = frases(de: texto).filter { $0.count >= 12 }
        return candidatas.first(where: { $0.contains("?") || $0.contains("¿") })
            ?? candidatas.last
            ?? candidatas.first
            ?? texto.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func frases(de texto: String) -> [String] {
        var salida: [String] = []
        var actual = ""
        for caracter in texto {
            if caracter == "\n" {
                let recorte = actual.trimmingCharacters(in: .whitespaces)
                if !recorte.isEmpty { salida.append(recorte) }
                actual = ""
                continue
            }
            actual.append(caracter)
            if caracter == "." || caracter == "?" || caracter == "!" {
                let recorte = actual.trimmingCharacters(in: .whitespaces)
                if !recorte.isEmpty { salida.append(recorte) }
                actual = ""
            }
        }
        let recorte = actual.trimmingCharacters(in: .whitespaces)
        if !recorte.isEmpty { salida.append(recorte) }
        return salida
    }

    static func normalizar(_ texto: String) -> String {
        texto
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
