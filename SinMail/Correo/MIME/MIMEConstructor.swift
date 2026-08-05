import Foundation

/// Compone el código fuente de un correo saliente. Texto plano, UTF-8,
/// quoted-printable: sin adjuntos ni HTML, porque un borrador de SinMail es una
/// frase, no un documento.
enum MIMEConstructor {

    struct Salida {
        var fuente: Data
        var messageID: String
    }

    static func construir(
        de: Direccion,
        para: [Direccion],
        cc: [Direccion] = [],
        asunto: String,
        cuerpo: String,
        enRespuestaA: Mensaje?
    ) -> Salida {
        let messageID = "<\(UUID().uuidString)@sinmail.app>"
        var lineas: [String] = []

        lineas.append("Message-ID: \(messageID)")
        lineas.append("Date: \(fechaRFC5322(Date()))")
        lineas.append("From: \(de.cabecera)")
        lineas.append("To: \(para.map(\.cabecera).joined(separator: ", "))")
        if !cc.isEmpty {
            lineas.append("Cc: \(cc.map(\.cabecera).joined(separator: ", "))")
        }
        lineas.append("Subject: \(codificarCabecera(asunto))")

        if let original = enRespuestaA {
            lineas.append("In-Reply-To: <\(original.id)>")
            let referencias = (original.references + [original.id])
                .suffix(10)
                .map { "<\($0)>" }
                .joined(separator: " ")
            lineas.append("References: \(referencias)")
        }

        lineas.append("MIME-Version: 1.0")
        lineas.append("Content-Type: text/plain; charset=utf-8")
        lineas.append("Content-Transfer-Encoding: quoted-printable")
        lineas.append("")
        lineas.append(quotedPrintable(cuerpo))

        let fuente = lineas.joined(separator: "\r\n")
        return Salida(fuente: Data(fuente.utf8), messageID: messageID)
    }

    /// Codifica una cabecera con caracteres no ASCII como palabra codificada.
    static func codificarCabecera(_ texto: String) -> String {
        guard texto.contains(where: { !$0.isASCII }) else { return texto }
        let base64 = Data(texto.utf8).base64EncodedString()
        return "=?utf-8?B?\(base64)?="
    }

    static func quotedPrintable(_ texto: String) -> String {
        var salida = ""
        var largoLinea = 0

        func anadir(_ pieza: String) {
            if largoLinea + pieza.count > 73 {
                salida += "=\r\n"
                largoLinea = 0
            }
            salida += pieza
            largoLinea += pieza.count
        }

        for caracter in texto {
            if caracter == "\n" {
                salida += "\r\n"
                largoLinea = 0
                continue
            }
            if caracter == "\r" { continue }

            let escalares = Array(String(caracter).utf8)
            let imprimible = escalares.count == 1
                && escalares[0] >= 33
                && escalares[0] <= 126
                && escalares[0] != 61 // '='
            if imprimible {
                anadir(String(caracter))
            } else if caracter == " " {
                anadir(" ")
            } else {
                for byte in escalares {
                    anadir(String(format: "=%02X", byte))
                }
            }
        }
        return salida
    }

    static func fechaRFC5322(_ fecha: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return df.string(from: fecha)
    }
}
