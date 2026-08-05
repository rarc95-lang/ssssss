import Foundation

/// Agrupa mensajes sueltos en hilos siguiendo References e In-Reply-To, con el
/// asunto normalizado como red de seguridad cuando las cabeceras se pierden.
enum Enhebrador {

    static func enhebrar(_ mensajes: [Mensaje]) -> [Hilo] {
        var conjuntos = ConjuntosDisjuntos<String>()
        var porID: [String: Mensaje] = [:]

        for mensaje in mensajes {
            porID[mensaje.id] = mensaje
            conjuntos.anadir(mensaje.id)
            for referencia in mensaje.references + [mensaje.inReplyTo].compactMap({ $0 }) {
                conjuntos.anadir(referencia)
                conjuntos.unir(mensaje.id, referencia)
            }
        }

        // Segunda pasada: mensajes sin cabeceras de hilo pero con el mismo asunto
        // normalizado y participantes en común.
        var porAsunto: [String: [Mensaje]] = [:]
        for mensaje in mensajes {
            let clave = normalizar(mensaje.asunto)
            guard !clave.isEmpty else { continue }
            porAsunto[clave, default: []].append(mensaje)
        }
        for (_, grupo) in porAsunto where grupo.count > 1 {
            let ordenado = grupo.sorted { $0.fecha < $1.fecha }
            for (anterior, siguiente) in zip(ordenado, ordenado.dropFirst()) {
                guard comparten(anterior, siguiente) else { continue }
                conjuntos.unir(anterior.id, siguiente.id)
            }
        }

        var agrupados: [String: [Mensaje]] = [:]
        for mensaje in mensajes {
            let raiz = conjuntos.raiz(mensaje.id) ?? mensaje.id
            agrupados[raiz, default: []].append(mensaje)
        }

        return agrupados.map { raiz, lista in
            let ordenada = lista.sorted { $0.fecha < $1.fecha }
            return Hilo(
                id: raiz,
                cuentaID: ordenada.first?.cuentaID ?? "",
                asunto: ordenada.first?.asunto ?? "",
                mensajes: ordenada
            )
        }
        .sorted { $0.fecha > $1.fecha }
    }

    /// Quita los prefijos de respuesta y reenvío en español e inglés.
    static func normalizar(_ asunto: String) -> String {
        var texto = asunto.lowercased().trimmingCharacters(in: .whitespaces)
        let prefijos = ["re:", "rv:", "fw:", "fwd:", "res:", "ref:"]
        var cambio = true
        while cambio {
            cambio = false
            for prefijo in prefijos where texto.hasPrefix(prefijo) {
                texto = String(texto.dropFirst(prefijo.count)).trimmingCharacters(in: .whitespaces)
                cambio = true
            }
        }
        return texto
    }

    private static func comparten(_ a: Mensaje, _ b: Mensaje) -> Bool {
        let correosA = Set(a.participantes.map { $0.correo.lowercased() })
        let correosB = Set(b.participantes.map { $0.correo.lowercased() })
        return !correosA.isDisjoint(with: correosB)
    }
}

/// Union-find, para agrupar por referencias sin recorrer el grafo entero.
struct ConjuntosDisjuntos<Elemento: Hashable> {
    private var padre: [Elemento: Elemento] = [:]

    mutating func anadir(_ elemento: Elemento) {
        if padre[elemento] == nil { padre[elemento] = elemento }
    }

    mutating func raiz(_ elemento: Elemento) -> Elemento? {
        guard var actual = padre[elemento] else { return nil }
        while let siguiente = padre[actual], siguiente != actual { actual = siguiente }
        padre[elemento] = actual
        return actual
    }

    mutating func unir(_ a: Elemento, _ b: Elemento) {
        guard let raizA = raiz(a), let raizB = raiz(b), raizA != raizB else { return }
        padre[raizB] = raizA
    }
}
