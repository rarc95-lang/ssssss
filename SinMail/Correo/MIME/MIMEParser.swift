import Foundation

/// Lee el código fuente de un correo y devuelve un `Mensaje` con el cuerpo en
/// texto plano ya decodificado.
enum MIMEParser {

    static func mensaje(
        desde fuente: Data,
        uid: UInt32,
        cuenta: Cuenta,
        buzon: String
    ) -> Mensaje? {
        let (cabeceras, cuerpo) = separar(fuente)
        guard !cabeceras.isEmpty else { return nil }

        let de = direcciones(cabeceras["from"]).first
            ?? Direccion(nombre: nil, correo: "desconocido@desconocido")
        let asunto = Codificaciones.decodificarCabecera(cabeceras["subject"] ?? "")
        let fecha = fechaRFC5322(cabeceras["date"]) ?? Date()

        let messageID = cabeceras["message-id"]?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
            ?? "\(cuenta.id)-\(uid)"

        let references = (cabeceras["references"] ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
            .filter { !$0.isEmpty }

        let inReplyTo = cabeceras["in-reply-to"]?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))

        let parte = analizar(cabeceras: cabeceras, cuerpo: cuerpo)
        let texto = limpiar(parte.texto)

        return Mensaje(
            id: messageID,
            uid: uid,
            cuentaID: cuenta.id,
            buzon: buzon,
            de: de,
            para: direcciones(cabeceras["to"]),
            cc: direcciones(cabeceras["cc"]),
            asunto: asunto,
            fecha: fecha,
            inReplyTo: inReplyTo?.isEmpty == true ? nil : inReplyTo,
            references: references,
            texto: texto,
            tieneAdjuntos: parte.adjuntos,
            propio: de.correo.lowercased() == cuenta.correo.lowercased()
        )
    }

    // MARK: - Cabeceras

    static func separar(_ fuente: Data) -> (cabeceras: [String: String], cuerpo: Data) {
        let separadores: [Data] = [
            Data([0x0D, 0x0A, 0x0D, 0x0A]),
            Data([0x0A, 0x0A])
        ]
        var corte: Range<Data.Index>?
        for separador in separadores {
            if let encontrado = fuente.firstRange(of: separador) {
                if corte == nil || encontrado.lowerBound < corte!.lowerBound { corte = encontrado }
            }
        }
        guard let corte else {
            return (analizarCabeceras(String(decoding: fuente, as: UTF8.self)), Data())
        }
        let bruto = String(decoding: fuente[fuente.startIndex..<corte.lowerBound], as: UTF8.self)
        return (analizarCabeceras(bruto), fuente.subdata(in: corte.upperBound..<fuente.endIndex))
    }

    static func analizarCabeceras(_ bruto: String) -> [String: String] {
        var cabeceras: [String: String] = [:]
        var claveActual: String?
        var valorActual = ""

        for linea in bruto.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if linea.hasPrefix(" ") || linea.hasPrefix("\t") {
                valorActual += " " + linea.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let clave = claveActual {
                cabeceras[clave] = valorActual.trimmingCharacters(in: .whitespaces)
            }
            guard let dosPuntos = linea.firstIndex(of: ":") else {
                claveActual = nil
                valorActual = ""
                continue
            }
            claveActual = linea[linea.startIndex..<dosPuntos].lowercased()
                .trimmingCharacters(in: .whitespaces)
            valorActual = String(linea[linea.index(after: dosPuntos)...])
        }
        if let clave = claveActual {
            cabeceras[clave] = valorActual.trimmingCharacters(in: .whitespaces)
        }
        return cabeceras
    }

    // MARK: - Cuerpo

    private struct Parte {
        var texto: String
        var adjuntos: Bool
    }

    private static func analizar(cabeceras: [String: String], cuerpo: Data) -> Parte {
        let contentType = cabeceras["content-type"] ?? "text/plain"
        let tipo = contentType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? "text/plain"
        let parametros = parametrosDe(contentType)
        let codificacion = (cabeceras["content-transfer-encoding"] ?? "7bit")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        if tipo.hasPrefix("multipart/") {
            guard let frontera = parametros["boundary"] else {
                return Parte(texto: "", adjuntos: false)
            }
            let partes = trocear(cuerpo, frontera: frontera)
            var alternativas: [(prioridad: Int, texto: String)] = []
            var adjuntos = false

            for bruta in partes {
                let (subCabeceras, subCuerpo) = separar(bruta)
                let disposicion = (subCabeceras["content-disposition"] ?? "").lowercased()
                if disposicion.contains("attachment") {
                    adjuntos = true
                    continue
                }
                let sub = analizar(cabeceras: subCabeceras, cuerpo: subCuerpo)
                adjuntos = adjuntos || sub.adjuntos
                guard !sub.texto.isEmpty else { continue }

                let subTipo = (subCabeceras["content-type"] ?? "text/plain").lowercased()
                let prioridad = subTipo.contains("text/plain") ? 0 : (subTipo.contains("text/html") ? 1 : 2)
                alternativas.append((prioridad, sub.texto))
            }

            if tipo == "multipart/alternative" {
                let mejor = alternativas.min(by: { $0.prioridad < $1.prioridad })
                return Parte(texto: mejor?.texto ?? "", adjuntos: adjuntos)
            }
            return Parte(
                texto: alternativas.map(\.texto).joined(separator: "\n\n"),
                adjuntos: adjuntos
            )
        }

        guard tipo.hasPrefix("text/") else {
            return Parte(texto: "", adjuntos: true)
        }

        let datos: Data
        switch codificacion {
        case "base64":
            datos = Codificaciones.base64(String(decoding: cuerpo, as: UTF8.self))
        case "quoted-printable":
            datos = Codificaciones.quotedPrintable(cuerpo)
        default:
            datos = cuerpo
        }

        var texto = Codificaciones.texto(datos, juego: parametros["charset"])
        if tipo == "text/html" { texto = sinEtiquetas(texto) }
        return Parte(texto: texto, adjuntos: false)
    }

    private static func trocear(_ cuerpo: Data, frontera: String) -> [Data] {
        let marca = Data("--\(frontera)".utf8)
        var partes: [Data] = []
        var cursor = cuerpo.startIndex
        var inicioParte: Data.Index?

        while cursor < cuerpo.endIndex {
            guard let encontrado = cuerpo[cursor...].firstRange(of: marca) else { break }
            if let inicio = inicioParte {
                var fin = encontrado.lowerBound
                // Se descarta el CRLF que precede a la frontera.
                if fin > inicio, cuerpo[cuerpo.index(before: fin)] == 0x0A {
                    fin = cuerpo.index(before: fin)
                }
                if fin > inicio, cuerpo[cuerpo.index(before: fin)] == 0x0D {
                    fin = cuerpo.index(before: fin)
                }
                if fin > inicio { partes.append(cuerpo.subdata(in: inicio..<fin)) }
            }
            var siguiente = encontrado.upperBound
            // "--" final cierra el multipart.
            if siguiente < cuerpo.endIndex,
               cuerpo[siguiente] == 0x2D,
               cuerpo.index(after: siguiente) < cuerpo.endIndex,
               cuerpo[cuerpo.index(after: siguiente)] == 0x2D {
                break
            }
            while siguiente < cuerpo.endIndex, cuerpo[siguiente] != 0x0A {
                siguiente = cuerpo.index(after: siguiente)
            }
            if siguiente < cuerpo.endIndex { siguiente = cuerpo.index(after: siguiente) }
            inicioParte = siguiente
            cursor = siguiente
        }
        return partes
    }

    static func parametrosDe(_ cabecera: String) -> [String: String] {
        var parametros: [String: String] = [:]
        for pieza in cabecera.split(separator: ";").dropFirst() {
            let recorte = pieza.trimmingCharacters(in: .whitespaces)
            guard let igual = recorte.firstIndex(of: "=") else { continue }
            let clave = recorte[recorte.startIndex..<igual].lowercased()
            var valor = String(recorte[recorte.index(after: igual)...])
            valor = valor.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            parametros[clave] = valor
        }
        return parametros
    }

    // MARK: - Direcciones y fechas

    static func direcciones(_ cabecera: String?) -> [Direccion] {
        guard let cabecera, !cabecera.isEmpty else { return [] }
        var salida: [Direccion] = []
        var actual = ""
        var dentroDeComillas = false

        func cerrar() {
            let recorte = actual.trimmingCharacters(in: .whitespaces)
            actual = ""
            guard !recorte.isEmpty else { return }
            if let direccion = direccion(desde: recorte) { salida.append(direccion) }
        }

        for caracter in cabecera {
            if caracter == "\"" { dentroDeComillas.toggle() }
            if caracter == ",", !dentroDeComillas { cerrar(); continue }
            actual.append(caracter)
        }
        cerrar()
        return salida
    }

    private static func direccion(desde texto: String) -> Direccion? {
        if let abre = texto.lastIndex(of: "<"), let cierra = texto.lastIndex(of: ">"), abre < cierra {
            let correo = String(texto[texto.index(after: abre)..<cierra])
                .trimmingCharacters(in: .whitespaces)
            var nombre = String(texto[texto.startIndex..<abre])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
            nombre = Codificaciones.decodificarCabecera(nombre)
            return Direccion(nombre: nombre.isEmpty ? nil : nombre, correo: correo)
        }
        let correo = texto.trimmingCharacters(in: .whitespaces)
        guard correo.contains("@") else { return nil }
        return Direccion(nombre: nil, correo: correo)
    }

    static func fechaRFC5322(_ texto: String?) -> Date? {
        guard let texto else { return nil }
        let formatos = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm Z"
        ]
        let limpio = texto.replacingOccurrences(
            of: #"\s*\([^)]*\)\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        for formato in formatos {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = formato
            if let fecha = df.date(from: limpio) { return fecha }
        }
        return nil
    }

    // MARK: - Limpieza

    static func sinEtiquetas(_ html: String) -> String {
        var texto = html
        for patron in [#"<style[^>]*>[\s\S]*?</style>"#, #"<script[^>]*>[\s\S]*?</script>"#] {
            texto = texto.replacingOccurrences(of: patron, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        texto = texto.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        texto = texto.replacingOccurrences(of: #"</p>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        texto = texto.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        let entidades = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&aacute;": "á", "&eacute;": "é",
            "&iacute;": "í", "&oacute;": "ó", "&uacute;": "ú", "&ntilde;": "ñ"
        ]
        for (entidad, valor) in entidades {
            texto = texto.replacingOccurrences(of: entidad, with: valor, options: .caseInsensitive)
        }
        return texto
    }

    /// Quita firmas y citas al pie, que ensucian el análisis sin aportar nada.
    static func limpiar(_ texto: String) -> String {
        var lineas = texto
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        if let corte = lineas.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "--" }) {
            lineas = Array(lineas[..<corte])
        }
        let marcasDeCita = [
            "-----mensaje original-----", "-----original message-----",
            "el ", "on ", "de: ", "from: "
        ]
        if let corte = lineas.firstIndex(where: { linea in
            let l = linea.lowercased().trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix(">") || marcasDeCita.contains(where: { l.hasPrefix($0) }) else { return false }
            return l.contains("escribió") || l.contains("wrote") || l.hasPrefix("-----")
        }) {
            lineas = Array(lineas[..<corte])
        }

        return lineas
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
