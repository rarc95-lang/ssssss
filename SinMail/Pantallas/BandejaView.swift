import SwiftUI

/// La bandeja. Tarjetas agrupadas en el orden TUYO, ESPERANDO, LEER, CERRADO,
/// encabezado con logo y una línea, y ningún contador de no leídos.
struct BandejaView: View {

    @EnvironmentObject private var modelo: ModeloBandeja
    @EnvironmentObject private var cuentas: GestorCuentas

    @State private var borrador: Asunto?
    @State private var hilo: Asunto?
    @State private var mostrandoAjustes = false

    var body: some View {
        ZStack {
            Tokens.Color.pagina.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: Tokens.Metrica.separacion) {
                    encabezado

                    if cuentas.cuentas.isEmpty {
                        invitacion
                    } else if modelo.vacia {
                        Text(modelo.sincronizando ? "Leyendo el correo" : "Nada pendiente")
                            .font(Tokens.Tipo.situacion)
                            .foregroundColor(Tokens.Color.secundario)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 24)
                    }

                    ForEach(modelo.asuntos) { asunto in
                        TarjetaAsunto(asunto: asunto) { accion in
                            atender(accion, en: asunto)
                        }
                    }
                }
                .padding(.horizontal, Tokens.Metrica.margenPagina)
                .padding(.bottom, 32)
            }
            .refreshable {
                await modelo.sincronizar()
                modelo.reagrupar()
            }
        }
        .task {
            await modelo.arrancar()
        }
        .onDisappear { modelo.detener() }
        .sheet(item: $borrador) { asunto in
            BorradorView(asunto: asunto)
                .environmentObject(modelo)
        }
        .sheet(item: $hilo) { asunto in
            HiloView(asunto: asunto)
                .environmentObject(modelo)
        }
        .sheet(isPresented: $mostrandoAjustes) {
            AltaCuentaView()
                .environmentObject(cuentas)
        }
    }

    // MARK: - Piezas

    private var encabezado: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Logotipo()
                Spacer(minLength: 0)
                Button {
                    mostrandoAjustes = true
                } label: {
                    Text("Cuentas")
                        .font(Tokens.Tipo.meta)
                        .foregroundColor(Tokens.Color.secundario)
                }
                .buttonStyle(.plain)
            }
            Text(modelo.linea)
                .font(Tokens.Tipo.meta)
                .foregroundColor(Tokens.Color.secundario)
                .animation(Tokens.Movimiento.fundido, value: modelo.linea)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var invitacion: some View {
        VStack(alignment: .leading, spacing: Tokens.Metrica.interlinea) {
            Text("Conecta tu correo")
                .font(Tokens.Tipo.titulo)
                .foregroundColor(Tokens.Color.texto)
            Text("SinMail lee tu cuenta y te devuelve asuntos, no mensajes.")
                .font(Tokens.Tipo.situacion)
                .foregroundColor(Tokens.Color.texto)
            Divisor().padding(.vertical, 8)
            Button {
                mostrandoAjustes = true
            } label: {
                Text("Conectar una cuenta")
                    .font(Tokens.Tipo.accion)
                    .foregroundColor(Tokens.Color.tuyoTexto)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Tokens.Metrica.padVertical)
        .padding(.horizontal, Tokens.Metrica.padHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Metrica.radioTarjeta, style: .continuous)
                .fill(Tokens.Color.tarjeta)
        )
    }

    // MARK: - Acciones

    private func atender(_ accion: AccionTarjeta, en asunto: Asunto) {
        switch accion {
        case .primaria:
            // El borrador se abre desde la acción primaria, con el texto ya escrito.
            borrador = asunto
        case .verHilo:
            hilo = asunto
        case .cerrar:
            modelo.cerrar(asunto)
        case .recordar:
            modelo.recordar(asunto)
        }
    }
}
