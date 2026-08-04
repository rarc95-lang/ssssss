import Foundation

/// Cómo se autentica una cuenta contra IMAP y SMTP.
enum MetodoAcceso: String, Codable, Sendable {
    /// LOGIN / AUTH PLAIN con contraseña (o contraseña de aplicación).
    case contrasena
    /// AUTHENTICATE XOAUTH2 con un token que se renueva solo.
    case oauth2
}

enum Proveedor: String, Codable, CaseIterable, Sendable {
    case gmail
    case outlook
    case icloud
    case imap

    var nombre: String {
        switch self {
        case .gmail: return "Gmail"
        case .outlook: return "Outlook"
        case .icloud: return "iCloud"
        case .imap: return "Otra cuenta IMAP"
        }
    }

    var metodo: MetodoAcceso {
        switch self {
        case .gmail, .outlook: return .oauth2
        case .icloud, .imap: return .contrasena
        }
    }

    var imap: Servidor? {
        switch self {
        case .gmail: return Servidor(host: "imap.gmail.com", puerto: 993, seguridad: .tls)
        case .outlook: return Servidor(host: "outlook.office365.com", puerto: 993, seguridad: .tls)
        case .icloud: return Servidor(host: "imap.mail.me.com", puerto: 993, seguridad: .tls)
        case .imap: return nil
        }
    }

    var smtp: Servidor? {
        switch self {
        case .gmail: return Servidor(host: "smtp.gmail.com", puerto: 587, seguridad: .starttls)
        case .outlook: return Servidor(host: "smtp.office365.com", puerto: 587, seguridad: .starttls)
        case .icloud: return Servidor(host: "smtp.mail.me.com", puerto: 587, seguridad: .starttls)
        case .imap: return nil
        }
    }

    /// Nota que se muestra al dar de alta la cuenta.
    var aviso: String? {
        switch self {
        case .icloud:
            return "iCloud necesita una contraseña de aplicación, no la del Apple ID."
        case .imap:
            return "Introduce los datos que te dio tu proveedor de correo."
        case .gmail, .outlook:
            return nil
        }
    }

    var oauth: ConfiguracionOAuth? {
        switch self {
        case .gmail: return .google
        case .outlook: return .microsoft
        case .icloud, .imap: return nil
        }
    }
}

struct Servidor: Codable, Equatable, Sendable {
    enum Seguridad: String, Codable, Sendable {
        /// TLS desde el primer byte (IMAPS 993, SMTPS 465).
        case tls
        /// Texto claro y ascenso con STARTTLS (SMTP 587, IMAP 143).
        case starttls
    }

    var host: String
    var puerto: UInt16
    var seguridad: Seguridad
}

/// Una cuenta de correo conectada. Las credenciales viven en el llavero, nunca
/// aquí y nunca en CloudKit.
struct Cuenta: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var proveedor: Proveedor
    var correo: String
    var nombre: String
    var imap: Servidor
    var smtp: Servidor
    /// Usuario de acceso, normalmente igual al correo.
    var usuario: String
    /// Buzón de entrada. Se resuelve al conectar.
    var buzon: String = "INBOX"
    /// Última fecha sincronizada, para pedir sólo lo nuevo.
    var sincronizadoHasta: Date?

    var identidad: Direccion { Direccion(nombre: nombre, correo: correo) }
}
