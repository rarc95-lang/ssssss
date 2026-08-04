import Foundation

/// Guarda los asuntos en disco y avisa a quien los muestra. La copia local es la
/// fuente de verdad para la interfaz; CloudKit la replica entre dispositivos.
actor AlmacenAsuntos {

    static let shared = AlmacenAsuntos()

    private var asuntos: [UUID: Asunto] = [:]
    private var hilosPorID: [String: Hilo] = [:]
    private var cargado = false
    private var observadores: [UUID: @Sendable ([Asunto]) -> Void] = [:]

    private var archivoAsuntos: URL {
        let carpeta = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SinMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        return carpeta.appendingPathComponent("asuntos.json")
    }

    private var archivoHilos: URL {
        archivoAsuntos.deletingLastPathComponent().appendingPathComponent("hilos.json")
    }

    // MARK: - Carga

    func cargar() {
        guard !cargado else { return }
        cargado = true

        if let datos = try? Data(contentsOf: archivoAsuntos),
           let lista = try? JSONDecoder().decode([Asunto].self, from: datos) {
            asuntos = Dictionary(uniqueKeysWithValues: lista.map { ($0.id, $0) })
        }
        if let datos = try? Data(contentsOf: archivoHilos),
           let lista = try? JSONDecoder().decode([Hilo].self, from: datos) {
            hilosPorID = Dictionary(uniqueKeysWithValues: lista.map { ($0.id, $0) })
        }
    }

    // MARK: - Lectura

    func todos() -> [Asunto] {
        cargar()
        return Array(asuntos.values)
    }

    func asunto(_ id: UUID) -> Asunto? {
        cargar()
        return asuntos[id]
    }

    func hilo(_ id: String) -> Hilo? {
        cargar()
        return hilosPorID[id]
    }

    func hilos(de asunto: Asunto) -> [Hilo] {
        cargar()
        return asunto.hilos.compactMap { hilosPorID[$0] }.sorted { $0.fecha < $1.fecha }
    }

    /// Busca un asunto que ya cubra alguno de estos hilos, para actualizarlo en vez
    /// de crear una fila nueva.
    func existente(paraHilos ids: [String], cuenta: String) -> Asunto? {
        cargar()
        return asuntos.values.first { asunto in
            asunto.cuentaID == cuenta && !Set(asunto.hilos).isDisjoint(with: Set(ids))
        }
    }

    // MARK: - Escritura

    func guardar(_ asunto: Asunto, replicar: Bool = true) {
        cargar()
        asuntos[asunto.id] = asunto
        persistir()
        avisar()
        if replicar { SincronizacionCloudKit.shared.enviar(asunto) }
    }

    func guardar(_ lista: [Asunto], replicar: Bool = true) {
        cargar()
        for asunto in lista { asuntos[asunto.id] = asunto }
        persistir()
        avisar()
        if replicar {
            for asunto in lista { SincronizacionCloudKit.shared.enviar(asunto) }
        }
    }

    func borrar(_ id: UUID, replicar: Bool = true) {
        cargar()
        asuntos.removeValue(forKey: id)
        persistir()
        avisar()
        if replicar { SincronizacionCloudKit.shared.borrar(id) }
    }

    func guardarHilos(_ lista: [Hilo]) {
        cargar()
        for hilo in lista { hilosPorID[hilo.id] = hilo }
        // Los hilos son caché local y no salen del dispositivo: no se replican.
        persistir()
    }

    /// Aplica un cambio llegado de otro dispositivo. No se vuelve a replicar.
    func aplicarDeLaNube(_ asunto: Asunto) {
        cargar()
        if let actual = asuntos[asunto.id], actual.actualizado > asunto.actualizado { return }
        asuntos[asunto.id] = asunto
        persistir()
        avisar()
    }

    func borrarDeLaNube(_ id: UUID) {
        cargar()
        asuntos.removeValue(forKey: id)
        persistir()
        avisar()
    }

    // MARK: - Observación

    func observar(_ bloque: @escaping @Sendable ([Asunto]) -> Void) -> UUID {
        cargar()
        let id = UUID()
        observadores[id] = bloque
        bloque(Array(asuntos.values))
        return id
    }

    func dejarDeObservar(_ id: UUID) {
        observadores.removeValue(forKey: id)
    }

    private func avisar() {
        let instantanea = Array(asuntos.values)
        for bloque in observadores.values { bloque(instantanea) }
    }

    private func persistir() {
        let codificador = JSONEncoder()
        if let datos = try? codificador.encode(Array(asuntos.values)) {
            try? datos.write(to: archivoAsuntos, options: .atomic)
        }
        // Sólo se conserva la caché de hilos recientes, para no crecer sin límite.
        let recientes = hilosPorID.values
            .sorted { $0.fecha > $1.fecha }
            .prefix(300)
        if let datos = try? codificador.encode(Array(recientes)) {
            try? datos.write(to: archivoHilos, options: .atomic)
        }
    }
}
