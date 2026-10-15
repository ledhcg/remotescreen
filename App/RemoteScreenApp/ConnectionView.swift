import ConnectionKit
import SessionKit
import SwiftUI
import UIKit

/// Màn hình chọn máy, theo cách của Screen Sharing: một ô nhập địa chỉ ("Kết nối tới máy chủ"), danh sách máy đã lưu,
/// và máy tìm thấy trong mạng. Chạm một máy thì kết nối (hoặc hỏi tên và mật khẩu trong một hộp thoại), không có form dài.
struct ConnectionView: View {
    let controller: SessionController
    let model: ConnectionsModel

    @State private var browser = ServiceBrowser()
    @State private var address = ""
    @State private var addressError: String?
    /// Hộp thoại đăng nhập đang mở (nếu có).
    @State private var login: LoginRequest?
    /// Tên máy đang nối, hiện trên màn hình chờ.
    @State private var connectingName = ""
    /// Máy đã lưu vừa nối bằng mật khẩu đã lưu, để khi thất bại còn đề nghị nhập lại mật khẩu.
    @State private var lastSaved: SavedConnection?
    @FocusState private var addressFocused: Bool

    private var sections: ComputerList.Sections {
        ComputerList.sections(saved: model.saved, discovered: browser.hosts)
    }

    private var failureMessage: String? {
        if case .failed(let message) = controller.state { return message }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                addressSection
                if !sections.saved.isEmpty {
                    Section("Máy đã lưu") {
                        ForEach(sections.saved) { row in
                            computerButton(row)
                                .swipeActions {
                                    if case .saved(let connection) = row.source {
                                        Button("Xóa", role: .destructive) { delete(connection) }
                                    }
                                }
                                .contextMenu { contextMenu(for: row) }
                        }
                    }
                }
                nearbySection
                if sections.isEmpty { helpSection }
                if let saveError = model.lastError {
                    Section { Text("Không lưu được: \(saveError)").foregroundStyle(.red) }
                }
            }
            .navigationTitle("RemoteScreen")
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
            .overlay { if controller.state == .connecting && login == nil { connectingCard } }
            .sheet(item: $login, onDismiss: { controller.dismissFailure() }) { request in
                LoginSheet(request: request, controller: controller) { username, password, remember in
                    connect(request, username: username, password: password, remember: remember)
                } onCancel: {
                    controller.disconnect()
                    login = nil
                }
            }
            .alert("Không kết nối được", isPresented: failureAlertShown) {
                if let lastSaved {
                    Button("Nhập lại mật khẩu…") { login = LoginRequest(saved: lastSaved) }
                }
                Button("Đóng", role: .cancel) {}
            } message: {
                Text(failureMessage ?? "")
            }
        }
    }

    // MARK: - Ô nhập địa chỉ

    private var addressSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "network").foregroundStyle(.secondary)
                TextField("Tên máy hoặc địa chỉ VNC", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(connectToAddress)
                    .accessibilityIdentifier("address-field")
                if !address.isEmpty {
                    Button(action: connectToAddress) {
                        Image(systemName: "arrow.right.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Kết nối")
                }
            }
        } footer: {
            if let addressError {
                Text(addressError).foregroundStyle(.red)
            } else {
                Text("Ví dụ: mac-mini.local, 192.168.1.5, hoặc vnc://tài-khoản@máy:5900")
            }
        }
    }

    // MARK: - Danh sách

    @ViewBuilder
    private var nearbySection: some View {
        if !sections.nearby.isEmpty {
            Section("Trong mạng") {
                ForEach(sections.nearby) { computerButton($0) }
            }
        } else if browser.hosts.isEmpty, !browser.denied, !sections.saved.isEmpty {
            // Đã có máy lưu: chỉ báo nhẹ rằng đang tìm, không chiếm chỗ bằng khung trợ giúp.
            Section("Trong mạng") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Đang tìm máy trong mạng…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func computerButton(_ row: ComputerRow) -> some View {
        Button { open(row) } label: {
            HStack(spacing: 12) {
                ComputerIcon(size: 40, isOnline: row.isOnline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.headline).foregroundStyle(.primary)
                    Text(row.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain) // không để tint của nút nhuộm xanh cả dòng
        .disabled(controller.state == .connecting)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("computer.\(row.name)")
    }

    @ViewBuilder
    private func contextMenu(for row: ComputerRow) -> some View {
        Button("Kết nối", systemImage: "play") { open(row) }
        if case .saved(let connection) = row.source {
            Button("Nhập lại mật khẩu…", systemImage: "key") { login = LoginRequest(saved: connection) }
            Button("Xóa", systemImage: "trash", role: .destructive) { delete(connection) }
        }
    }

    /// Khi chưa có gì để chọn: nói rõ phải làm gì ở phía Mac, thay vì để màn hình trống.
    private var helpSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: browser.denied ? "lock.shield" : "desktopcomputer")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                if browser.denied {
                    Text("Chưa có quyền Mạng cục bộ").font(.headline)
                    Text("Cho phép RemoteScreen tìm máy trong mạng để tự thấy các Mac, hoặc nhập địa chỉ ở trên.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Mở Cài đặt") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Đang tìm máy trong mạng…").font(.headline)
                    }
                    Text("Trên Mac, bật Cài đặt hệ thống › Chung › Chia sẻ › Chia sẻ màn hình. Mac và thiết bị này cần cùng mạng Wi-Fi.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Đang kết nối

    private var connectingCard: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Đang kết nối tới \(connectingName)…").font(.headline).multilineTextAlignment(.center)
            Button("Hủy") { controller.disconnect() }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 20)
        .transition(.opacity)
    }

    private var failureAlertShown: Binding<Bool> {
        Binding(
            get: { login == nil && failureMessage != nil },
            set: { shown in
                if !shown { controller.dismissFailure() }
            }
        )
    }

    // MARK: - Hành động

    private func open(_ row: ComputerRow) {
        addressError = nil
        switch row.source {
        case .saved(let connection):
            if let stored = model.password(for: connection) {
                connectingName = connection.name
                lastSaved = connection
                controller.connect(target: connection.target, username: connection.username, password: stored) {
                    model.markUsed(connection)
                }
            } else {
                login = LoginRequest(saved: connection)
            }
        case .discovered(let host):
            lastSaved = nil
            login = LoginRequest(target: host.target, name: host.name, username: "")
        }
    }

    private func connectToAddress() {
        switch ConnectionDraft(host: address).validated() {
        case .failure(.emptyHost):
            addressError = "Nhập tên máy hoặc địa chỉ."
        case .failure(.invalidPort):
            addressError = "Cổng phải là số từ 1 đến 65535."
        case .success(let valid):
            addressError = nil
            addressFocused = false
            let target = SavedConnection.Target.host(valid.host, port: valid.port)
            let known = model.connection(for: target)
            lastSaved = nil
            login = LoginRequest(target: target, name: valid.host, username: valid.username ?? known?.username ?? "")
        }
    }

    /// Nối từ hộp thoại đăng nhập. Chỉ lưu SAU khi kết nối thành công: gõ sai địa chỉ hay mật khẩu không để lại rác trong danh sách.
    private func connect(_ request: LoginRequest, username: String, password: String, remember: Bool) {
        connectingName = request.name
        lastSaved = nil
        let target = request.target
        let name = request.name
        controller.connect(target: target, username: username, password: password) {
            guard remember else { return }
            model.remember(target: target, username: username, password: password, name: name)
        }
    }

    private func delete(_ connection: SavedConnection) {
        do { try model.delete(connection) } catch { model.lastError = error.localizedDescription }
    }
}

/// Máy đang hỏi tên và mật khẩu trong hộp thoại.
struct LoginRequest: Identifiable {
    let id = UUID()
    let target: SavedConnection.Target
    let name: String
    /// Tên tài khoản điền sẵn (máy đã lưu, hoặc nhập dạng `tài-khoản@máy`).
    let username: String

    init(target: SavedConnection.Target, name: String, username: String) {
        self.target = target
        self.name = name
        self.username = username
    }

    init(saved: SavedConnection) {
        self.init(target: saved.target, name: saved.name, username: saved.username)
    }
}

/// Biểu tượng máy tính: ô bo góc xanh, kèm chấm xanh lá khi Bonjour đang thấy máy.
struct ComputerIcon: View {
    var size: CGFloat = 40
    var isOnline = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay { Image(systemName: "desktopcomputer").font(.system(size: size * 0.5)).foregroundStyle(.white) }
            .overlay(alignment: .bottomTrailing) {
                if isOnline {
                    Circle()
                        .fill(.green)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 3, y: 3)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Hộp thoại "Nhập tên và mật khẩu", giống hộp thoại của Screen Sharing: kết quả (đang nối, sai mật khẩu…) hiện ngay tại đây,
/// các ô giữ nguyên để sửa rồi thử lại. Nối thành công thì màn hình chọn máy biến mất cùng hộp thoại này.
struct LoginSheet: View {
    let request: LoginRequest
    let controller: SessionController
    let onConnect: (_ username: String, _ password: String, _ remember: Bool) -> Void
    let onCancel: () -> Void

    @State private var username: String
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    init(
        request: LoginRequest,
        controller: SessionController,
        onConnect: @escaping (String, String, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.controller = controller
        self.onConnect = onConnect
        self.onCancel = onCancel
        _username = State(initialValue: request.username)
    }

    private var isConnecting: Bool { controller.state == .connecting }
    private var canConnect: Bool { !password.isEmpty && !isConnecting }

    private var failure: String? {
        if case .failed(let message) = controller.state { return message }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        ComputerIcon(size: 64)
                        Text("Chia sẻ màn hình với “\(request.name)”")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text("Nhập tên và mật khẩu của một tài khoản macOS trên máy này.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Tên tài khoản", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("login-username")
                    SecureField("Mật khẩu", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                        .accessibilityIdentifier("login-password")
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(.red)
                    } else if username.isEmpty {
                        Text("Mac cần tên tài khoản macOS. Chỉ để trống nếu máy dùng mật khẩu VNC (yếu hơn đăng nhập tài khoản).")
                    }
                }
                .disabled(isConnecting)

                Section {
                    Toggle("Ghi nhớ mật khẩu trong Keychain", isOn: $remember)
                } footer: {
                    Text("Mật khẩu chỉ nằm trong Keychain của thiết bị này, không đồng bộ lên iCloud.\n\n\(ConnectionSecurityNotice.loginFooter)")
                }
                .disabled(isConnecting)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Đang kết nối…")
                        }
                    } else {
                        Button("Kết nối", action: submit)
                            .fontWeight(.semibold)
                            .disabled(!canConnect)
                            .accessibilityIdentifier("login-connect")
                    }
                }
            }
        }
        .interactiveDismissDisabled(isConnecting)
        .task { focus = username.isEmpty ? .username : .password }
    }

    private func submit() {
        guard canConnect else { return }
        onConnect(username.trimmingCharacters(in: .whitespaces), password, remember)
    }
}
