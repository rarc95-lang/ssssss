import SwiftUI
import UIKit
import UserNotifications

@main
struct SinMailApp: App {

    @UIApplicationDelegateAdaptor(Delegado.self) private var delegado
    @StateObject private var modelo = ModeloBandeja()
    @StateObject private var cuentas = GestorCuentas.shared

    var body: some Scene {
        WindowGroup {
            BandejaView()
                .environmentObject(modelo)
                .environmentObject(cuentas)
                .preferredColorScheme(.light)
                .tint(Tokens.Color.tuyoTexto)
        }
    }
}

/// Recoge los avisos de CloudKit para traer los cambios de otros dispositivos, y
/// pide permiso para los recordatorios de los asuntos en espera.
final class Delegado: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions opciones: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        SincronizacionCloudKit.shared.arrancar()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification info: [AnyHashable: Any],
        fetchCompletionHandler completado: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        SincronizacionCloudKit.shared.recibirCambios()
        completado(.newData)
    }
}
