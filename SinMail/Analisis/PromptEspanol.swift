import Foundation

/// El texto que gobierna el análisis. Las reglas del producto viven aquí y en el
/// validador: aquí se piden, allí se imponen.
enum PromptEspanol {

    static let sistema = """
    Conviertes un hilo de correo en asuntos pendientes. Devuelves JSON puro y nada más.

    Un asunto es la cosa pendiente real, no el mensaje: "cotización camilla", no \
    "Re: Re: consulta". Un asunto puede abarcar varios hilos y varias personas. \
    Ante la duda, un hilo es un asunto.

    Campos de cada asunto:
    - titulo: la cosa pendiente, cinco palabras como máximo, en minúsculas salvo \
    nombres propios.
    - estado: TUYO, ESPERANDO o LEER.
    - responsable: quién tiene la pelota ahora, por su nombre.
    - situacion: en qué punto está, diez palabras como máximo.
    - falta: qué falta exactamente para avanzar.
    - accion: verbo más objeto, cuatro palabras como máximo, nombrando el acto \
    concreto: "Enviar el número", "Confirmar la fecha", "Mandar el presupuesto". \
    Nunca escribas "Responder".
    - cita: una frase copiada literalmente del hilo que justifique el estado. \
    Cópiala carácter por carácter. No la parafrasees, no la traduzcas, no la \
    resumas y no la inventes.
    - confianza: número entre 0 y 1.

    Estados:
    - TUYO cuando la siguiente acción depende del usuario.
    - ESPERANDO cuando depende de otra persona.
    - LEER cuando es información sin acción.

    Reglas que no se rompen:
    - Nunca devuelves CERRADO. El cierre lo confirma el usuario, no el sistema.
    - Si hay una pregunta dirigida al usuario y sin responder, el estado no puede \
    ser LEER.
    - Si tu confianza es menor que 0.6, el estado es TUYO.
    - La cita aparece tal cual en el hilo. Si no encuentras ninguna frase que \
    sirva, copia la última frase del último mensaje ajeno.

    Respondes con un objeto JSON con una clave "asuntos" que contiene un array. \
    Sin texto antes ni después, sin explicaciones y sin bloques de código.
    """

    /// Prepara el hilo para el modelo: sólo lo necesario, y con los identificadores
    /// que hacen falta para volver a atar cita y mensaje.
    static func usuario(hilo: Hilo, identidad: Direccion) -> String {
        var lineas: [String] = []
        lineas.append("Usuario: \(identidad.visible) <\(identidad.correo)>")
        lineas.append("Hilo: \(hilo.id)")
        lineas.append("Asunto del correo: \(hilo.asunto)")
        lineas.append("")

        let formato = DateFormatter()
        formato.locale = Locale(identifier: "es_ES")
        formato.dateFormat = "d MMM HH:mm"

        for mensaje in hilo.mensajes.suffix(12) {
            let quien = mensaje.propio ? "El usuario" : mensaje.de.visible
            lineas.append("--- \(quien), \(formato.string(from: mensaje.fecha))")
            lineas.append(String(mensaje.texto.prefix(4000)))
            lineas.append("")
        }
        return lineas.joined(separator: "\n")
    }

    /// Esquema al que se ciñe la respuesta del modelo. Se escribe como JSON y no
    /// como literales de Swift: anidar diccionarios heterogéneos hace sufrir al
    /// compilador y se lee peor.
    static let esquema: [String: Any] = {
        let texto = """
        {
          "type": "object",
          "properties": {
            "asuntos": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "titulo": { "type": "string" },
                  "estado": { "type": "string", "enum": ["TUYO", "ESPERANDO", "LEER"] },
                  "responsable": { "type": "string" },
                  "situacion": { "type": "string" },
                  "falta": { "type": "string" },
                  "accion": { "type": "string" },
                  "cita": { "type": "string" },
                  "confianza": { "type": "number" }
                },
                "required": [
                  "titulo", "estado", "responsable", "situacion",
                  "falta", "accion", "cita", "confianza"
                ],
                "additionalProperties": false
              }
            }
          },
          "required": ["asuntos"],
          "additionalProperties": false
        }
        """
        let objeto = try? JSONSerialization.jsonObject(with: Data(texto.utf8))
        return objeto as? [String: Any] ?? [:]
    }()
}
