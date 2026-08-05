import CloudKit
import Foundation

/// Replica los asuntos entre los dispositivos del usuario usando su base privada
/// de CloudKit.
///
/// Sólo viajan los asuntos: título, estado, situación, falta, acción y la cita.
/// Los mensajes no salen del dispositivo, y no hay ningún servidor de SinMail
/// por el que pueda pasar el correo.
final class SincronizacionCloudKit: @unchecked Sendable {

    static let shared = SincronizacionCloudKit()

    static let tipoRegistro = "Asunto"
    private let contenedor = CKContainer(identifier: "iCloud.app.sinmail")
    private var baseDatos: CKDatabase { contenedor.privateCloudDatabase }
    private let zona = CKRecordZone(zoneName: "Asuntos")

    private var listaDeEnvio: [CKRecord] = []
    private var listaDeBorrado: [CKRecord.ID] = []
    private let cola = DispatchQueue(label: "app.sinmail.cloudkit")
    private var vaciadoProgramado = false
    private var zonaLista = false
    private var tokenDeCambios: CKServerChangeToken?

    private var archivoToken: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SinMail/token-cloudkit.dat")
    }

    // MARK: - Arranque

    func arrancar() {
        cargarToken()
        prepararZona { [weak self] in
            self?.suscribir()
            self?.recibirCambios()
        }
    }

    private func prepararZona(_ despues: @escaping () -> Void) {
        guard !zonaLista else { despues(); return }
        let operacion = CKModifyRecordZonesOperation(recordZonesToSave: [zona])
        operacion.modifyRecordZonesResultBlock = { [weak self] resultado in
            if case .success = resultado { self?.zonaLista = true }
            despues()
        }
        baseDatos.add(operacion)
    }

    private func suscribir() {
        let suscripcion = CKRecordZoneSubscription(zoneID: zona.zoneID, subscriptionID: "asuntos-zona")
        let aviso = CKSubscription.NotificationInfo()
        aviso.shouldSendContentAvailable = true
        suscripcion.notificationInfo = aviso

        let operacion = CKModifySubscriptionsOperation(subscriptionsToSave: [suscripcion])
        operacion.qualityOfService = .utility
        baseDatos.add(operacion)
    }

    // MARK: - Salida

    func enviar(_ asunto: Asunto) {
        cola.async { [weak self] in
            guard let self else { return }
            listaDeEnvio.removeAll { $0.recordID == Self.identificador(asunto.id) }
            listaDeEnvio.append(Self.registro(de: asunto, zona: zona.zoneID))
            programarVaciado()
        }
    }

    func borrar(_ id: UUID) {
        cola.async { [weak self] in
            guard let self else { return }
            listaDeBorrado.append(Self.identificador(id, zona: zona.zoneID))
            programarVaciado()
        }
    }

    private func programarVaciado() {
        guard !vaciadoProgramado else { return }
        vaciadoProgramado = true
        cola.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.vaciar()
        }
    }

    private func vaciar() {
        vaciadoProgramado = false
        let registros = listaDeEnvio
        let borrados = listaDeBorrado
        listaDeEnvio.removeAll()
        listaDeBorrado.removeAll()
        guard !registros.isEmpty || !borrados.isEmpty else { return }

        prepararZona { [weak self] in
            guard let self else { return }
            let operacion = CKModifyRecordsOperation(
                recordsToSave: registros,
                recordIDsToDelete: borrados
            )
            operacion.savePolicy = .changedKeys
            operacion.qualityOfService = .userInitiated
            operacion.modifyRecordsResultBlock = { resultado in
                if case .failure = resultado {
                    // Se reintenta en el siguiente ciclo; el disco ya tiene el dato.
                    self.cola.async {
                        self.listaDeEnvio.append(contentsOf: registros)
                        self.listaDeBorrado.append(contentsOf: borrados)
                    }
                }
            }
            baseDatos.add(operacion)
        }
    }

    // MARK: - Entrada

    func recibirCambios() {
        prepararZona { [weak self] in
            guard let self else { return }
            let configuracion = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuracion.previousServerChangeToken = tokenDeCambios

            let operacion = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zona.zoneID],
                configurationsByRecordZoneID: [zona.zoneID: configuracion]
            )

            operacion.recordWasChangedBlock = { _, resultado in
                guard case .success(let registro) = resultado,
                      let asunto = Self.asunto(de: registro) else { return }
                Task { await AlmacenAsuntos.shared.aplicarDeLaNube(asunto) }
            }

            operacion.recordWithIDWasDeletedBlock = { id, _ in
                guard let uuid = UUID(uuidString: id.recordName) else { return }
                Task { await AlmacenAsuntos.shared.borrarDeLaNube(uuid) }
            }

            operacion.recordZoneFetchResultBlock = { _, resultado in
                if case .success(let datos) = resultado {
                    self.guardarToken(datos.serverChangeToken)
                }
            }
            operacion.qualityOfService = .userInitiated
            baseDatos.add(operacion)
        }
    }

    // MARK: - Conversión

    static func identificador(_ id: UUID, zona: CKRecordZone.ID? = nil) -> CKRecord.ID {
        if let zona { return CKRecord.ID(recordName: id.uuidString, zoneID: zona) }
        return CKRecord.ID(recordName: id.uuidString)
    }

    static func registro(de asunto: Asunto, zona: CKRecordZone.ID) -> CKRecord {
        let registro = CKRecord(recordType: tipoRegistro, recordID: identificador(asunto.id, zona: zona))
        registro["titulo"] = asunto.titulo as NSString
        registro["estado"] = asunto.estado.rawValue as NSString
        registro["responsable"] = asunto.responsable as NSString
        registro["situacion"] = asunto.situacion as NSString
        registro["falta"] = asunto.falta as NSString
        registro["accion"] = asunto.accion as NSString
        registro["cita"] = asunto.cita as NSString
        registro["confianza"] = NSNumber(value: asunto.confianza)
        registro["hilos"] = asunto.hilos as NSArray
        registro["cuentaID"] = asunto.cuentaID as NSString
        registro["borrador"] = asunto.borrador as NSString
        registro["destinatarios"] = asunto.destinatarios as NSArray
        registro["asuntoDelCorreo"] = asunto.asuntoDelCorreo as NSString
        registro["cierreSugerido"] = NSNumber(value: asunto.cierreSugerido)
        registro["creado"] = asunto.creado as NSDate
        registro["actualizado"] = asunto.actualizado as NSDate
        registro["ultimoMovimiento"] = asunto.ultimoMovimiento as NSDate
        if let mensaje = asunto.mensajeDeLaCita { registro["mensajeDeLaCita"] = mensaje as NSString }
        if let recordatorio = asunto.recordatorio { registro["recordatorio"] = recordatorio as NSDate }
        return registro
    }

    static func asunto(de registro: CKRecord) -> Asunto? {
        guard
            let id = UUID(uuidString: registro.recordID.recordName),
            let titulo = registro["titulo"] as? String,
            let estadoBruto = registro["estado"] as? String,
            let estado = Estado(rawValue: estadoBruto)
        else { return nil }

        return Asunto(
            id: id,
            titulo: titulo,
            estado: estado,
            responsable: registro["responsable"] as? String ?? "",
            situacion: registro["situacion"] as? String ?? "",
            falta: registro["falta"] as? String ?? "",
            accion: registro["accion"] as? String ?? "",
            cita: registro["cita"] as? String ?? "",
            confianza: registro["confianza"] as? Double ?? 0,
            hilos: registro["hilos"] as? [String] ?? [],
            cuentaID: registro["cuentaID"] as? String ?? "",
            mensajeDeLaCita: registro["mensajeDeLaCita"] as? String,
            borrador: registro["borrador"] as? String ?? "",
            destinatarios: registro["destinatarios"] as? [String] ?? [],
            asuntoDelCorreo: registro["asuntoDelCorreo"] as? String ?? "",
            cierreSugerido: (registro["cierreSugerido"] as? Int ?? 0) != 0,
            recordatorio: registro["recordatorio"] as? Date,
            creado: registro["creado"] as? Date ?? Date(),
            actualizado: registro["actualizado"] as? Date ?? Date(),
            ultimoMovimiento: registro["ultimoMovimiento"] as? Date ?? Date()
        )
    }

    // MARK: - Token

    private func cargarToken() {
        guard let datos = try? Data(contentsOf: archivoToken) else { return }
        tokenDeCambios = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: datos
        )
    }

    private func guardarToken(_ token: CKServerChangeToken?) {
        tokenDeCambios = token
        guard let token,
              let datos = try? NSKeyedArchiver.archivedData(
                withRootObject: token,
                requiringSecureCoding: true
              ) else { return }
        try? datos.write(to: archivoToken, options: .atomic)
    }
}
