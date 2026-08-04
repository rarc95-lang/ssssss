import SwiftUI

/// El hilo: cronología de sólo lectura, con la cita resaltada. Está a un toque,
/// pero no es la interfaz.
struct HiloView: View {

    let asunto: Asunto

    @EnvironmentObject private var modelo: ModeloBandeja
    @Environment(\.dismiss) private var cerrar

    @State private var hilos: [Hilo] = []

    var body: some View {
        ZStack {
            Tokens.Color.pagina.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Metrica.separacion) {
                    cabecera

                    ForEach(hilos) { hilo in
                        ForEach(hilo.mensajes) { mensaje in
                            mensajeView(mensaje)
                        }
                    }
                }
                .padding(.horizontal, Tokens.Metrica.margenPagina)
                .padding(.bottom, 32)
            }
        }
        .task {
            hilos = await modelo.hilos(de: asunto)
        }
    }

    private var cabecera: some View {
        VStack(alignment: .leading, spacing: Tokens.Metrica.interlinea) {
            HStack {
                Button {
                    cerrar()
                } label: {
                    Text("Volver")
                        .font(Tokens.Tipo.accionSecundaria)
                        .foregroundColor(Tokens.Color.secundario)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Text(asunto.titulo)
                .font(Tokens.Tipo.titulo)
                .foregroundColor(Tokens.Color.texto)
        }
        .padding(.top, 20)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mensajeView(_ mensaje: Mensaje) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Metrica.interlinea) {
            HStack(alignment: .firstTextBaseline) {
                Text(mensaje.propio ? "Tú" : mensaje.de.visible)
                    .font(Tokens.Tipo.titulo)
                    .foregroundColor(Tokens.Color.texto)
                Spacer(minLength: 0)
                Text(Self.formato.string(from: mensaje.fecha))
                    .font(Tokens.Tipo.meta)
                    .foregroundColor(Tokens.Color.secundario)
            }

            cuerpo(de: mensaje)
                .font(Tokens.Tipo.situacion)
                .foregroundColor(Tokens.Color.texto)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, Tokens.Metrica.padVertical)
        .padding(.horizontal, Tokens.Metrica.padHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Metrica.radioTarjeta, style: .continuous)
                .fill(Tokens.Color.tarjeta)
        )
    }

    /// Resalta la cita literal dentro del mensaje del que salió.
    private func cuerpo(de mensaje: Mensaje) -> Text {
        guard
            mensaje.id == asunto.mensajeDeLaCita,
            let fragmento = Citas.fragmentoExacto(de: asunto.cita, en: mensaje.texto),
            let rango = mensaje.texto.range(of: fragmento)
        else {
            return Text(mensaje.texto)
        }

        let antes = String(mensaje.texto[mensaje.texto.startIndex..<rango.lowerBound])
        let despues = String(mensaje.texto[rango.upperBound...])

        return Text(antes)
            + Text(fragmento)
                .foregroundColor(asunto.estado.color)
                .font(.system(size: 15, weight: .medium))
            + Text(despues)
    }

    private static let formato: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_ES")
        df.dateFormat = "d MMM, HH:mm"
        return df
    }()
}
