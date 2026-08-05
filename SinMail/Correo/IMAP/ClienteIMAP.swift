import Foundation

enum FalloIMAP: LocalizedError {
    case saludoInesperado(String)
    case rechazado(String)
    case sinBuzon
    case credencialCaducada

    var errorDescription: String? {
        switch self {
        case .saludoInesperado(let t): return "El servidor IMAP saludó de forma inesperada: \(t)"
        case .rechazado(let t): return t
        case .sinBuzon: return "No se pudo abrir la bandeja de entrada."
        case .credencialCaducada: return "El acceso a la cuenta ha caducado."
        }
    }
}

/// Una línea de respuesta IMAP con sus literales ya resueltos.
struct LineaIMAP {
    var texto: String
    var literales: [Data]
}

/// Cliente IMAP4rev1 con lo que SinMail necesita: entrar, seleccionar la bandeja,
/// buscar por fecha, traer mensajes completos y quedarse a la escucha con IDLE.
actor ClienteIMAP {

    private let conexion: Conexion
    private let servidor: Servidor
    private var contador = 0
    private var capacidades: Set<String> = []
    private(set) var abierto = false

    init(servidor: Servidor) {
        self.servidor = servidor
        self.conexion = Conexion(
            host: servidor.host,
            puerto: servidor.puerto,
            tls: servidor.seguridad == .tls
        )
    }

    // MARK: - Sesión

    func conectar() async throws {
        try await conexion.abrir()
        let saludo = try await leerLinea()
        guard saludo.texto.hasPrefix("* OK") || saludo.texto.hasPrefix("* PREAUTH") else {
            throw FalloIMAP.saludoInesperado(saludo.texto)
        }
        try await capacidad()
        if servidor.seguridad == .starttls {
            guard capacidades.contains("STARTTLS") else {
                throw FalloConexion.protocoloInesperado(
                    "El servidor IMAP no admite conexión cifrada."
                )
            }
            _ = try await ejecutar("STARTTLS")
            try await conexion.ascenderATLS()
            // Tras subir a TLS las capacidades anunciadas en claro no valen.
            capacidades.removeAll()
            try await capacidad()
        }
        abierto = true
    }

    func capacidad() async throws {
        let respuesta = try await ejecutar("CAPABILITY")
        for linea in respuesta.untagged where linea.texto.uppercased().contains("CAPABILITY") {
            let piezas = linea.texto
                .replacingOccurrences(of: "* CAPABILITY ", with: "", options: .caseInsensitive)
                .split(separator: " ")
                .map { $0.uppercased() }
            capacidades.formUnion(piezas)
        }
    }

    func entrar(usuario: String, credencial: Credencial) async throws {
        switch (credencial.accessTokenVigente, credencial.contrasena) {
        case (let token?, _):
            try await entrarXOAUTH2(usuario: usuario, token: token)
        case (nil, let clave?):
            _ = try await ejecutar("LOGIN \(Self.entrecomillar(usuario)) \(Self.entrecomillar(clave))")
        default:
            throw FalloIMAP.credencialCaducada
        }
        try await capacidad()
    }

    private func entrarXOAUTH2(usuario: String, token: String) async throws {
        let cadena = "user=\(usuario)\u{01}auth=Bearer \(token)\u{01}\u{01}"
        let base64 = Data(cadena.utf8).base64EncodedString()
        let etiqueta = siguienteEtiqueta()
        try await conexion.enviarLinea("\(etiqueta) AUTHENTICATE XOAUTH2 \(base64)")

        while true {
            let linea = try await leerLinea()
            if linea.texto.hasPrefix("+") {
                // El servidor pide más datos: se contesta vacío para que devuelva el error.
                try await conexion.enviarLinea("")
                continue
            }
            if linea.texto.hasPrefix(etiqueta) {
                let resto = String(linea.texto.dropFirst(etiqueta.count)).trimmingCharacters(in: .whitespaces)
                if resto.uppercased().hasPrefix("OK") { return }
                throw FalloIMAP.credencialCaducada
            }
        }
    }

    func salir() async {
        _ = try? await ejecutar("LOGOUT")
        await conexion.cerrar()
        abierto = false
    }

    // MARK: - Buzón

    struct Buzon {
        var nombre: String
        var existen: Int
        var uidValidity: UInt32
        var uidNext: UInt32
    }

    @discardableResult
    func seleccionar(_ nombre: String) async throws -> Buzon {
        let respuesta = try await ejecutar("SELECT \(Self.entrecomillar(nombre))")
        var existen = 0
        var validez: UInt32 = 0
        var siguiente: UInt32 = 0
        for linea in respuesta.untagged {
            let texto = linea.texto
            if let n = Self.entero(en: texto, patron: #"\* (\d+) EXISTS"#) { existen = Int(n) }
            if let n = Self.entero(en: texto, patron: #"UIDVALIDITY (\d+)"#) { validez = n }
            if let n = Self.entero(en: texto, patron: #"UIDNEXT (\d+)"#) { siguiente = n }
        }
        return Buzon(nombre: nombre, existen: existen, uidValidity: validez, uidNext: siguiente)
    }

    /// Devuelve los UID de los mensajes recibidos desde una fecha.
    func buscarDesde(_ fecha: Date) async throws -> [UInt32] {
        let formato = DateFormatter()
        formato.locale = Locale(identifier: "en_US_POSIX")
        formato.dateFormat = "d-MMM-yyyy"
        let respuesta = try await ejecutar("UID SEARCH SINCE \(formato.string(from: fecha))")
        for linea in respuesta.untagged where linea.texto.uppercased().hasPrefix("* SEARCH") {
            return linea.texto
                .dropFirst("* SEARCH".count)
                .split(separator: " ")
                .compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
        }
        return []
    }

    /// Trae el código fuente completo de los mensajes indicados, sin marcarlos
    /// como leídos: SinMail no gestiona el estado de lectura.
    func traer(uids: [UInt32]) async throws -> [(uid: UInt32, fuente: Data)] {
        guard !uids.isEmpty else { return [] }
        var salida: [(uid: UInt32, fuente: Data)] = []

        for lote in uids.trozos(de: 25) {
            let conjunto = lote.map(String.init).joined(separator: ",")
            let respuesta = try await ejecutar("UID FETCH \(conjunto) (UID BODY.PEEK[])")
            for linea in respuesta.untagged {
                guard linea.texto.uppercased().contains("FETCH"),
                      let uid = Self.entero(en: linea.texto, patron: #"UID (\d+)"#),
                      let fuente = linea.literales.last else { continue }
                salida.append((uid, fuente))
            }
        }
        return salida
    }

    /// Deja el mensaje en el buzón de enviados, si el servidor tiene uno.
    func guardarEnEnviados(_ fuente: Data, buzon: String) async throws {
        let etiqueta = siguienteEtiqueta()
        try await conexion.enviarLinea(
            "\(etiqueta) APPEND \(Self.entrecomillar(buzon)) (\\Seen) {\(fuente.count)}"
        )
        let continuar = try await leerLinea()
        guard continuar.texto.hasPrefix("+") else { throw FalloIMAP.rechazado(continuar.texto) }
        try await conexion.enviar(fuente)
        try await conexion.enviar("\r\n")
        _ = try await esperarEtiqueta(etiqueta)
    }

    /// Lista los buzones para localizar el de enviados.
    func buzonDeEnviados() async throws -> String? {
        let respuesta = try await ejecutar(#"LIST "" "*""#)
        var candidatos: [String] = []
        for linea in respuesta.untagged where linea.texto.uppercased().hasPrefix("* LIST") {
            if linea.texto.contains("\\Sent") {
                if let nombre = Self.ultimoEntrecomillado(linea.texto) { return nombre }
            }
            if let nombre = Self.ultimoEntrecomillado(linea.texto) { candidatos.append(nombre) }
        }
        return candidatos.first { nombre in
            let n = nombre.lowercased()
            return n.contains("sent") || n.contains("enviado")
        }
    }

    // MARK: - IDLE

    /// Espera a que el servidor avise de correo nuevo. Devuelve cuando algo cambia
    /// o cuando vence el plazo, lo que ocurra antes.
    func esperarNovedades(hasta segundos: TimeInterval = 240) async throws -> Bool {
        guard capacidades.contains("IDLE") else {
            try await Task.sleep(nanoseconds: UInt64(segundos * 1_000_000_000))
            return true
        }

        // Durante IDLE el silencio es lo normal: se alarga el plazo de lectura para
        // que no se confunda con una conexión caída.
        await conexion.fijarPlazoDeLectura(segundos + 15)
        defer { Task { await conexion.fijarPlazoDeLectura(45) } }

        let etiqueta = siguienteEtiqueta()
        try await conexion.enviarLinea("\(etiqueta) IDLE")
        let continuar = try await leerLinea()
        guard continuar.texto.hasPrefix("+") else { throw FalloIMAP.rechazado(continuar.texto) }

        var novedad = false
        let limite = Date().addingTimeInterval(segundos)
        do {
            while Date() < limite {
                let linea = try await leerLinea()
                let t = linea.texto.uppercased()
                if t.contains("EXISTS") || t.contains("EXPUNGE") || t.contains("RECENT") {
                    novedad = true
                    break
                }
            }
        } catch FalloConexion.tiempoAgotado {
            // Silencio hasta que venció el plazo: no hay novedades.
            novedad = false
        }

        try await conexion.enviarLinea("DONE")
        _ = try? await esperarEtiqueta(etiqueta)
        return novedad
    }

    // MARK: - Motor de órdenes

    struct RespuestaIMAP {
        var untagged: [LineaIMAP]
        var final: String
    }

    @discardableResult
    private func ejecutar(_ orden: String) async throws -> RespuestaIMAP {
        let etiqueta = siguienteEtiqueta()
        try await conexion.enviarLinea("\(etiqueta) \(orden)")
        return try await esperarEtiqueta(etiqueta)
    }

    private func esperarEtiqueta(_ etiqueta: String) async throws -> RespuestaIMAP {
        var untagged: [LineaIMAP] = []
        while true {
            let linea = try await leerLinea()
            if linea.texto.hasPrefix(etiqueta + " ") {
                let resto = String(linea.texto.dropFirst(etiqueta.count + 1))
                let mayus = resto.uppercased()
                if mayus.hasPrefix("OK") {
                    return RespuestaIMAP(untagged: untagged, final: resto)
                }
                throw FalloIMAP.rechazado(resto)
            }
            untagged.append(linea)
        }
    }

    /// Lee una línea resolviendo los literales `{n}` que aparezcan en ella.
    private func leerLinea() async throws -> LineaIMAP {
        var texto = try await conexion.leerLinea()
        var literales: [Data] = []

        while let cantidad = Self.literalPendiente(en: texto) {
            let datos = try await conexion.leerBytes(cantidad)
            literales.append(datos)
            let continuacion = try await conexion.leerLinea()
            texto += " " + continuacion
        }
        return LineaIMAP(texto: texto, literales: literales)
    }

    /// Detecta `{123}` o `{123+}` al final de una línea.
    private static func literalPendiente(en texto: String) -> Int? {
        guard texto.hasSuffix("}") else { return nil }
        guard let apertura = texto.lastIndex(of: "{") else { return nil }
        let interior = texto[texto.index(after: apertura)..<texto.index(before: texto.endIndex)]
        return Int(interior.replacingOccurrences(of: "+", with: ""))
    }

    private func siguienteEtiqueta() -> String {
        contador += 1
        return String(format: "a%04d", contador)
    }

    // MARK: - Utilidades de texto

    private static func entrecomillar(_ valor: String) -> String {
        let escapado = valor
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapado)\""
    }

    private static func entero(en texto: String, patron: String) -> UInt32? {
        guard let regex = try? NSRegularExpression(pattern: patron, options: .caseInsensitive),
              let coincidencia = regex.firstMatch(
                in: texto,
                range: NSRange(texto.startIndex..., in: texto)
              ),
              let rango = Range(coincidencia.range(at: 1), in: texto)
        else { return nil }
        return UInt32(texto[rango])
    }

    private static func ultimoEntrecomillado(_ texto: String) -> String? {
        let piezas = texto.components(separatedBy: "\"")
        guard piezas.count >= 2 else { return nil }
        return piezas[piezas.count - 2]
    }
}

extension Array {
    func trozos(de tamano: Int) -> [[Element]] {
        guard tamano > 0 else { return [self] }
        return stride(from: 0, to: count, by: tamano).map {
            Array(self[$0..<Swift.min($0 + tamano, count)])
        }
    }
}
