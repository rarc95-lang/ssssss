import Foundation
import SwiftUI

/// El estado de la bandeja.
///
/// Mantiene un orden estable: al llegar correo nuevo no aparece una fila, cambia
/// el estado de una tarjeta que ya está ahí. Reagrupar es una operación explícita
/// (al abrir la app o al tirar para actualizar), nunca un efecto secundario de que
/// llegue un mensaje, porque la tarjeta no debe viajar bajo el dedo del usuario.
@MainActor
final class ModeloBandeja: ObservableObject {

    @Published private(set) var asuntos: [Asunto] = []
    @Published private(set) var sincronizando = false
    @Published var aviso: String?

    private var orden: [UUID] = []
    private var observador: UUID?
    private var vigilancia: Task<Void, Never>?

    private let gestor = GestorCuentas.shared

    // MARK: - Encabezado

    /// Una línea, sin contador de no leídos.
    var linea: String {
        let tuyos = asuntos.filter { $0.estado == .tuyo }.count
        switch tuyos {
        case 0:
            let esperando = asuntos.filter { $0.estado == .esperando }.count
            if esperando == 0 { return "Nada pendiente" }
            return esperando == 1 ? "1 asunto en espera" : "\(esperando) asuntos en espera"
        case 1:
            return "1 asunto tuyo"
        default:
            return "\(tuyos) asuntos tuyos"
        }
    }

    var vacia: Bool { asuntos.isEmpty }

    // MARK: - Ciclo de vida

    func arrancar() async {
        if observador == nil {
            observador = await AlmacenAsuntos.shared.observar { [weak self] lista in
                Task { @MainActor in self?.recibir(lista) }
            }
        }
        SincronizacionCloudKit.shared.arrancar()
        reagrupar()
        await sincronizar()
        vigilar()
    }

    func detener() {
        vigilancia?.cancel()
        vigilancia = nil
    }

    private func recibir(_ lista: [Asunto]) {
        // Los cambios de contenido se funden en su sitio; el orden no se toca.
        withAnimation(Tokens.Movimiento.fundido) {
            asuntos = ordenar(lista)
        }
    }

    /// Recalcula el orden por grupos. Sin animación de posición: la tarjeta no viaja.
    func reagrupar() {
        var lista = asuntos
        lista.sort { izquierda, derecha in
            if izquierda.estado.orden != derecha.estado.orden {
                return izquierda.estado.orden < derecha.estado.orden
            }
            return izquierda.ultimoMovimiento > derecha.ultimoMovimiento
        }
        orden = lista.map(\.id)
        var transaccion = Transaction()
        transaccion.disablesAnimations = true
        withTransaction(transaccion) { asuntos = lista }
    }

    private func ordenar(_ lista: [Asunto]) -> [Asunto] {
        let porID = Dictionary(uniqueKeysWithValues: lista.map { ($0.id, $0) })
        var salida = orden.compactMap { porID[$0] }

        // Lo que no estaba se coloca al final de su grupo, sin desplazar nada.
        let conocidos = Set(orden)
        let nuevos = lista.filter { !conocidos.contains($0.id) }
        for nuevo in nuevos.sorted(by: { $0.ultimoMovimiento > $1.ultimoMovimiento }) {
            let posicion = salida.lastIndex { $0.estado.orden <= nuevo.estado.orden }
            salida.insert(nuevo, at: posicion.map { $0 + 1 } ?? 0)
        }
        orden = salida.map(\.id)
        return salida
    }

    // MARK: - Sincronización

    func sincronizar() async {
        guard !sincronizando, !gestor.cuentas.isEmpty else { return }
        sincronizando = true
        defer { sincronizando = false }

        let motor: MotorAnalisis
        if let clave = ClaveModelo.leer() {
            motor = MotorClaude(clave: clave)
        } else {
            motor = MotorHeuristico()
        }

        for cuenta in gestor.cuentas {
            do {
                let desde = cuenta.sincronizadoHasta ?? Calendar.current.date(
                    byAdding: .day, value: -21, to: Date()
                )!
                let hilos = try await ServicioCorreo.shared.hilos(de: cuenta, desde: desde)
                guard !hilos.isEmpty else {
                    gestor.marcarSincronizada(cuenta, hasta: Date())
                    continue
                }
                await AlmacenAsuntos.shared.guardarHilos(hilos)
                await procesar(hilos: hilos, cuenta: cuenta, motor: motor)
                gestor.marcarSincronizada(cuenta, hasta: Date())
            } catch {
                aviso = error.localizedDescription
            }
        }
        SincronizacionCloudKit.shared.recibirCambios()
    }

    private func procesar(hilos: [Hilo], cuenta: Cuenta, motor: MotorAnalisis) async {
        let reserva = MotorHeuristico()

        for hilo in hilos {
            let anterior = await AlmacenAsuntos.shared.existente(
                paraHilos: [hilo.id],
                cuenta: cuenta.id
            )

            // Si nada se ha movido desde la última vez, no se vuelve a analizar.
            if let anterior, anterior.ultimoMovimiento >= hilo.fecha { continue }

            var propuestas: [AsuntoPropuesto]
            do {
                propuestas = try await motor.analizar(hilo: hilo, identidad: cuenta.identidad)
            } catch {
                propuestas = (try? await reserva.analizar(hilo: hilo, identidad: cuenta.identidad)) ?? []
            }
            // Ante la duda, un hilo es un asunto.
            if propuestas.isEmpty {
                propuestas = (try? await reserva.analizar(hilo: hilo, identidad: cuenta.identidad)) ?? []
            }

            var actualizados: [Asunto] = []
            for (indice, propuesta) in propuestas.enumerated() {
                // Sólo la primera propuesta hereda el asunto anterior; si el modelo
                // parte el hilo en dos, la segunda es un asunto nuevo.
                let base = indice == 0 ? anterior : nil
                var asunto = ValidadorAsunto.validar(
                    propuesta,
                    hilo: hilo,
                    cuenta: cuenta,
                    anterior: base
                )
                asunto.borrador = RedactorBorrador.redactar(
                    asunto: asunto,
                    hilo: hilo,
                    identidad: cuenta.identidad
                )
                actualizados.append(asunto)
            }
            await AlmacenAsuntos.shared.guardar(actualizados)
        }
    }

    /// Se queda a la escucha con IDLE. Cuando llega correo, se vuelve a analizar y
    /// las tarjetas cambian de estado donde están.
    private func vigilar() {
        vigilancia?.cancel()
        let cuentas = gestor.cuentas
        guard !cuentas.isEmpty else { return }

        vigilancia = Task { [weak self] in
            while !Task.isCancelled {
                for cuenta in cuentas {
                    guard !Task.isCancelled else { return }
                    let hayNovedades = (try? await ServicioCorreo.shared.esperarNovedades(en: cuenta)) ?? false
                    if hayNovedades {
                        await self?.sincronizar()
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: - Acciones sobre una tarjeta

    /// El cierre lo confirma el usuario. Nunca el sistema.
    func cerrar(_ asunto: Asunto) {
        var copia = asunto
        copia.estado = .cerrado
        copia.cierreSugerido = false
        copia.actualizado = Date()
        Task { await AlmacenAsuntos.shared.guardar(copia) }
    }

    func recordar(_ asunto: Asunto, dentro intervalo: TimeInterval = 60 * 60 * 24 * 2) {
        var copia = asunto
        copia.recordatorio = Date().addingTimeInterval(intervalo)
        copia.actualizado = Date()
        Task { await AlmacenAsuntos.shared.guardar(copia) }
    }

    func guardarBorrador(_ texto: String, en asunto: Asunto) {
        var copia = asunto
        copia.borrador = texto
        copia.actualizado = Date()
        Task { await AlmacenAsuntos.shared.guardar(copia) }
    }

    /// Envía de verdad, con el texto que el usuario ha visto y tocado.
    func enviar(_ texto: String, de asunto: Asunto) async throws {
        guard let cuenta = gestor.cuenta(asunto.cuentaID) else {
            throw FalloSMTP.rechazado(codigo: 0, texto: "La cuenta ya no está conectada.")
        }
        let hilos = await AlmacenAsuntos.shared.hilos(de: asunto)
        let original = hilos.last?.ultimoAjeno ?? hilos.last?.ultimo

        try await ServicioCorreo.shared.enviar(
            borrador: texto,
            asunto: asunto,
            cuenta: cuenta,
            respondiendoA: original
        )

        // Enviado: la pelota pasa a la otra parte.
        var copia = asunto
        copia.estado = .esperando
        copia.responsable = original?.de.visible ?? copia.responsable
        copia.situacion = "Enviado, a la espera de respuesta"
        copia.falta = "Su respuesta"
        copia.accion = "Recordar el envío"
        copia.borrador = ""
        copia.actualizado = Date()
        copia.ultimoMovimiento = Date()
        await AlmacenAsuntos.shared.guardar(copia)
    }

    func hilos(de asunto: Asunto) async -> [Hilo] {
        await AlmacenAsuntos.shared.hilos(de: asunto)
    }
}
