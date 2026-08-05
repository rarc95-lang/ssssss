import Foundation

enum FalloSMTP: LocalizedError {
    case rechazado(codigo: Int, texto: String)
    case sinSTARTTLS
    case credencialCaducada

    var errorDescription: String? {
        switch self {
        case .rechazado(let codigo, let texto): return "El servidor SMTP respondió \(codigo): \(texto)"
        case .sinSTARTTLS: return "El servidor SMTP no admite conexión cifrada."
        case .credencialCaducada: return "El acceso a la cuenta ha caducado."
        }
    }
}

/// Cliente SMTP con STARTTLS o TLS directo, AUTH PLAIN y XOAUTH2.
actor ClienteSMTP {

    private let conexion: Conexion
    private let servidor: Servidor
    private var extensiones: Set<String> = []

    init(servidor: Servidor) {
        self.servidor = servidor
        self.conexion = Conexion(
            host: servidor.host,
            puerto: servidor.puerto,
            tls: servidor.seguridad == .tls
        )
    }

    func enviar(
        fuente: Data,
        de: String,
        para: [String],
        usuario: String,
        credencial: Credencial
    ) async throws {
        try await conexion.abrir()
        _ = try await esperar(codigos: [220])
        try await saludar()

        if servidor.seguridad == .starttls {
            guard extensiones.contains("STARTTLS") else { throw FalloSMTP.sinSTARTTLS }
            try await orden("STARTTLS", esperando: [220])
            try await conexion.ascenderATLS()
            // Tras subir a TLS hay que volver a saludar: lo anunciado en claro no vale.
            try await saludar()
        }

        try await autenticar(usuario: usuario, credencial: credencial)

        try await orden("MAIL FROM:<\(de)>", esperando: [250])
        for destinatario in para {
            try await orden("RCPT TO:<\(destinatario)>", esperando: [250, 251])
        }
        try await orden("DATA", esperando: [354])

        try await conexion.enviar(puntear(fuente))
        try await conexion.enviar("\r\n.\r\n")
        _ = try await esperar(codigos: [250])

        try? await orden("QUIT", esperando: [221])
        await conexion.cerrar()
    }

    // MARK: - Interno

    private func saludar() async throws {
        let respuesta = try await ordenConTexto("EHLO sinmail.local", esperando: [250])
        extensiones = Set(
            respuesta
                .components(separatedBy: "\n")
                .map { linea in
                    String(linea.dropFirst(4)).split(separator: " ").first.map(String.init) ?? ""
                }
                .map { $0.uppercased() }
        )
    }

    private func autenticar(usuario: String, credencial: Credencial) async throws {
        if let token = credencial.accessTokenVigente {
            let cadena = "user=\(usuario)\u{01}auth=Bearer \(token)\u{01}\u{01}"
            let base64 = Data(cadena.utf8).base64EncodedString()
            try await orden("AUTH XOAUTH2 \(base64)", esperando: [235])
            return
        }
        guard let clave = credencial.contrasena else { throw FalloSMTP.credencialCaducada }
        var carga = Data()
        carga.append(0)
        carga.append(contentsOf: Array(usuario.utf8))
        carga.append(0)
        carga.append(contentsOf: Array(clave.utf8))
        try await orden("AUTH PLAIN \(carga.base64EncodedString())", esperando: [235])
    }

    private func orden(_ texto: String, esperando codigos: [Int]) async throws {
        _ = try await ordenConTexto(texto, esperando: codigos)
    }

    @discardableResult
    private func ordenConTexto(_ texto: String, esperando codigos: [Int]) async throws -> String {
        try await conexion.enviarLinea(texto)
        return try await esperar(codigos: codigos)
    }

    /// Lee una respuesta completa, incluidas las multilínea (`250-…` / `250 …`).
    @discardableResult
    private func esperar(codigos: [Int]) async throws -> String {
        var acumulado: [String] = []
        while true {
            let linea = try await conexion.leerLinea()
            acumulado.append(linea)
            guard linea.count >= 4 else { continue }
            let indice = linea.index(linea.startIndex, offsetBy: 3)
            if linea[indice] == "-" { continue }

            let codigo = Int(linea.prefix(3)) ?? 0
            guard codigos.contains(codigo) else {
                throw FalloSMTP.rechazado(codigo: codigo, texto: linea)
            }
            return acumulado.joined(separator: "\n")
        }
    }

    /// Duplica el punto inicial de línea, como exige el protocolo.
    private func puntear(_ fuente: Data) -> Data {
        var salida = Data()
        var principioDeLinea = true
        for byte in fuente {
            if principioDeLinea && byte == 0x2E { salida.append(0x2E) }
            salida.append(byte)
            principioDeLinea = (byte == 0x0A)
        }
        return salida
    }
}
