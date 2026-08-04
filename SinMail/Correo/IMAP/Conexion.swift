import Foundation

enum FalloConexion: LocalizedError {
    case cerrada
    case tiempoAgotado
    case noSeAbre
    case red(Error)
    case protocoloInesperado(String)

    var errorDescription: String? {
        switch self {
        case .cerrada: return "La conexión con el servidor se cerró."
        case .tiempoAgotado: return "El servidor no respondió a tiempo."
        case .noSeAbre: return "No se pudo abrir la conexión con el servidor."
        case .red(let error): return error.localizedDescription
        case .protocoloInesperado(let texto): return texto
        }
    }
}

/// Par de flujos sobre un socket, en modo bloqueante.
///
/// Se usan `CFStream` y no `NWConnection` por una razón concreta: STARTTLS. SMTP
/// en el puerto 587 empieza en claro y sube a TLS sobre la misma conexión, y
/// `NWConnection` no sabe hacer eso. `CFStream` sí: basta con fijar el nivel de
/// seguridad del flujo ya abierto.
final class Socket: @unchecked Sendable {

    private let entrada: InputStream
    private let salida: OutputStream

    init?(host: String, puerto: UInt16) {
        var lectura: Unmanaged<CFReadStream>?
        var escritura: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(
            kCFAllocatorDefault,
            host as CFString,
            UInt32(puerto),
            &lectura,
            &escritura
        )
        guard let i = lectura?.takeRetainedValue() as InputStream?,
              let o = escritura?.takeRetainedValue() as OutputStream? else { return nil }
        self.entrada = i
        self.salida = o
    }

    /// Abre el socket. Los flujos no se registran en ningún run loop, así que
    /// trabajan en modo bloqueante y se manejan desde una cola propia.
    func abrir(tls: Bool, plazo: TimeInterval = 20) throws {
        if tls { activarTLS() }
        entrada.open()
        salida.open()

        let limite = Date().addingTimeInterval(plazo)
        while Date() < limite {
            if entrada.streamStatus == .error || salida.streamStatus == .error {
                throw FalloConexion.red(entrada.streamError ?? salida.streamError ?? FalloConexion.noSeAbre)
            }
            if entrada.streamStatus.rawValue >= Stream.Status.open.rawValue,
               salida.streamStatus.rawValue >= Stream.Status.open.rawValue {
                fijarPlazoDeLectura(45)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw FalloConexion.tiempoAgotado
    }

    /// Sube a TLS. Sobre un flujo ya abierto es exactamente lo que pide STARTTLS.
    ///
    /// El certificado se valida contra el nombre con el que se creó el par, así
    /// que no hay ninguna comprobación que relajar.
    func activarTLS() {
        let nivel = StreamSocketSecurityLevel.negotiatedSSL.rawValue
        entrada.setProperty(nivel, forKey: .socketSecurityLevelKey)
        salida.setProperty(nivel, forKey: .socketSecurityLevelKey)
    }

    /// Ajusta cuánto espera una lectura antes de rendirse.
    func fijarPlazoDeLectura(_ segundos: TimeInterval) {
        let clave = Stream.PropertyKey(kCFStreamPropertySocketNativeHandle as String)
        guard let datos = entrada.property(forKey: clave) as? Data,
              datos.count >= MemoryLayout<CFSocketNativeHandle>.size else { return }

        let descriptor = datos.withUnsafeBytes { $0.load(as: CFSocketNativeHandle.self) }
        var plazo = timeval(
            tv_sec: Int(segundos),
            tv_usec: Int32((segundos - floor(segundos)) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &plazo, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Lectura bloqueante. Devuelve vacío cuando el otro extremo cierra.
    func leer(_ maximo: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximo)
        let leidos = entrada.read(&bytes, maxLength: maximo)

        if leidos > 0 { return Data(bytes[0..<leidos]) }
        if leidos == 0 { return Data() }

        if let error = entrada.streamError as NSError?,
           error.domain == NSPOSIXErrorDomain,
           error.code == Int(EAGAIN) || error.code == Int(EWOULDBLOCK) {
            throw FalloConexion.tiempoAgotado
        }
        throw FalloConexion.red(entrada.streamError ?? FalloConexion.cerrada)
    }

    func escribir(_ datos: Data) throws {
        var restante = datos
        while !restante.isEmpty {
            // El tamaño se lee antes: tocar `restante` dentro de su propio
            // `withUnsafeBytes` es un acceso solapado y salta en ejecución.
            let cuantos = restante.count
            let escritos = restante.withUnsafeBytes { puntero -> Int in
                guard let base = puntero.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return salida.write(base, maxLength: cuantos)
            }
            guard escritos > 0 else {
                throw FalloConexion.red(salida.streamError ?? FalloConexion.cerrada)
            }
            restante.removeFirst(escritos)
        }
    }

    func cerrar() {
        entrada.close()
        salida.close()
    }
}

/// Conexión de texto sobre el socket, con un búfer que permite leer líneas
/// terminadas en CRLF o un número exacto de bytes (los literales de IMAP).
actor Conexion {

    private let host: String
    private let puerto: UInt16
    private var socket: Socket?
    private var buffer = Data()
    private var terminada = false

    /// Las lecturas y escrituras bloquean, así que viven en una cola propia y
    /// nunca en el grupo cooperativo de Swift.
    private let cola: DispatchQueue

    init(host: String, puerto: UInt16, tls: Bool) {
        self.host = host
        self.puerto = puerto
        self.tlsInicial = tls
        self.cola = DispatchQueue(label: "app.sinmail.socket.\(host):\(puerto)")
    }

    private let tlsInicial: Bool

    func abrir() async throws {
        guard let socket = Socket(host: host, puerto: puerto) else {
            throw FalloConexion.noSeAbre
        }
        let tls = tlsInicial
        try await enCola { try socket.abrir(tls: tls) }
        self.socket = socket
        terminada = false
    }

    /// Sube la conexión ya abierta a TLS, como pide STARTTLS.
    func ascenderATLS() async throws {
        guard let socket else { throw FalloConexion.cerrada }
        try await enCola { socket.activarTLS() }
        // Lo que quedara en el búfer es de antes del cifrado y no vale.
        buffer.removeAll()
    }

    /// IDLE espera mucho más que una orden normal.
    func fijarPlazoDeLectura(_ segundos: TimeInterval) async {
        guard let socket else { return }
        try? await enCola { socket.fijarPlazoDeLectura(segundos) }
    }

    func cerrar() {
        socket?.cerrar()
        socket = nil
        terminada = true
    }

    // MARK: - Escritura

    func enviarLinea(_ texto: String) async throws {
        try await enviar(Data((texto + "\r\n").utf8))
    }

    func enviar(_ texto: String) async throws {
        try await enviar(Data(texto.utf8))
    }

    func enviar(_ datos: Data) async throws {
        guard let socket else { throw FalloConexion.cerrada }
        try await enCola { try socket.escribir(datos) }
    }

    // MARK: - Lectura

    /// Lee una línea completa, sin el CRLF final.
    func leerLinea() async throws -> String {
        while true {
            if let corte = buffer.firstRange(of: Data([0x0D, 0x0A])) {
                let linea = buffer.subdata(in: buffer.startIndex..<corte.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<corte.upperBound)
                return String(decoding: linea, as: UTF8.self)
            }
            try await rellenar()
        }
    }

    /// Lee exactamente `cantidad` bytes. Los literales de IMAP los necesitan.
    func leerBytes(_ cantidad: Int) async throws -> Data {
        while buffer.count < cantidad {
            try await rellenar()
        }
        let trozo = buffer.prefix(cantidad)
        buffer.removeFirst(cantidad)
        return Data(trozo)
    }

    private func rellenar() async throws {
        guard let socket, !terminada else { throw FalloConexion.cerrada }
        let datos = try await enCola { try socket.leer(64 * 1024) }
        guard !datos.isEmpty else {
            terminada = true
            throw FalloConexion.cerrada
        }
        buffer.append(datos)
    }

    // MARK: - Puente con la cola bloqueante

    private func enCola<T: Sendable>(_ trabajo: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuacion in
            cola.async {
                do {
                    continuacion.resume(returning: try trabajo())
                } catch {
                    continuacion.resume(throwing: error)
                }
            }
        }
    }
}
