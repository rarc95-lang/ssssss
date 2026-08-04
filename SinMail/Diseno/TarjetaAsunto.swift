import SwiftUI

/// Chip de estado, título, línea de situación, línea "Falta: …", divisor y
/// acciones al pie sólo en texto: diferenciadas por color y nunca con fondo.
struct TarjetaAsunto: View {

    let asunto: Asunto
    var alPulsar: (AccionTarjeta) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            contenido
                .padding(.vertical, Tokens.Metrica.padVertical)
                .padding(.horizontal, Tokens.Metrica.padHorizontal)

            if !asunto.acciones.isEmpty {
                Divisor()
                pie
                    .padding(.vertical, Tokens.Metrica.padVertical)
                    .padding(.horizontal, Tokens.Metrica.padHorizontal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Metrica.radioTarjeta, style: .continuous)
                .fill(Tokens.Color.tarjeta)
        )
        // Sin sombras.
        .animation(Tokens.Movimiento.fundido, value: asunto.estado)
        .animation(Tokens.Movimiento.fundido, value: asunto.situacion)
        .animation(Tokens.Movimiento.fundido, value: asunto.falta)
    }

    private var contenido: some View {
        VStack(alignment: .leading, spacing: Tokens.Metrica.interlinea) {
            ChipEstado(estado: asunto.estado)
                .padding(.bottom, 2)

            Text(asunto.titulo)
                .font(Tokens.Tipo.titulo)
                .foregroundColor(Tokens.Color.texto)
                .fixedSize(horizontal: false, vertical: true)

            Text(asunto.situacion)
                .font(Tokens.Tipo.situacion)
                .foregroundColor(Tokens.Color.texto)
                .fixedSize(horizontal: false, vertical: true)

            Text("Falta: \(asunto.falta)")
                .font(Tokens.Tipo.meta)
                .foregroundColor(Tokens.Color.secundario)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pie: some View {
        HStack(spacing: 20) {
            ForEach(asunto.acciones) { accion in
                Button {
                    alPulsar(accion)
                } label: {
                    Text(accion.titulo)
                        .font(accion.esPrimaria ? Tokens.Tipo.accion : Tokens.Tipo.accionSecundaria)
                        .foregroundColor(accion.esPrimaria ? asunto.estado.color : Tokens.Color.secundario)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
