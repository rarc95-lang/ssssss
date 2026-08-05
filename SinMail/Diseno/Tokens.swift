import SwiftUI
import UIKit

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
    //
    // Los tamaños son los del diseño en el ajuste por defecto del sistema, y
    // escalan con el cuerpo de letra que haya elegido el usuario. Un tamaño fijo
    // se leería igual en la maqueta y mal en el teléfono de quien lo necesita.

    enum Tipo {
        static var titulo: Font { escalada(17, .medium) }
        static var situacion: Font { escalada(15, .regular) }
        static var meta: Font { escalada(13, .regular) }
        static var chip: Font { escalada(12, .medium, relativoA: .caption1) }
        static var accion: Font { escalada(15, .medium) }
        static var accionSecundaria: Font { escalada(15, .regular) }
        static var encabezado: Font { escalada(24, .medium, relativoA: .title2) }
        /// La cita literal, resaltada dentro del hilo.
        static var citaResaltada: Font { escalada(15, .medium) }

        private static func escalada(
            _ tamano: CGFloat,
            _ peso: Font.Weight,
            relativoA estilo: UIFont.TextStyle = .body
        ) -> Font {
            Font.system(
                size: UIFontMetrics(forTextStyle: estilo).scaledValue(for: tamano),
                weight: peso
            )
        }
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
        /// Área mínima que se puede tocar con el dedo. Las acciones son sólo
        /// texto, así que el área crece sin que se vea nada.
        static let tocable: CGFloat = 44
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

/// La superficie de una tarjeta: blanco sobre la página, radio 18 y un borde de
/// un cabello.
///
/// El borde no es decoración. Sin sombras, `#FFFFFF` sobre `#FAFAF8` es un
/// contraste tan bajo que el canto de la tarjeta desaparece; el hairline es lo
/// único que dice dónde termina.
struct SuperficieTarjeta: ViewModifier {
    func body(content: Content) -> some View {
        let forma = RoundedRectangle(cornerRadius: Tokens.Metrica.radioTarjeta, style: .continuous)
        return content
            .background(forma.fill(Tokens.Color.tarjeta))
            .overlay(forma.strokeBorder(Tokens.Color.hairline, lineWidth: Tokens.Metrica.hairline))
    }
}

extension View {
    func superficieTarjeta() -> some View {
        modifier(SuperficieTarjeta())
    }

    /// Agranda el área tocable sin dibujar nada.
    func areaTocable() -> some View {
        frame(minHeight: Tokens.Metrica.tocable)
            .contentShape(Rectangle())
    }
}
