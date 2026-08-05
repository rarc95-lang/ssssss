import Foundation

enum Codificaciones {

    /// Decodifica quoted-printable (RFC 2045).
    static func quotedPrintable(_ datos: Data) -> Data {
        var salida = Data()
        var i = datos.startIndex
        while i < datos.endIndex {
            let byte = datos[i]
            if byte == 0x3D { // '='
                let siguiente = datos.index(after: i)
                guard siguiente < datos.endIndex else { break }
                if datos[siguiente] == 0x0D || datos[siguiente] == 0x0A {
                    // Salto de línea suave: se descarta.
                    i = datos.index(after: siguiente)
                    if i < datos.endIndex, datos[i] == 0x0A, datos[siguiente] == 0x0D {
                        i = datos.index(after: i)
                    }
                    continue
                }
                let tercero = datos.index(after: siguiente)
                guard tercero < datos.endIndex,
                      let alto = hex(datos[siguiente]),
                      let bajo = hex(datos[tercero]) else {
                    salida.append(byte)
                    i = datos.index(after: i)
                    continue
                }
                salida.append(alto << 4 | bajo)
                i = datos.index(after: tercero)
            } else {
                salida.append(byte)
                i = datos.index(after: i)
            }
        }
        return salida
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    static func base64(_ texto: String) -> Data {
        let limpio = texto.filter { !$0.isWhitespace }
        let relleno = (4 - limpio.count % 4) % 4
        return Data(base64Encoded: limpio + String(repeating: "=", count: relleno)) ?? Data()
    }

    /// Traduce un juego de caracteres IANA a la codificación de Foundation.
    static func codificacion(_ nombre: String?) -> String.Encoding {
        guard let nombre = nombre?.lowercased() else { return .utf8 }
        switch nombre {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "iso-8859-2": return .isoLatin2
        case "windows-1252", "cp1252": return .windowsCP1252
        case "windows-1251": return .windowsCP1251
        case "utf-16": return .utf16
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(nombre as CFString)
            guard cf != kCFStringEncodingInvalidId else { return .utf8 }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    static func texto(_ datos: Data, juego: String?) -> String {
        let codificacion = codificacion(juego)
        return String(data: datos, encoding: codificacion)
            ?? String(data: datos, encoding: .isoLatin1)
            ?? String(decoding: datos, as: UTF8.self)
    }

    /// Decodifica las palabras codificadas de una cabecera (RFC 2047):
    /// `=?utf-8?B?...?=` y `=?iso-8859-1?Q?...?=`.
    static func decodificarCabecera(_ texto: String) -> String {
        guard texto.contains("=?") else { return texto }
        let patron = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: patron) else { return texto }

        var salida = ""
        var cursor = texto.startIndex
        let coincidencias = regex.matches(in: texto, range: NSRange(texto.startIndex..., in: texto))

        for coincidencia in coincidencias {
            guard
                let rangoTotal = Range(coincidencia.range, in: texto),
                let rangoJuego = Range(coincidencia.range(at: 1), in: texto),
                let rangoTipo = Range(coincidencia.range(at: 2), in: texto),
                let rangoCarga = Range(coincidencia.range(at: 3), in: texto)
            else { continue }

            let entre = String(texto[cursor..<rangoTotal.lowerBound])
            // Entre dos palabras codificadas contiguas sólo puede haber espacios,
            // y esos espacios se descartan según el RFC.
            if !entre.trimmingCharacters(in: .whitespaces).isEmpty || salida.isEmpty {
                salida += entre
            } else if !entre.isEmpty && cursor == texto.startIndex {
                salida += entre
            }

            let juego = String(texto[rangoJuego])
            let tipo = texto[rangoTipo].uppercased()
            let carga = String(texto[rangoCarga])

            let datos: Data
            if tipo == "B" {
                datos = base64(carga)
            } else {
                datos = quotedPrintable(Data(carga.replacingOccurrences(of: "_", with: " ").utf8))
            }
            salida += Self.texto(datos, juego: juego)
            cursor = rangoTotal.upperBound
        }

        salida += String(texto[cursor...])
        return salida
    }
}
