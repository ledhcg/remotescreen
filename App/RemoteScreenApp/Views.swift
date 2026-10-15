import ConnectionKit
import InputKit
import RemoteDisplay
import SessionKit
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = SessionController(defaults: SessionController.environmentDefaults())
    let model: ConnectionsModel

    var body: some View {
        Group {
            switch controller.state {
            // Hai trạng thái chung một nhánh để SessionView (và khung hình cuối) không bị dựng lại khi mất rồi có lại kết nối.
            case .connected(let name), .reconnecting(let name, _, _):
                SessionView(controller: controller, name: name)
            default:
                ConnectionView(controller: controller, model: model)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.appDidEnterBackground()
            case .active: controller.appDidBecomeActive()
            case .inactive: controller.sceneDidDeactivate()
            @unknown default: break
            }
        }
        .task {
            #if DEBUG
            // Kết nối tự động khi chạy thử: biến môi trường RFB_HOST, RFB_PORT, RFB_USER, RFB_PASSWORD.
            let environment = ProcessInfo.processInfo.environment
            if let host = environment["RFB_HOST"] {
                let port = UInt16(environment["RFB_PORT"] ?? "") ?? 5900
                let username = environment["RFB_USER"] ?? ""
                let password = environment["RFB_PASSWORD"] ?? ""
                let shouldSave = environment["RFB_SAVE"] == "1" // thử luồng lưu kết nối mà không cần gõ form
                controller.connect(host: host, port: port, username: username, password: password) {
                    guard shouldSave else { return }
                    model.remember(target: .host(host, port: port), username: username, password: password, name: host)
                }
            }
            #endif
        }
    }
}

struct SessionView: View {
    let controller: SessionController
    let name: String
    /// Khung các điều khiển nổi trong toạ độ cửa sổ. View màn hình từ xa bỏ qua cú chạm rơi vào đây, để nút nhận được cú
    /// chạm thay vì cú chạm bị gửi xuống Mac.
    @State private var toolbarFrame = CGRect.zero
    @State private var keyBarFrame = CGRect.zero
    @State private var bannerFrame = CGRect.zero
    /// Thanh công cụ thu gọn thành một viên thuốc nhỏ để nhường chỗ cho màn hình Mac (nhất là trên iPhone).
    @State private var isToolbarCollapsed = false

    private var excludedRegions: [CGRect] {
        [toolbarFrame, keyBarFrame, bannerFrame].filter { $0 != .zero }.map { $0.insetBy(dx: -12, dy: -12) }
    }

    private var showsSidebar: Bool { controller.sidebarPosition != .hidden }

    var body: some View {
        // Sidebar nằm cạnh màn hình Mac (không đè lên): màn hình Mac co lại cho vừa phần còn lại, như Sidecar.
        HStack(spacing: 0) {
            if controller.sidebarPosition == .leading { Sidebar(controller: controller, name: name) }
            screenArea
            if controller.sidebarPosition == .trailing { Sidebar(controller: controller, name: name) }
        }
        .background(.black)
        .onChange(of: controller.isKeyBarVisible) { _, visible in
            if !visible { keyBarFrame = .zero } // khung cũ không được chặn cú chạm vào màn hình từ xa
        }
    }

    private var screenArea: some View {
        ZStack {
            RemoteScreenRepresentable(controller: controller, excludedRegions: excludedRegions)
                .ignoresSafeArea()
            if case .reconnecting = controller.state {
                // Làm mờ và chặn chạm: không có phiên nào để nhận thao tác nữa.
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }
            VStack(spacing: 8) {
                toolbar.claimingTouches(frame: $toolbarFrame)
                if controller.isStatsVisible {
                    Text(controller.statsLine)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("stream-stats")
                }
                if let warning = controller.securityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("security-warning")
                }
                if case .reconnecting(let reconnectName, let attempt, let total) = controller.state {
                    reconnectBanner(name: reconnectName, attempt: attempt, total: total)
                } else if let notice = controller.clipboard.notice {
                    Text(notice)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                Spacer()
                if controller.isKeyBarVisible {
                    KeyBar(controller: controller, showsModifiers: !showsSidebar)
                        .claimingTouches(frame: $keyBarFrame)
                        .padding(.bottom, 4)
                }
            }
            .animation(.default, value: controller.clipboard.notice)
        }
    }

    private func reconnectBanner(name: String, attempt: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(controller.isApplyingQuality
                 ? "Đang áp dụng chế độ chất lượng mới…"
                 : "Mất kết nối với \(name). Đang nối lại (\(attempt)/\(total))…")
                .font(.footnote)
            Button("Hủy") { controller.disconnect() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .claimingTouches(frame: $bannerFrame)
        // Banner biến mất thì khung của nó cũng phải biến mất: `onGeometryChange` không báo khi view bị gỡ, nên trước đây một dải
        // dưới thanh công cụ (thường là thanh menu của Mac) bị chặn chạm suốt phần còn lại của phiên sau mỗi lần nối lại.
        .onDisappear { bannerFrame = .zero }
    }

    // MARK: - Thanh công cụ

    private var isReconnecting: Bool {
        if case .reconnecting = controller.state { return true }
        return false
    }

    private var statusColor: Color {
        if isReconnecting { return .orange }
        return controller.isViewOnly ? .blue : .green
    }

    private var statusText: String {
        if isReconnecting { return "Đang nối lại…" }
        return controller.isViewOnly ? "Chỉ xem" : "Đang điều khiển"
    }

    @ViewBuilder
    private var toolbar: some View {
        if isToolbarCollapsed { collapsedToolbar } else { fullToolbar }
    }

    /// Viên thuốc thu gọn: chạm để mở lại thanh đầy đủ.
    private var collapsedToolbar: some View {
        Button {
            withAnimation(.snappy) { isToolbarCollapsed = false }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(name).font(.footnote.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel("Hiện thanh công cụ")
        .accessibilityValue("\(name), \(statusText)")
        .padding(.top, 4)
    }

    /// Thanh công cụ nổi theo bố cục của Screen Sharing: ngắt kết nối, tên máy và trạng thái, các nút hay dùng, rồi menu tùy chọn.
    private var fullToolbar: some View {
        HStack(spacing: 14) {
            // Sidebar đang hiện thì nó đã có ngắt kết nối, bàn phím và thanh phím phụ: thanh công cụ gọn lại, che ít thanh menu Mac hơn.
            if !showsSidebar {
                Button("Ngắt kết nối với \(name)", systemImage: "xmark.circle.fill") { controller.disconnect() }
                    .tint(.red)
            }

            Button {
                withAnimation(.snappy) { isToolbarCollapsed = true }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Text(statusText).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 150, alignment: .leading)
                .foregroundStyle(.white)
            }
            .accessibilityLabel("\(name), \(statusText). Chạm để thu gọn thanh công cụ")

            Divider().frame(height: 24)

            if !showsSidebar {
                Button("Bàn phím", systemImage: "keyboard") { controller.toggleKeyboard() }
                    .tint(controller.isKeyboardVisible ? .blue : .white)
                    .disabled(controller.isViewOnly || !controller.isLive)
                    .accessibilityAddTraits(controller.isKeyboardVisible ? .isSelected : [])
                Button("Phím phụ", systemImage: "command") { controller.toggleKeyBar() }
                    .tint(controller.isKeyBarVisible ? .blue : .white)
                    .disabled(controller.isViewOnly || !controller.isLive)
                    .accessibilityAddTraits(controller.isKeyBarVisible ? .isSelected : [])
            }
            optionsMenu
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule()) // cả viên thuốc nhận cú chạm, không chỉ riêng biểu tượng
        .padding(.top, 4)
    }

    /// Menu tùy chọn, gom các mục như menu của Screen Sharing: điều khiển/chỉ xem, cỡ hiển thị, clipboard, con trỏ.
    private var optionsMenu: some View {
        Menu {
            Picker("Chế độ", selection: Binding(get: { controller.isViewOnly }, set: { controller.setViewOnly($0) })) {
                Label("Điều khiển", systemImage: "cursorarrow.click.2").tag(false)
                Label("Chỉ xem", systemImage: "eye").tag(true)
            }
            .pickerStyle(.inline)

            Picker("Hiển thị", selection: Binding(get: { controller.displayMode }, set: { controller.setDisplayMode($0) })) {
                Label("Vừa màn hình", systemImage: "arrow.down.right.and.arrow.up.left").tag(DisplayMode.fit)
                Label("Lấp đầy màn hình", systemImage: "arrow.up.left.and.arrow.down.right").tag(DisplayMode.fill)
                Label("Điểm ảnh gốc (1:1)", systemImage: "1.square").tag(DisplayMode.native)
                Label("Theo độ phân giải thiết bị", systemImage: "rectangle.on.rectangle").tag(DisplayMode.device)
            }
            .pickerStyle(.inline)

            Picker("Cách chạm", selection: Binding(get: { controller.touchMode }, set: { controller.setTouchMode($0) })) {
                Label("Chạm trực tiếp", systemImage: "hand.point.up.left").tag(TouchMode.directTouch)
                Label("Bàn di chuột", systemImage: "rectangle.and.hand.point.up.left").tag(TouchMode.trackpad)
            }
            .pickerStyle(.inline)

            Picker("Sidebar", selection: Binding(get: { controller.sidebarPosition }, set: { controller.setSidebarPosition($0) })) {
                Label("Sidebar bên trái", systemImage: "sidebar.left").tag(SidebarPosition.leading)
                Label("Sidebar bên phải", systemImage: "sidebar.right").tag(SidebarPosition.trailing)
                Label("Ẩn sidebar", systemImage: "rectangle").tag(SidebarPosition.hidden)
            }
            .pickerStyle(.inline)

            Menu("Cử chỉ trên Mac", systemImage: "hand.draw") {
                Toggle("Cuộn mượt kiểu trackpad", isOn: Binding(
                    get: { controller.smoothScroll }, set: { controller.setSmoothScroll($0) }
                ))
                Picker("Chụm/xoay hai ngón", selection: Binding(
                    get: { controller.pinchSendsToMac }, set: { controller.setPinchSendsToMac($0) }
                )) {
                    Text("Phóng khung nhìn iPad").tag(false)
                    Text("Gửi lên Mac").tag(true)
                }
                .pickerStyle(.inline)
                if !controller.isAppleServer {
                    Text("Chỉ có với máy Mac (Chia sẻ màn hình của macOS)")
                }
            }

            if UIDevice.current.userInterfaceIdiom == .pad {
                Menu("Apple Pencil", systemImage: "applepencil") {
                    Picker("Chạm hai lần lên bút", selection: Binding(
                        get: { controller.pencilDoubleTapAction }, set: { controller.setPencilDoubleTapAction($0) }
                    )) {
                        Text("Nhấp phải").tag(PencilDoubleTapAction.secondaryClick)
                        Text("Hiện/ẩn bàn phím").tag(PencilDoubleTapAction.toggleKeyboard)
                        Text("Không làm gì").tag(PencilDoubleTapAction.nothing)
                    }
                    .pickerStyle(.inline)
                    Toggle("Ngón tay chỉ cuộn khi dùng bút", isOn: Binding(
                        get: { controller.fingersOnlyScrollWithPencil }, set: { controller.setFingersOnlyScrollWithPencil($0) }
                    ))
                }
            }

            Toggle("Hiện con trỏ của Mac", systemImage: "cursorarrow", isOn: Binding(
                get: { controller.isRemoteCursorVisible }, set: { controller.setRemoteCursorVisible($0) }
            ))

            Picker("Chất lượng hình", selection: Binding(get: { controller.qualityMode }, set: { controller.setQualityMode($0) })) {
                Label("Tự động", systemImage: "wand.and.stars").tag(QualityMode.adaptive)
                Label("Hiển thị tốt nhất", systemImage: "sparkles.tv").tag(QualityMode.bestQuality)
                Label("Hiệu năng tốt nhất", systemImage: "bolt").tag(QualityMode.bestPerformance)
            }
            .pickerStyle(.menu)

            Toggle("Hiện thống kê luồng hình", systemImage: "gauge.with.dots.needle.33percent", isOn: Binding(
                get: { controller.isStatsVisible }, set: { controller.setStatsVisible($0) }
            ))

            Menu("Clipboard", systemImage: "doc.on.clipboard") {
                Button("Lấy clipboard từ Mac", systemImage: "arrow.down.doc") { controller.clipboard.requestFromMac() }
                Picker("Đồng bộ", selection: Binding(get: { controller.clipboard.mode }, set: { controller.clipboard.mode = $0 })) {
                    Text("Thủ công").tag(ClipboardBridge.Mode.manual)
                    Text("Tự động (⌘C, ⌘V)").tag(ClipboardBridge.Mode.shared)
                }
                .pickerStyle(.inline)
            }

            Section {
                Button("Ngắt kết nối", systemImage: "xmark.circle", role: .destructive) { controller.disconnect() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .tint(.white)
        .accessibilityLabel("Tùy chọn")
    }
}

/// Thanh phím phụ: các phím iOS không có trên bàn phím ảo. Phím bổ trợ (⌃ ⌥ ⌘ ⇧) là phím dính: chạm một lần để giữ xuống,
/// nó tự nhả sau phím hay cú nhấp kế tiếp, nên chạm ⌘ rồi gõ `c` là Cmd+C. Chạm hai lần nhanh để khóa, chạm lại để bỏ.
/// Sidebar đang hiện thì các phím bổ trợ chỉ nằm trên sidebar.
struct KeyBar: View {
    let controller: SessionController
    var showsModifiers = true

    private static let modifiers: [(StickyModifier, String, String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.command, "⌘", "Command"), (.shift, "⇧", "Shift"),
    ]
    private static let keys: [(VirtualKey, String, String)] = [
        (.escape, "esc", "Escape"), (.tab, "tab", "Tab"),
        (.left, "←", "Mũi tên trái"), (.down, "↓", "Mũi tên xuống"), (.up, "↑", "Mũi tên lên"), (.right, "→", "Mũi tên phải"),
        (.home, "home", "Home"), (.end, "end", "End"), (.pageUp, "pg↑", "Page Up"), (.pageDown, "pg↓", "Page Down"),
        (.forwardDelete, "del", "Xóa tới"),
    ]

    /// Clipboard: chọn chế độ, lấy từ Mac, và nút Dán của hệ thống để gửi lên Mac (nút này đọc clipboard thiết bị mà không
    /// hiện hộp thoại xin quyền, khác với việc app tự đọc).
    private var clipboardControls: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Đồng bộ clipboard", selection: Binding(
                    get: { controller.clipboard.mode }, set: { controller.clipboard.mode = $0 }
                )) {
                    Text("Thủ công").tag(ClipboardBridge.Mode.manual)
                    Text("Tự động (⌘C, ⌘V)").tag(ClipboardBridge.Mode.shared)
                }
            } label: {
                Image(systemName: controller.clipboard.mode == .shared ? "doc.on.clipboard.fill" : "doc.on.clipboard")
                    .frame(minWidth: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Chế độ clipboard")

            Button { controller.clipboard.requestFromMac() } label: {
                Image(systemName: "arrow.down.doc").frame(minWidth: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Lấy clipboard từ Mac")

            PasteButton(payloadType: String.self) { strings in
                controller.clipboard.send(text: strings.first ?? "")
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.roundedRectangle)
            .accessibilityLabel("Gửi clipboard tới Mac")
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if showsModifiers {
                    ForEach(Self.modifiers, id: \.0) { modifier, symbol, name in
                        let state = controller.modifierStates[modifier] ?? .up
                        Button { controller.toggleModifier(modifier) } label: {
                            HStack(spacing: 2) {
                                Text(symbol)
                                if state == .locked { Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)) }
                            }
                            .frame(minWidth: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(state == .up ? .gray : .blue)
                        .accessibilityLabel(name)
                        .accessibilityValue(state == .locked ? "Đang khóa" : "")
                        .accessibilityAddTraits(state == .up ? [] : .isSelected)
                    }
                    Divider().frame(height: 24)
                }
                clipboardControls
                Divider().frame(height: 24)
                ForEach(Self.keys, id: \.0) { key, symbol, name in
                    Button { controller.press(key) } label: {
                        Text(symbol).frame(minWidth: 28)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(name)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        // Đang nối lại thì phím dính bấm vào sẽ bị bỏ (không có phiên) mà vẫn hiện là đang dính: khóa cả thanh cho tới khi nối xong.
        .disabled(!controller.isLive)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule())
        .padding(.horizontal, 12)
    }
}

private extension View {
    /// Cho điều khiển nổi này nhận cú chạm của nó và báo khung của nó ra ngoài (để view màn hình từ xa bỏ qua vùng đó).
    ///
    /// Không bỏ `simultaneousGesture`: nút SwiftUI nằm đè lên một UIViewRepresentable (view màn hình từ xa) không nhận
    /// được cú chạm nếu vùng đó không có cử chỉ SwiftUI nào. Đo trên iPad thật (iPadOS 27.0.1): thiếu nó thì bấm nút không
    /// làm gì, dù có loại trừ vùng chạm khỏi view bên dưới. Cử chỉ rỗng này không làm gì cả, chỉ để SwiftUI nhận vùng đó.
    func claimingTouches(frame: Binding<CGRect>) -> some View {
        simultaneousGesture(TapGesture().onEnded {})
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.wrappedValue = $0 }
    }
}

struct RemoteScreenRepresentable: UIViewRepresentable {
    let controller: SessionController
    var excludedRegions: [CGRect] = []

    func makeUIView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView(frame: .zero, device: nil)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: RemoteScreenView, context: Context) {
        uiView.excludedRegions = excludedRegions
    }
}
