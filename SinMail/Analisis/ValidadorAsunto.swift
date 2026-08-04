import Foundation

/// Impone las reglas duras sobre lo que devuelve el modelo. Nada llega a la
/// bandeja sin pasar por aquí, porque un modelo puede equivocarse y las reglas no
/// son negociables.
enum ValidadorAsunto {

    static func validar(
        _ propuesto: AsuntoPropuesto,
        hilo: Hilo,
        cuenta: Cuenta,
        anterior: Asunto?
    ) -> Asunto {

        var confianza = min(max(propuesto.confianza, 0), 1)

        // La cita es literal o no es. Si el modelo la ha escrito de su cosecha, se
        // sustituye por una frase recortada del hilo y baja la confianza.
        var cita = propuesto.cita.trimmingCharacters(in: .whitespacesAndNewlines)
        var mensajeDeLaCita = mensaje(conCita: cita, en: hilo)?.id

        if mensajeDeLaCita == nil {
            cita = Citas.primeraFraseUtil(de: hilo.ultimoAjeno?.texto ?? hilo.textoCompleto)
            mensajeDeLaCita = mensaje(conCita: cita, en: hilo)?.id
            confianza = min(confianza, 0.55)
        }

        var estado = Estado(rawValue: propuesto.estado.uppercased()) ?? .tuyo
        var cierreSugerido = false

        // El cierre lo confirma el usuario y nunca el sistema: si el modelo pide
        // CERRADO, se guarda como sugerencia y el asunto sigue siendo del usuario.
        if estado == .cerrado {
            estado = .tuyo
            cierreSugerido = true
        }

        // Nunca CERRADO, ni tampoco LEER, si hay una pregunta sin responder.
        if hilo.tienePreguntaSinResponder, estado == .leer || estado == .cerrado {
            estado = .tuyo
            cierreSugerido = false
        }

        // Con poca confianza decide el usuario.
        if confianza < 0.6 {
            estado = .tuyo
        }

        // Un asunto que el usuario ya cerró no lo reabre el modelo por su cuenta:
        // sólo vuelve a abrirse si llega un mensaje ajeno posterior al cierre.
        if let anterior, anterior.estado == .cerrado {
            let movimientoNuevo = hilo.ultimoAjeno.map { $0.fecha > anterior.actualizado } ?? false
            if !movimientoNuevo { estado = .cerrado }
        }

        let accion = accionValida(propuesto.accion, falta: propuesto.falta, estado: estado)

        return Asunto(
            id: anterior?.id ?? UUID(),
            titulo: recortar(propuesto.titulo, palabras: 5),
            estado: estado,
            responsable: propuesto.responsable.trimmingCharacters(in: .whitespaces),
            situacion: recortar(propuesto.situacion, palabras: 10),
            falta: propuesto.falta.trimmingCharacters(in: .whitespaces),
            accion: accion,
            cita: cita,
            confianza: confianza,
            hilos: propuesto.hilos ?? [hilo.id],
            cuentaID: cuenta.id,
            mensajeDeLaCita: mensajeDeLaCita,
            borrador: anterior?.borrador ?? "",
            destinatarios: destinatarios(de: hilo, cuenta: cuenta),
            asuntoDelCorreo: hilo.asunto,
            cierreSugerido: cierreSugerido,
            recordatorio: anterior?.recordatorio,
            creado: anterior?.creado ?? Date(),
            actualizado: Date(),
            ultimoMovimiento: hilo.fecha
        )
    }

    // MARK: - Reglas de campo

    /// La acción primaria nombra el acto concreto y jamás dice "Responder".
    static func accionValida(_ propuesta: String, falta: String, estado: Estado) -> String {
        let limpia = recortar(propuesta, palabras: 4)
        let raiz = Citas.normalizar(limpia)

        let prohibidas = ["responder", "contestar", "responder correo", "responder al correo", "reply"]
        if !prohibidas.contains(raiz) && !raiz.isEmpty && raiz.split(separator: " ").count >= 2 {
            return limpia
        }
        return derivarAccion(de: falta, estado: estado)
    }

    /// Construye un verbo más objeto a partir de lo que falta.
    private static func derivarAccion(de falta: String, estado: Estado) -> String {
        let objeto = recortar(
            falta
                .replacingOccurrences(of: #"^(su|tu|la|el|los|las|un|una)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces),
            palabras: 2
        )
        guard !objeto.isEmpty else {
            return estado == .esperando ? "Recordar el envío" : "Escribir el mensaje"
        }
        return "Enviar \(objeto.lowercased())"
    }

    static func recortar(_ texto: String, palabras limite: Int) -> String {
        let piezas = texto
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard piezas.count > limite else {
            return piezas.joined(separator: " ")
        }
        return piezas.prefix(limite).joined(separator: " ")
    }

    // MARK: - Apoyos

    private static func mensaje(conCita cita: String, en hilo: Hilo) -> Mensaje? {
        guard !cita.isEmpty else { return nil }
        return hilo.mensajes.last(where: { Citas.esLiteral(cita, en: $0.texto) })
    }

    private static func destinatarios(de hilo: Hilo, cuenta: Cuenta) -> [String] {
        guard let ultimoAjeno = hilo.ultimoAjeno else {
            return hilo.otros.map(\.correo)
        }
        var lista = [ultimoAjeno.de.correo]
        for direccion in ultimoAjeno.para + ultimoAjeno.cc
        where direccion.correo.lowercased() != cuenta.correo.lowercased() {
            if !lista.contains(where: { $0.lowercased() == direccion.correo.lowercased() }) {
                lista.append(direccion.correo)
            }
        }
        return lista
    }
}
