import SwiftUI

/// "Sin" en azul y "Mail" en el color del texto. Sin icono, sin símbolo.
struct Logotipo: View {
    var body: some View {
        (
            Text("Sin").foregroundColor(Tokens.Color.tuyoTexto)
            + Text("Mail").foregroundColor(Tokens.Color.texto)
        )
        .font(Tokens.Tipo.encabezado)
        .accessibilityLabel("SinMail")
    }
}

/// Chip de estado: fondo pastel, texto del color del estado, radio 8.
struct ChipEstado: View {
    let estado: Estado

    var body: some View {
        Text(estado.etiqueta)
            .font(Tokens.Tipo.chip)
            .foregroundColor(estado.color)
            .padding(.vertical, Tokens.Metrica.padChipVertical)
            .padding(.horizontal, Tokens.Metrica.padChipHorizontal)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Metrica.radioChip, style: .continuous)
                    .fill(estado.fondo)
            )
            // El cambio de estado se expresa con un fundido de 250 ms.
            .id(estado)
            .transition(.opacity)
    }
}
