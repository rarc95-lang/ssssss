import SwiftUI

/// El borrador. Se abre desde la acción primaria con el texto ya escrito y el
/// cursor dentro: sin pantalla intermedia y sin spinner. El envío ocurre en un
/// segundo toque.
struct BorradorView: View {

    let asunto: Asunto

    @EnvironmentObject private var modelo: ModeloBandeja
    @Environment(\.dismiss) private var cerrar

    @State private var texto: String
    @State private var fallo: String?
    @FocusState private var escribiendo: Bool

    init(asunto: Asunto) {
        self.asunto = asunto
        _texto = State(initialValue: asunto.borrador)
    }

    var body: some View {
        ZStack {
            Tokens.Color.pagina.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Tokens.Metrica.separacion) {
                cabecera

                TextEditor(text: $texto)
                    .font(Tokens.Tipo.situacion)
                    .foregroundColor(Tokens.Color.texto)
                    .scrollContentBackground(.hidden)
                    .background(Tokens.Color.tarjeta)
                    .focused($escribiendo)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Metrica.radioTarjeta, style: .continuous)
                            .fill(Tokens.Color.tarjeta)
                    )

                if let fallo {
                    Text(fallo)
                        .font(Tokens.Tipo.meta)
                        .foregroundColor(Tokens.Color.esperandoTexto)
                }
            }
            .padding(.horizontal, Tokens.Metrica.margenPagina)
            .padding(.top, 20)
            .padding(.bottom, Tokens.Metrica.margenPagina)
        }
        .onAppear {
            // El cursor entra solo: el usuario ya está escribiendo.
            escribiendo = true
        }
        .onDisappear {
            if texto != asunto.borrador { modelo.guardarBorrador(texto, en: asunto) }
        }
    }

    private var cabecera: some View {
        VStack(alignment: .leading, spacing: Tokens.Metrica.interlinea) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    cerrar()
                } label: {
                    Text("Volver")
                        .font(Tokens.Tipo.accionSecundaria)
                        .foregroundColor(Tokens.Color.secundario)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    enviar()
                } label: {
                    Text(asunto.accion)
                        .font(Tokens.Tipo.accion)
                        .foregroundColor(Tokens.Color.tuyoTexto)
                }
                .buttonStyle(.plain)
                .disabled(texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text(asunto.titulo)
                .font(Tokens.Tipo.titulo)
                .foregroundColor(Tokens.Color.texto)

            Text("Para: \(asunto.destinatarios.joined(separator: ", "))")
                .font(Tokens.Tipo.meta)
                .foregroundColor(Tokens.Color.secundario)
        }
    }

    private func enviar() {
        let contenido = texto
        let destino = asunto
        // Se cierra en el acto: el envío sigue en marcha detrás, sin spinner.
        cerrar()
        Task {
            do {
                try await modelo.enviar(contenido, de: destino)
            } catch {
                await MainActor.run { modelo.aviso = error.localizedDescription }
            }
        }
    }
}
