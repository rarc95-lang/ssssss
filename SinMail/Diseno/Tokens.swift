import SwiftUI

/// Sistema de diseño de SinMail.
///
/// Los valores son literales y cerrados a propósito: el diseño es minimalista,
/// pastel y de iOS moderno, y cualquier color, peso o radio que no esté aquí
/// no debe aparecer en la interfaz.
enum Tokens {

    // MARK: - Color

    enum Color {
        static let pagina = SwiftUI.Color(hex: 0xFAFAF8)
        static let tarjeta = SwiftUI.Color(hex: 0xFFFFFF)
        static let texto = SwiftUI.Color(hex: 0x1C1C1E)
        static let secundario = SwiftUI.Color(hex: 0x8A8A8E)
        static let hairline = SwiftUI.Color(red: 0, green: 0, blue: 0, opacity: 0.06)

        static let tuyoFondo = SwiftUI.Color(hex: 0xE7EEFC)
        static let tuyoTexto = SwiftUI.Color(hex: 0x1D4ED8)

        static let esperandoFondo = SwiftUI.Color(hex: 0xF7EFE5)
        static let esperandoTexto = SwiftUI.Color(hex: 0x96794F)

        static let leerFondo = SwiftUI.Color(hex: 0xF0F0ED)
        static let leerTexto = SwiftUI.Color(hex: 0x71716B)

        static let cerradoFondo = SwiftUI.Color(hex: 0xE9F1E9)
        static let cerradoTexto = SwiftUI.Color(hex: 0x5B7A5B)
    }

    // MARK: - Tipografía
    //
    // SF Pro, únicamente pesos 400 (regular) y 500 (medium). Nunca mayúsculas.

    enum Tipo {
        static let titulo = Font.system(size: 17, weight: .medium)
        static let situacion = Font.system(size: 15, weight: .regular)
        static let meta = Font.system(size: 13, weight: .regular)
        static let chip = Font.system(size: 12, weight: .medium)
        static let accion = Font.system(size: 15, weight: .medium)
        static let accionSecundaria = Font.system(size: 15, weight: .regular)
        static let encabezado = Font.system(size: 24, weight: .medium)
    }

    // MARK: - Métrica

    enum Metrica {
        static let radioTarjeta: CGFloat = 18
        static let radioChip: CGFloat = 8
        static let padVertical: CGFloat = 16
        static let padHorizontal: CGFloat = 20
        static let separacion: CGFloat = 12
        static let margenPagina: CGFloat = 16
        static let hairline: CGFloat = 1
        /// Separación interna entre las líneas de una tarjeta.
        static let interlinea: CGFloat = 6
        static let padChipVertical: CGFloat = 4
        static let padChipHorizontal: CGFloat = 8
    }

    // MARK: - Movimiento

    enum Movimiento {
        /// Un cambio de estado se expresa con un fundido. La tarjeta no viaja.
        static let fundido = Animation.easeInOut(duration: 0.25)
        static let duracionFundido: TimeInterval = 0.25
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Línea divisoria de un cabello de grosor, sin sombra.
struct Divisor: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.Color.hairline)
            .frame(height: Tokens.Metrica.hairline)
    }
}
