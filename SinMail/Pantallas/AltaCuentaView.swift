import SwiftUI

/// Alta y baja de cuentas. Es plomería, no una de las tres pantallas del producto:
/// se abre desde el encabezado y desaparece en cuanto hay correo conectado.
struct AltaCuentaView: View {

    @EnvironmentObject private var cuentas: GestorCuentas
    @Environment(\.dismiss) private var cerrar

    @State private var proveedor: Proveedor = .gmail
    @State private var correo = ""
    @State private var nombre = ""
    @State private var contrasena = ""
    @State private var hostIMAP = ""
    @State private var hostSMTP = ""
    @State private var claveModelo = ClaveModelo.leer() ?? ""
    @State private var trabajando = false
    @State private var fallo: String?

    var body: some View {
        ZStack {
            Tokens.Color.pagina.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Metrica.separacion) {
                    cabecera
                    if !cuentas.cuentas.isEmpty { conectadas }
                    alta
                    modelo
                }
                .padding(.horizontal, Tokens.Metrica.margenPagina)
                .padding(.bottom, 32)
            }
        }
    }

    private var cabecera: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Cuentas")
                .font(Tokens.Tipo.encabezado)
                .foregroundColor(Tokens.Color.texto)
            Spacer(minLength: 0)
            Button {
                if !claveModelo.isEmpty { try? ClaveModelo.guardar(claveModelo) }
                cerrar()
            } label: {
                Text("Listo")
                    .font(Tokens.Tipo.accion)
                    .foregroundColor(Tokens.Color.tuyoTexto)
                    .areaTocable()
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 20)
    }

    private var conectadas: some View {
        tarjeta {
            ForEach(cuentas.cuentas) { cuenta in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cuenta.correo)
                            .font(Tokens.Tipo.situacion)
                            .foregroundColor(Tokens.Color.texto)
                        Text(cuenta.proveedor.nombre)
                            .font(Tokens.Tipo.meta)
                            .foregroundColor(Tokens.Color.secundario)
                    }
                    Spacer(minLength: 0)
                    Button {
                        cuentas.quitar(cuenta)
                    } label: {
                        Text("Quitar")
                            .font(Tokens.Tipo.accionSecundaria)
                            .foregroundColor(Tokens.Color.secundario)
                    }
                    .buttonStyle(.plain)
                }
                if cuenta.id != cuentas.cuentas.last?.id {
                    Divisor().padding(.vertical, 8)
                }
            }
        }
    }

    private var alta: some View {
        tarjeta {
            Text("Conectar")
                .font(Tokens.Tipo.titulo)
                .foregroundColor(Tokens.Color.texto)

            HStack(spacing: 16) {
                ForEach(Proveedor.allCases, id: \.self) { opcion in
                    Button {
                        proveedor = opcion
                    } label: {
                        Text(opcion.nombre)
                            .font(proveedor == opcion ? Tokens.Tipo.accion : Tokens.Tipo.accionSecundaria)
                            .foregroundColor(proveedor == opcion ? Tokens.Color.tuyoTexto : Tokens.Color.secundario)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            if let aviso = proveedor.aviso {
                Text(aviso)
                    .font(Tokens.Tipo.meta)
                    .foregroundColor(Tokens.Color.secundario)
            }

            if proveedor.metodo == .contrasena {
                campo("Correo", texto: $correo)
                campo("Nombre", texto: $nombre)
                campo("Contraseña", texto: $contrasena, secreto: true)
                if proveedor == .imap {
                    campo("Servidor IMAP", texto: $hostIMAP)
                    campo("Servidor SMTP", texto: $hostSMTP)
                }
            }

            if let fallo {
                Text(fallo)
                    .font(Tokens.Tipo.meta)
                    .foregroundColor(Tokens.Color.esperandoTexto)
            }

            Divisor().padding(.vertical, 4)

            Button {
                conectar()
            } label: {
                Text(trabajando ? "Conectando" : "Conectar \(proveedor.nombre)")
                    .font(Tokens.Tipo.accion)
                    .foregroundColor(Tokens.Color.tuyoTexto)
            }
            .buttonStyle(.plain)
            .disabled(trabajando)
        }
    }

    private var modelo: some View {
        tarjeta {
            Text("Modelo")
                .font(Tokens.Tipo.titulo)
                .foregroundColor(Tokens.Color.texto)
            Text("La clave se guarda en el llavero y sólo la usa este dispositivo.")
                .font(Tokens.Tipo.meta)
                .foregroundColor(Tokens.Color.secundario)
            campo("Clave de Anthropic", texto: $claveModelo, secreto: true)
        }
    }

    // MARK: - Piezas

    @ViewBuilder
    private func campo(_ titulo: String, texto: Binding<String>, secreto: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titulo)
                .font(Tokens.Tipo.meta)
                .foregroundColor(Tokens.Color.secundario)
            Group {
                if secreto {
                    SecureField("", text: texto)
                } else {
                    TextField("", text: texto)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .font(Tokens.Tipo.situacion)
            .foregroundColor(Tokens.Color.texto)
            Divisor()
        }
    }

    private func tarjeta<Contenido: View>(@ViewBuilder _ contenido: () -> Contenido) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Metrica.interlinea, content: contenido)
            .padding(.vertical, Tokens.Metrica.padVertical)
            .padding(.horizontal, Tokens.Metrica.padHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .superficieTarjeta()
    }

    private func conectar() {
        trabajando = true
        fallo = nil
        Task {
            do {
                if proveedor.metodo == .oauth2 {
                    try await cuentas.conectarConOAuth(proveedor)
                } else {
                    let imap = hostIMAP.isEmpty
                        ? nil
                        : Servidor(host: hostIMAP, puerto: 993, seguridad: .tls)
                    let smtp = hostSMTP.isEmpty
                        ? nil
                        : Servidor(host: hostSMTP, puerto: 587, seguridad: .starttls)
                    try await cuentas.conectarConContrasena(
                        proveedor: proveedor,
                        correo: correo,
                        nombre: nombre,
                        contrasena: contrasena,
                        imap: imap,
                        smtp: smtp
                    )
                }
                contrasena = ""
                cerrar()
            } catch {
                fallo = error.localizedDescription
            }
            trabajando = false
        }
    }
}
