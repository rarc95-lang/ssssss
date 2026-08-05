import Foundation

/// Puente entre las cuentas y los protocolos. Lee y envía correo real; nada pasa
/// por un servidor propio, porque no hay ninguno: el dispositivo habla
/// directamente con IMAP y SMTP.
actor ServicioCorreo {

    static let shared = ServicioCorreo()

    // MARK: - Lectura

    /// Trae los hilos con actividad desde una fecha.
    func hilos(de cuenta: Cuenta, desde fecha: Date) async throws -> [Hilo] {
        let credencial = try await credencialVigente(para: cuenta)
        let cliente = ClienteIMAP(servidor: cuenta.imap)

        try await cliente.conectar()
        defer { Task { await cliente.salir() } }

        try await cliente.entrar(usuario: cuenta.usuario, credencial: credencial)
        try await cliente.seleccionar(cuenta.buzon)

        let uids = try await cliente.buscarDesde(fecha)
        guard !uids.isEmpty else { return [] }

        let fuentes = try await cliente.traer(uids: Array(uids.suffix(200)))
        let mensajes = fuentes.compactMap {
            MIMEParser.mensaje(desde: $0.fuente, uid: $0.uid, cuenta: cuenta, buzon: cuenta.buzon)
        }

        // Los enviados dan el otro lado de la conversación: sin ellos no se puede
        // saber si una pregunta sigue sin responder.
        var todos = mensajes
        if let enviados = (try? await cliente.buzonDeEnviados()) ?? nil {
            try? await cliente.seleccionar(enviados)
            if let uidsEnviados = try? await cliente.buscarDesde(fecha),
               let fuentesEnviadas = try? await cliente.traer(uids: Array(uidsEnviados.suffix(200))) {
                todos += fuentesEnviadas.compactMap {
                    MIMEParser.mensaje(desde: $0.fuente, uid: $0.uid, cuenta: cuenta, buzon: enviados)
                }
            }
        }

        return Enhebrador.enhebrar(todos)
    }

    /// Espera a que llegue correo nuevo. Es lo que hace que al llegar un mensaje
    /// no aparezca una fila: cambia el estado de una tarjeta que ya existe.
    func esperarNovedades(en cuenta: Cuenta) async throws -> Bool {
        let credencial = try await credencialVigente(para: cuenta)
        let cliente = ClienteIMAP(servidor: cuenta.imap)
        try await cliente.conectar()
        defer { Task { await cliente.salir() } }

        try await cliente.entrar(usuario: cuenta.usuario, credencial: credencial)
        try await cliente.seleccionar(cuenta.buzon)
        return try await cliente.esperarNovedades()
    }

    // MARK: - Envío

    /// Envía de verdad, y sólo cuando el usuario lo ha visto y lo ha tocado.
    func enviar(
        borrador: String,
        asunto: Asunto,
        cuenta: Cuenta,
        respondiendoA original: Mensaje?
    ) async throws {
        let credencial = try await credencialVigente(para: cuenta)

        let destinatarios: [Direccion] = asunto.destinatarios.isEmpty
            ? (original.map { [$0.de] } ?? [])
            : asunto.destinatarios.map { Direccion(nombre: nil, correo: $0) }

        guard !destinatarios.isEmpty else {
            throw FalloSMTP.rechazado(codigo: 0, texto: "El asunto no tiene destinatario.")
        }

        let tema = asunto.asuntoDelCorreo.isEmpty
            ? (original?.asunto ?? asunto.titulo)
            : asunto.asuntoDelCorreo
        let temaFinal = tema.lowercased().hasPrefix("re:") ? tema : "Re: \(tema)"

        let correo = MIMEConstructor.construir(
            de: cuenta.identidad,
            para: destinatarios,
            asunto: temaFinal,
            cuerpo: borrador,
            enRespuestaA: original
        )

        let smtp = ClienteSMTP(servidor: cuenta.smtp)
        try await smtp.enviar(
            fuente: correo.fuente,
            de: cuenta.correo,
            para: destinatarios.map(\.correo),
            usuario: cuenta.usuario,
            credencial: credencial
        )

        // Copia en enviados, para que el hilo quede completo en todos los clientes.
        Task {
            let imap = ClienteIMAP(servidor: cuenta.imap)
            guard (try? await imap.conectar()) != nil else { return }
            try? await imap.entrar(usuario: cuenta.usuario, credencial: credencial)
            if let enviados = (try? await imap.buzonDeEnviados()) ?? nil {
                try? await imap.guardarEnEnviados(correo.fuente, buzon: enviados)
            }
            await imap.salir()
        }
    }

    // MARK: - Credenciales

    /// Devuelve una credencial utilizable, renovando el token OAuth si hace falta.
    private func credencialVigente(para cuenta: Cuenta) async throws -> Credencial {
        var credencial = try Llavero.leer(cuentaID: cuenta.id)

        if cuenta.proveedor.metodo == .oauth2, credencial.accessTokenVigente == nil {
            guard let configuracion = cuenta.proveedor.oauth else { throw FalloIMAP.credencialCaducada }
            let cliente = await ClienteOAuth(configuracion: configuracion)
            credencial = try await cliente.renovar(credencial)
            try Llavero.guardar(credencial, cuentaID: cuenta.id)
        }
        return credencial
    }
}
