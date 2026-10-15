import ConnectionKit
import SwiftUI

@main
struct RemoteScreenApp: App {
    /// Một danh sách máy cho MỌI cửa sổ của app. Mỗi cửa sổ giữ bản riêng thì cửa sổ lưu sau ghi đè tệp bằng danh sách cũ của
    /// nó, làm mất máy cửa sổ kia vừa lưu (mật khẩu của máy đó còn nằm mồ côi trong Keychain).
    @State private var model = ConnectionsModel(
        store: ConnectionStore(fileURL: ConnectionStore.defaultURL()), secrets: KeychainSecretStore()
    )

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
