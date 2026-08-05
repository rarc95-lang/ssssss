import Foundation

/// Cuentas conectadas. Los datos de servidor van a disco; las credenciales, al
/// llavero.
@MainActor
final class GestorCuentas: ObservableObject {

    static let shared = GestorCuentas()

    @Published private(set) var cuentas: [Cuenta] = []

    private var archivo: URL {
        let carpeta = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SinMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        return carpeta.appendingPathComponent("cuentas.json")
    }

    init() {
        cargar()
    }

    private func cargar() {
        guard let datos = try? Data(contentsOf: archivo),
              let lista = try? JSONDecoder().decode([Cuenta].self, from: datos) else { return }
        cuentas = lista
    }

    private func persistir() {
        guard let datos = try? JSONEncoder().encode(cuentas) else { return }
        try? datos.write(to: archivo, options: .atomic)
    }

    // MARK: - Alta

    /// Da de alta Gmail u Outlook por OAuth.
    func conectarConOAuth(_ proveedor: Proveedor) async throws {
        guard let configuracion = proveedor.oauth,
              let imap = proveedor.imap,
              let smtp = proveedor.smtp else { return }

        let cliente = ClienteOAuth(configuracion: configuracion)
        let resultado = try await cliente.autorizar()

        let cuenta = Cuenta(
            id: "\(proveedor.rawValue):\(resultado.correo.lowercased())",
            proveedor: proveedor,
            correo: resultado.correo,
            nombre: resultado.nombre,
            imap: imap,
            smtp: smtp,
            usuario: resultado.correo
        )
        try Llavero.guardar(resultado.credencial, cuentaID: cuenta.id)
        anadir(cuenta)
    }

    /// Da de alta iCloud o una cuenta IMAP cualquiera con contraseña.
    func conectarConContrasena(
        proveedor: Proveedor,
        correo: String,
        nombre: String,
        contrasena: String,
        imap: Servidor?,
        smtp: Servidor?
    ) async throws {
        guard let imap = imap ?? proveedor.imap, let smtp = smtp ?? proveedor.smtp else {
            throw FalloIMAP.sinBuzon
        }
        let cuenta = Cuenta(
            id: "\(proveedor.rawValue):\(correo.lowercased())",
            proveedor: proveedor,
            correo: correo,
            nombre: nombre.isEmpty ? correo : nombre,
            imap: imap,
            smtp: smtp,
            usuario: correo
        )
        let credencial = Credencial(contrasena: contrasena)

        // Se comprueba antes de guardar: una cuenta que no entra no sirve de nada.
        let cliente = ClienteIMAP(servidor: imap)
        try await cliente.conectar()
        try await cliente.entrar(usuario: cuenta.usuario, credencial: credencial)
        try await cliente.seleccionar(cuenta.buzon)
        await cliente.salir()

        try Llavero.guardar(credencial, cuentaID: cuenta.id)
        anadir(cuenta)
    }

    private func anadir(_ cuenta: Cuenta) {
        if let indice = cuentas.firstIndex(where: { $0.id == cuenta.id }) {
            cuentas[indice] = cuenta
        } else {
            cuentas.append(cuenta)
        }
        persistir()
    }

    func quitar(_ cuenta: Cuenta) {
        cuentas.removeAll { $0.id == cuenta.id }
        Llavero.borrar(cuentaID: cuenta.id)
        persistir()
    }

    func marcarSincronizada(_ cuenta: Cuenta, hasta fecha: Date) {
        guard let indice = cuentas.firstIndex(where: { $0.id == cuenta.id }) else { return }
        cuentas[indice].sincronizadoHasta = fecha
        persistir()
    }

    func cuenta(_ id: String) -> Cuenta? {
        cuentas.first { $0.id == id }
    }
}
