# Ghi chú giao thức: Apple Screen Sharing (RFB)

> **Lưu ý về nguồn gốc.** Tài liệu này ghi lại *quan sát hành vi* của giao thức Screen Sharing và các suy luận từ đó, không chứa mã nguồn của Apple. Địa chỉ hàm và mã băm của binary đã được lược bỏ. Apple không công bố giao thức này, nên nội dung có thể sai hoặc đổi giữa các bản macOS.

Quy ước nhãn: **[QS]** quan sát trực tiếp, **[SL]** suy luận, **[CB]** chưa biết / cần xác minh.

Môi trường quan sát: macOS 27.0.1 (26A434), `screensharingd` cục bộ qua loopback, ngày 2026-10-14.
Công cụ: `rfbprobe` (thăm dò trực tiếp, không gửi thông tin đăng nhập) và REA/Hopper (đọc binary).

## 1. Handshake (đã xác nhận bằng `rfbprobe`)

| Mục | Giá trị | Nhãn |
|---|---|---|
| Chuỗi version server | `RFB 003.889` | [QS] |
| Client trả lời | `RFB 003.008`, server chấp nhận và đi tiếp | [QS] |
| Security types, **theo thứ tự server gửi** | `30, 33, 36, 31, 32, 2, 35` | [QS] |

## 2. Phản hồi đầu tiên của server sau khi chọn từng type (`rfbprobe --select N`)

| Type | Phản hồi trong 1,5 giây | Diễn giải | Nhãn |
|---|---|---|---|
| 2 | 16 byte | Thử thách VNC Authentication chuẩn (kiểm chứng công cụ) | [QS] |
| 30 | 1028 byte | Cấu trúc DH, xem mục 3 | [QS] |
| 31 | 1028 byte, cùng khuôn với 30 | Biến thể của kiểu DH. **Chưa rõ khác 30 ở bước nào** | [QS] khuôn; [CB] khác biệt |
| 32 | 1028 byte, cùng khuôn với 30 | Biến thể của kiểu DH. **Chưa rõ khác 30/31 ở bước nào** | [QS] khuôn; [CB] khác biệt |
| 33 | 0 byte, server im lặng | **Client phải nói trước** (ví dụ gửi định danh người dùng) | [QS] im lặng; [SL] SRP |
| 35 | 0 byte, server im lặng | Như 33 | [QS] im lặng; [CB] chức năng |
| 36 | 0 byte, server im lặng | Như 33 | [QS] im lặng; [CB] chức năng |

Kết luận có thể dựa vào: **[SL]** 33, 35, 36 là các kiểu mà client mở đầu. Binary `screensharingd` có nhập `ccsrp_server_*` và nhóm RFC 5054 (1024/2048/4096/8192) nên ít nhất một trong số này dùng SRP. Chưa gán được số nào.

## 3. Cấu trúc phản hồi của type 30, 31, 32 (1028 byte)

```
offset  độ dài  nội dung
0       2       00 05
2       2       02 00            (= 512)
4       512     số nguyên tố p   (4096-bit)
516     512     khóa công khai của server (thay đổi mỗi kết nối)
        ----
        1028    = 4 + 512 + 512
```

- **[QS]** Tổng 1028 byte khớp chính xác với `2 + 2 + 512 + 512`, nên trường 2 byte thứ hai (`0x0200 = 512`) là độ dài khóa.
- **[QS]** 512 byte số nguyên tố trùng khít với chuỗi byte đầu và cuối của nhóm MODP 4096-bit trong RFC 3526 (bắt đầu `FFFFFFFF FFFFFFFF C90FDAA2 2168C234`, kết thúc `... 34063199 FFFFFFFF FFFFFFFF`).
- **[SL]** Trường 2 byte đầu `00 05` là generator g = 5. Tài liệu cộng đồng cũ thường nói g = 2 với nhóm 1024-bit, nên đây là điểm khác cần chú ý.
- **[CB]** Chưa kiểm chứng toàn bộ số nguyên tố từng byte so với RFC 3526. Chưa biết cách tạo khóa AES từ bí mật chung (nhận định cũ: MD5 của bí mật chung, **chưa kiểm chứng với nhóm 4096-bit này**).

**Hệ quả thiết kế:** thư viện số lớn cần xử lý **4096-bit**, không phải 1024-bit như plan ban đầu ghi.

**Hiệu năng đã đo [QS]** (`BigUInt` tự viết, nhân Montgomery, Apple Silicon, bản release; một lần modexp):

| Số mũ | Thời gian |
|---|---|
| 512-bit | ≈ 38 ms |
| 4096-bit (đầy đủ) | ≈ 287 ms |

Một lần DH cần 2 modexp (khóa công khai của client và bí mật chung). Nhận định ban đầu "bắt buộc dùng số mũ ngắn để đủ nhanh" **không đúng**: số mũ ngắn chỉ là tối ưu tùy chọn. Mặc định hiện là 512-bit. Chưa đo trên iPhone thật, nên con số cho thiết bị cần đo lại. Bản debug chậm hơn khoảng 20 lần (0,9 s và 6 s).

## 4. Quan sát từ binary (xem phân tích trước)

- **[QS]** `screensharingd` nhúng ZRLE (`EncodeZRLE.c`), zlib, JPEG DCT, cursor có cache ID, hai stream HEVC (`RFBMediaStreamMessage1`), `DisplayInfo`/`DisplayInfo2`, đo băng thông.
- **[QS]** Khóa phiên ARD dùng `CCCryptor` AES-ECB (`viewer->AESKeyECB`).
- **[QS]** SRP dùng các hàm `ccsrp_*` của corecrypto (`ccsrp_server_compute_session`, `ccsrp_server_generate_public_key`, `ccsrp_server_verify_session`, `ccsrp_ctx_init`) và các nhóm `ccsrp_gp_rfc5054_{1024,2048,4096,8192}`.
- **[QS]** Hàm gọi `ccsrp_server_compute_session` không được trình đọc binary nhận ra: nhận ra hàm chứa nó, nên chưa đọc được logic.
- **[CB]** Hash dùng trong SRP (SHA-1 hay SHA-256), cách đệm số, định dạng message và nhóm nào được dùng ở type nào: chưa biết.
- **[CB]** corecrypto không có API công khai trên iOS, nên SRP phải tự cài đặt. Vì vậy các chi tiết ở trên là bắt buộc phải biết chính xác.

## 4b. SRP của Apple (đọc từ binary + thực nghiệm, vòng 2)

Hàm xử lý nằm trong lát cắt `arm64e` của `screensharingd`, tên gốc `srp_server_mech_step1/step2` trong `common/srp.m`.

**Quan sát từ binary [QS]:**

| Mục | Giá trị |
|---|---|
| Khuôn đọc message bước 1 của client | `"%s%s%s%o"` |
| Khuôn đọc message bước 2 của client | `"%m%-o%s%-o"` (`%-o` là biến thể của `os`, **chưa biết khác ở đâu**) |
| Nhóm mặc định | `rfc5054_4096` (còn hỗ trợ 1024/2048/8192) |
| Hàm băm mặc định | `sha512` (`SHA-512`) |
| KDF | `SALTED-SHA512-PBKDF2` |
| Tùy chọn trong message | `mda=`, `maxbuffersize=`, `replay_detection`, confidentiality + integrity, KDF |
| Nguồn dữ liệu người dùng | Tra bản ghi qua OpenDirectory, lấy salt qua `customFunction` |
| Lớp bảo mật sau xác thực | Có (`LayerInit`, IV ngẫu nhiên `sIV`). **Phiên có thể được mã hóa** |
| Kerberos / GSS | Có chuỗi `GSS_S_BAD_MECH`, `gss-code`, `KerberosProcessesCipherMessage` |

**Suy luận [SL]:** mã này dẫn xuất từ plugin SRP của cyrus-sasl (`ScreenSharing.plist` ghi nhận `SRP` từ `cyrus-sasl 1.59`, tên hàm trùng, thông điệp lỗi trùng). Khuôn bước 1 của Apple khớp hoàn toàn bản gốc `{ utf8(U) utf8(I) utf8(sid) os(cn) }`.

**Quy ước mã hóa buffer của bản gốc cyrus-sasl (tham khảo, bản Apple có thể khác):**

| Kiểu | Mã hóa |
|---|---|
| Toàn buffer | 4 byte độ dài (big-endian) + nội dung |
| `utf8` (`%s`) | 2 byte độ dài + byte |
| `os` (`%o`) | 1 byte độ dài + byte |
| `mpi` (`%m`) | 2 byte độ dài + byte |
| `uint` (`%u`) | 4 byte |
| `char` (`%c`) | 1 byte |

**Thực nghiệm bằng `rfbprobe --send-hex` (chỉ gửi tên tài khoản, không có mật khẩu) [QS]:**

| Type | Gửi | Phản hồi |
|---|---|---|
| 33 | 4 byte bất kỳ, hoặc message bước 1 (có/không tiền tố độ dài) | Đóng kết nối ngay, 0 byte |
| 36 | như trên | Đóng kết nối ngay, 0 byte |
| 35 | message bước 1 có tiền tố 4 byte | Lặp lại đúng 4 byte đầu rồi đóng |
| 35 | message bước 1 không tiền tố | `00 09 64 69` (4 byte đầu của thân), rồi đóng |
| 35 | `00000000` | Lặp lại `00000000`, giữ kết nối, chờ tiếp |
| 35 | `00000001` hoặc `ffffffff` | Lặp lại 4 byte rồi đóng |

**Chưa giải thích được [CB]:**
- Vì sao type 35 lặp lại 4 byte đầu và phản ứng khác nhau theo giá trị. Có thể là trao đổi một từ 32-bit trước khi vào SRP, nhưng đó là suy đoán.
- 33 và 36 đóng kết nối ngay trước cả những message hợp lệ theo khuôn cyrus. Một trong hai có thể là Kerberos (cần token GSS), nhưng chưa có bằng chứng gán số.
- Khung RFB bọc quanh các buffer SRP.

**Kết luận:** thử mù đã hết giá trị. Muốn biết chính xác cần một trong hai: (a) bắt lưu lượng của client Apple từ Mac thứ hai, (b) đọc tiếp hàm tách buffer và hàm gọi `srp_server_mech_step`.

## 4c. Trạng thái cài đặt (RFBKit)

| Thành phần | Trạng thái | Kiểm chứng |
|---|---|---|
| Handshake, liệt kê security type | Xong | Server thật + unit test |
| Type 1 None, type 2 VNC Authentication | Xong | DES đối chiếu OpenSSL; luồng bằng luồng giả. **Chưa thử với server thật** (cần mật khẩu VNC) |
| Type 30 Apple Remote Desktop | Xong | Số lớn đối chiếu Python; DH hai chiều bằng server giả với số nguyên tố 4096-bit thật. **Đăng nhập thật thành công** (2026-10-14, `rfbprobe --login 30` vào `screensharingd` macOS 27.0.1) |
| `ClientInit` / `ServerInit` / `PixelFormat` | Xong | Unit test + server thật |
| `SetPixelFormat` / `SetEncodings` / `FramebufferUpdateRequest`, `RFBSession`, `Framebuffer` | Xong | Unit test + **server thật**: nhận khung hình Raw đầy đủ (2048×1152, 9216 KiB, ≈ 0,56 s qua loopback) và đối chiếu bằng mắt với giao diện thật, màu đúng, không lệch hàng |
| Decoder Raw, CopyRect, pseudo DesktopSize / LastRect | Xong | Unit test. Raw đã kiểm chứng với server thật. **CopyRect chưa thấy server thật gửi** vì ta mới chỉ khai báo Raw |
| Decoder ZRLE (zlib liên tục, 7 loại tile) | Xong. **Khung đầu tiên đã kiểm chứng với server thật**; nhiều cập nhật nối tiếp chờ kiểm chứng (`--watch`) | Unit test: tile tính tay theo RFC 6143, luồng zlib nối tiếp do Python nén. Server thật (2026-10-14, `--compare-encodings`): xin Raw rồi ZRLE trên cùng kết nối, **0/2.359.296 pixel khác nhau**; Raw 9216 KiB / 0,54 s, ZRLE 829 KiB / 0,05 s (nén 11,1×) |
| Cập nhật tăng dần ZRLE liên tục | **Đã kiểm chứng** [QS] | Ghi lại 8 giây byte thật từ server (290 cập nhật, 40.478 tile, 22,7 MiB nén ra 440 MiB, một luồng zlib liên tục) rồi giải mã bằng một **bộ giải mã Python độc lập**: **0/2.359.296 pixel khác** với decoder Swift. Xem mục 4d |
| Pseudo-encoding Cursor (-239) | **Hoạt động**: server gửi khi hình con trỏ đổi [QS] | 6 sự kiện con trỏ trong 15 giây khi người dùng di chuột; con trỏ cuối 16×16, điểm nóng (5, 8). Server **không** gửi kèm khung đầu (lần `--compare-encodings` không nhận được). Nhận định cũ của tôi "server không hỗ trợ -239" là **sai** |
| CopyRect | Decoder xong; **0 lần server gửi trong lần chạy `--watch`** [QS] | Chưa kết luận server không bao giờ dùng, vì không rõ người dùng có kéo cửa sổ hay cuộn trang trong lúc chạy |
| Decoder Hextile, Zlib, Tight | Chưa làm | |

**Về phép so khung cuối của `--watch` [đã giải thích]:** so khung tích lũy với một khung Raw lấy sau đó **không thể cho kết quả sạch khi màn hình đang chuyển động**. Phép thử đối chứng cho thấy điều này: chạy y hệt nhưng nhận bằng **Raw** (không có decoder nén) vẫn cho 229.003 pixel khác (9,7%), nhiều hơn ZRLE (27.133 pixel, 1,15%), vì màn hình lúc đó có tới ~47 cập nhật/giây. Lần đầu (102.412 pixel) còn bị nhiễu thêm do công cụ in ra terminal trên chính màn hình đang chụp; đã sửa bằng cách lấy khung tham chiếu trước khi in. Kết luận về tính đúng đắn của decoder vì vậy dựa vào phép giải mã song song ở mục 4d, không dựa vào phép so này.

Lưu ý thiết kế về zlib [QS, qua test]: zlib chỉ kiểm tra Adler32 ở cuối luồng, mà luồng RFB không kết thúc giữa phiên, nên một bit bị đảo trong dữ liệu nén vẫn giải ra dữ liệu sai mà **không báo lỗi**. Phát hiện lệch luồng phải dựa vào kiểm tra tầng ZRLE (byte thừa hoặc thiếu sau tile cuối, lượt chạy vượt tile, chỉ số palette sai) và trần kích thước giải nén (chống zip bomb).
| Type 31, 32, 33, 35, 36 | **Chưa hỗ trợ**, trả `unsupportedSecurityType` | Xem mục 4b |

**Đã xác nhận bằng đăng nhập thật [QS]** trên nhóm DH 4096-bit của type 30: khóa AES-128 = MD5(bí mật chung đệm đủ 512 byte) và khối đăng nhập 128 byte = tên (64) + mật khẩu (64), mỗi trường kết thúc bằng NUL. Số mũ riêng của client 512-bit được server chấp nhận.

Sau xác thực, `ServerInit` đọc được [QS]: 2048 × 1152, tên `Mac mini`, pixel format 32 bpp / depth 24 / little-endian / true colour / max 255 / shift R16 G8 B0, tức byte trong bộ nhớ là B, G, R, X và khớp `MTLPixelFormat.bgra8Unorm`.

Thử đăng nhập thật và chụp khung hình (mật khẩu chỉ đọc từ biến môi trường, không bao giờ được in ra; ảnh chứa toàn bộ màn hình, thư mục `.snapshots/` nằm trong `.gitignore`):

```sh
read -s "RFB_PASSWORD?Mật khẩu: "; export RFB_PASSWORD
RFB_USER=<tên tài khoản> swift run -c release -q rfbprobe 127.0.0.1 5900 --login 30 --snapshot .snapshots/first-frame.png
```

## 4d. Kiểm chứng giải mã ZRLE bằng bộ giải mã độc lập

**Phương pháp.** `rfbprobe --watch N --record FILE --dump-frame FILE` ghi nguyên văn mọi byte server gửi (sau `ServerInit`) và khung hình do decoder Swift dựng. `Tools/replay-check/zrle_replay.py` giải mã lại đúng các byte đó bằng numpy và zlib của Python (không dùng lại code Swift) rồi so từng pixel. Cả hai bên giải mã cùng dữ liệu nên không phụ thuộc màn hình có chuyển động hay không. **Bản ghi chứa nội dung màn hình: không commit, xóa sau khi dùng** (`.snapshots/` và các file ghi tạm không nên nằm trong repo).

**Kết quả [QS]** (macOS 27.0.1, 2026-10-14): 290 `FramebufferUpdate`, toàn bộ là ZRLE (không có Raw, CopyRect hay Cursor trong đoạn ghi); 22.735 KiB nén → 439.667 KiB sau giải nén; **0 pixel khác nhau**.

**Phát hiện quan trọng [QS]:** trong 40.478 tile thật, **100% là loại raw** (sub-encoding 0). Server Apple không dùng tile một màu, palette hay RLE; việc nén hoàn toàn do zlib. Hệ quả:
- Dữ liệu thật **chỉ kiểm chứng được đường raw** của decoder.
- Sáu loại tile còn lại (một màu, palette 1/2/4 bit, RLE, palette RLE) được kiểm chứng bằng `Tools/replay-check/make_zrle_fixture.py`: một bộ **mã hóa** ZRLE độc lập (Python) dựng ảnh có pixel đúng biết trước, bao phủ đủ bảy loại tile, lượt chạy dài hơn 255, hình chữ nhật không nằm trên lưới 64, hai hình chữ nhật trong cùng luồng zlib. Test Swift `ZRLERoundTripTests` giải ra ảnh phải khớp MD5. Đã kiểm tra bằng đột biến: phá có chủ đích dịch bit palette, độ dài lượt chạy, cờ RLE của palette và độ lệch tile cạnh thì cả bốn đều bị test bắt.
- Giới hạn còn lại: bộ mã hóa và bộ giải mã đều do cùng một người viết theo cùng cách hiểu đặc tả. Chúng bắt được lỗi cài đặt, không bắt được hiểu sai đặc tả ở các loại tile server Apple không gửi. Khi có server VNC khác (TigerVNC, UltraVNC...) nên chạy lại phép giải mã song song trên dữ liệu của chúng.

## 4e. Clipboard (đo và đọc binary ngày 2026-10-14)

**Kết luận ngắn [QS]:** server Apple **không** dùng `ServerCutText`/`ClientCutText` chuẩn để đồng bộ clipboard. Nó dùng message riêng,
**hỏi-đáp**, có UTF-8 (tiếng Việt và emoji đi qua nguyên vẹn). Đã kiểm chứng cả hai chiều với `screensharingd` thật qua LAN.

### Cách tìm ra

1. `strings screensharingd` có `HandleViewerClipboardRequest`, `HandleViewerClipboardSend`, `HandleAutoPasteboardCommand`,
   `RFBAutoPasteboardMessage`, "uncompressed size %u pasteboardDataCnt %d", "only want promises".
2. `otool -arch arm64e -tV` (Hopper không phân giải được hàm trong binary này). Hàm xử lý message chính đọc byte loại vào `[sp+0xab]`,
   `cmp w8, #0x25` rồi nhảy qua **bảng nhảy** (38 mục, offset 32-bit có dấu tính từ lệnh `adr`).
   Đọc bảng bằng Python rồi đối chiếu địa chỉ đích với các chuỗi log `Handle...` trong từng hàm.
3. Thử trực tiếp bằng `rfbprobe --clipboard-request`, `--send-apple-clipboard`, `--clipboard-probe`.

### Bản đồ loại message client → server (phần liên quan clipboard)

| Loại | Hàm | Ghi chú |
|---|---|---|
| 6 | `HandleViewerCutTextMessage` | `ClientCutText` chuẩn. Server có xử lý nhưng **bỏ qua** nếu `[session+0x60c]`, một biến toàn cục hoặc `[session+0xe22]` khác 0. Trong các phiên đo, gửi nó **không đổi** clipboard Mac (cả loopback lẫn LAN, cả Latin-1, UTF-8, MacRoman). Không dùng. |
| 11 (`0x0b`) | `HandleViewerClipboardRequest` | 8 byte. Byte 1 bit 0 = "chỉ xin promise". Byte 4-7 = mã server lặp lại. |
| 21 (`0x15`) | `HandleAutoPasteboardCommand` | 8 byte (`RFBAutoPasteboardMessage`). Số 16-bit big-endian ở offset 2, chỉ nhận 1 hoặc 2. Bật chế độ tự theo dõi clipboard. **Gửi 1 hoặc 2 rồi đổi clipboard Mac, server vẫn im** trong 10 giây. Chưa hiểu, **không dùng**. |
| 31 (`0x1f`) | `HandleViewerClipboardSend` | Gửi clipboard lên Mac, định dạng dưới đây. |
| 33 (`0x21`) | `HandleViewerInfoMessage` | Không liên quan clipboard (đã nhầm lẫn một lần: đừng gán theo khoảng cách địa chỉ, phải theo bảng nhảy). |

### Message loại 31 (hai chiều, cùng định dạng) [QS]

```
u8  31
u8  0
u8  cờ (bit 0 = "promise", quan sát 0)
u8  0
u32 mã                       (client chọn; server lặp lại trong câu trả lời ClipboardRequest)
u32 kích thước sau giải nén  (<= 100 MiB phía server)
u32 kích thước dữ liệu nén   (<= 100 MiB phía server)
... dữ liệu nén
```

Xác nhận: gửi `0b 00 00 00 de ad be ef`, nhận `1f 00 00 00 de ad be ef 00 00 01 e4 00 00 01 08 78 da ...` trong 0,5 giây.

Dữ liệu nén là **zlib mức 9 (`78 da`), kết thúc bằng sync flush, KHÔNG đóng luồng** (giải nén bằng `zlib.decompress` của Python báo "incomplete or truncated"; phải dùng `decompressobj`). Chiều ngược lại (client → server) cũng chấp nhận đúng dạng này.

### Payload sau giải nén [QS], số nguyên 32-bit big-endian

```
u32 số biểu diễn
mỗi biểu diễn:
    u32 độ dài, UTI                         ví dụ "public.utf8-plain-text"
    u32 flags                               luôn 0
    u32 số cặp thuộc tính
    mỗi cặp: u32 độ dài, khóa; u32 độ dài, giá trị
    u32 độ dài, dữ liệu
```

Với văn bản, server gửi ba biểu diễn theo thứ tự: `public.utf8-plain-text` (UTF-8), `com.apple.traditional-mac-plain-text` (MacRoman, **mất ký tự không biểu diễn được**), `public.utf16-plain-text` (**UTF-16 big-endian, không BOM**). Phân tích rồi mã hóa lại payload thật cho ra đúng từng byte (có test).

Client gửi lên chỉ cần UTF-8 + UTF-16: kiểm tra `pbpaste` sau đó trả đúng `Xin chào Việt Nam đệ ố ữ 🙂`.

### Chưa biết [CB]

- Điều kiện làm server bỏ qua `ClientCutText` chuẩn (ba cờ nói trên). Có thể là quyền "chỉ xem" của tài khoản hay một tùy chọn của phiên.
- Server có tự đẩy clipboard về client khi Mac thay đổi hay không, và bằng cách nào (loại 21 không đủ). Hiện chỉ dùng hỏi-đáp.
- Định dạng cho nội dung không phải văn bản (ảnh, tệp, RTF): chưa thử.

## 5. Còn lại của Pha 0

| Câu hỏi | Cách trả lời | Trạng thái |
|---|---|---|
| Type 33/35/36 là gì, client gửi gì đầu tiên | Đọc tiếp đoạn mã liên quan hoặc bắt gói client Apple từ máy khác | Chưa làm |
| Khác biệt giữa 30, 31, 32 | Cùng cách trên | Chưa làm |
| Hash và đệm của SRP | Cùng cách trên | Chưa làm |
| Encoding ID Apple dùng (cursor cache, DisplayInfo, MediaStream) | Cần xác thực xong, đọc `SetEncodings` của client | Chưa làm |
| Khung message HEVC và audio | Bắt gói + REA | Chưa làm (gate cho Pha 6) |

### Ràng buộc đã gặp

- **[QS]** Client Apple từ chối kết nối tới chính máy này (`You cannot control your own screen.`) và không mở socket, nên **không bắt gói được bằng loopback**. Cần Mac thứ hai nếu muốn bắt lưu lượng của client Apple.

## Cách tái hiện

```sh
swift run -q rfbprobe 127.0.0.1 5900               # liệt kê security type
swift run -q rfbprobe 127.0.0.1 5900 --select 30   # in hex dump phản hồi đầu tiên
```

Thăm dò clipboard (cần RFB_USER/RFB_PASSWORD; chỉ in nội dung khi bắt đầu bằng `rfbprobe-marker`, và **sao lưu rồi khôi phục clipboard Mac**
trước và sau):

```sh
rfbprobe HOST 5900 --login 30 --clipboard-probe 10 --clipboard-request                 # hỏi clipboard Mac
rfbprobe HOST 5900 --login 30 --clipboard-probe 4 --send-apple-clipboard "rfbprobe-marker-x"   # gửi lên Mac
```

Công cụ chỉ đọc version, danh sách type và phản hồi đầu tiên. Không bao giờ gửi mật khẩu hay thông tin đăng nhập.

## 4f. Encoding và định dạng pixel server Apple chịu (đo 2026-10-14, macOS 27.0.1, `rfbprobe --probe-encodings`)

| Yêu cầu của client (`SetEncodings`) | Server trả | Nhãn |
|---|---|---|
| ZRLE (16) | ZRLE | [QS] |
| Tight (7) + chất lượng JPEG 5 + ZRLE | **ZRLE** (Tight bị bỏ qua) | [QS] |
| Hextile (5) | **Raw** | [QS] |
| RRE (2) | **Raw** | [QS] |
| Zlib (6) | Zlib | [QS] |
| `SetPixelFormat` 16 bit RGB565 (redMax 31, greenMax 63, blueMax 31, shift 11/5/0) + Raw | Raw, **đúng 2 byte mỗi pixel** | [QS] |
| `SetPixelFormat` 16 bit + ZRLE | ZRLE (CPIXEL 2 byte), giải mã đúng màu (99,4-99,99% pixel trong ±8 so với 32 bit) | [QS] |
| `SetPixelFormat` 8 bit BGR233 | **Đóng kết nối** | [QS] |

[CB] Đổi `SetPixelFormat` **giữa phiên** có an toàn với server Apple không: chưa thử. Lý do không thử: RFB không đánh dấu cập nhật nào dùng định dạng nào, nên cập nhật đang bay lúc đổi có thể ở định dạng cũ. App chọn định dạng lúc kết nối.

## 4g. Message riêng của Apple cho hiển thị, cử chỉ và bàn phím (đọc từ binary + thử thật, 2026-10-14)

Bảng nhảy của bộ phân phối message. Các nhánh xử lý được viết **liền trong** hàm phân phối; tìm theo chuỗi log `Handle...` nằm trong từng nhánh.

| Loại | Hàm | Định dạng / hành vi | Nhãn |
|---|---|---|---|
| 8 | `HandleSetServerScalingMessage` | 10 byte: `[8][0][double IEEE 754 big-endian]`. Tỉ lệ phải trong (0, 1] (lệnh `fcmp`/`fccmp` từ chối ≤ 0 và > 1). Lưu ở `viewer+0x580`. | [QS] binary |
| 8 | (thử thật) | Tỉ lệ 0,5 → server trả **`DesktopSize` 1280x720** rồi **chờ**, không tự gửi lại toàn bộ hình; 0,75 → 1920x1080. Cập nhật sau đó ở toạ độ đã thu nhỏ. **Màn hình Mac không đổi**: chỉ luồng của người xem này nhỏ lại. Client phải xin lại một cập nhật **không tăng dần** ở cỡ mới. | [QS] thử thật |
| 8 | Toạ độ | Một hàm lá chia (x, y, rộng, cao) cho tỉ lệ khi cờ `viewer+0x57a` bật, được gọi từ nhánh loại 3 (FramebufferUpdateRequest): vùng xin cập nhật được đổi từ toạ độ người xem sang toạ độ thật. **Chưa tìm thấy** phép đổi tương tự trong nhánh loại 5 (PointerEvent: đọc x, y ở offset 2, 4, gọi (địa chỉ đã lược bỏ) rồi (địa chỉ đã lược bỏ)). App giả định toạ độ chuột cũng ở không gian người xem. **Chưa kiểm bằng thực nghiệm** (phải di chuột trên Mac thật). | [SL] |
| 29 | `HandleSetDisplayConfiguration` | Tiêu đề 12 byte: u16 big-endian "message size" ở offset 2 (tối thiểu 192), u16 "messageVersion" ở offset 4, u16 số màn hình ở offset 6 (tối đa 2, "resetting to 2"), u32 cờ ở offset 8; sau đó các `displayInfo` (cỡ mm, danh sách chế độ hiển thị, tần số quét). Tạo **màn hình ảo** (`SSAgentVirtualDisplay ... dynamicResolution:`), có tham số `blankScreen` (làm tối màn hình thật). **Không dùng**: đổi cấu hình màn hình của Mac. | [QS] binary, chưa thử |
| 23 | `HandleEventMessage2` | Cử chỉ, cuộn mượt. Định dạng: xem mục 4h. | [QS] binary + Mac thật (loại 3, 5, 11) |
| 26 | `HandleSetKeyboardInputSource` | Người xem báo bố cục bàn phím đang dùng. Định dạng chưa biết. | [QS] chuỗi |

Encoding riêng trong `HandleSetEncodingsMessage` (vùng địa chỉ đã lược bỏ): 1010 bật cờ "ScreenSharing/ProMode" (High Performance, video qua AVConference), 1107 "vendor keysyms supported", 1109 "keyboard input language encoding supported", 1100-1106 và 1110 chưa rõ. Có một bộ mã hóa có tổn hao riêng (`EncodeMultiVariant.c`, ô 8x8, có DCT) chưa biết số encoding. [QS] chuỗi, chưa thử.

ExtendedDesktopSize (-308) **không được hỗ trợ**: xin nó thì cập nhật đầu chỉ có ZRLE, không có hình chữ nhật -308 (`rfbprobe --probe-desktop-size`). [QS]

Hình con trỏ (-239): server **không gửi** cho một người xem chưa gửi sự kiện chuột nào (200 cập nhật đầu, cả 32 và 16 bit, `rfbprobe --probe-cursor`). Vì vậy chưa đo được server gửi pixel con trỏ ở định dạng nào khi client xin 16 bit. [QS]

## 4h. Message loại 23 (`HandleEventMessage2`): cử chỉ và cuộn mượt (đọc binary 2026-10-14, thử Mac thật 2026-10-15)

Đọc hai đầu: `screensharingd` (kiểm cỡ, đảo byte, chuyển nguyên payload qua MIG `SSAgent_PostGestureEvent_rpc`) và `ScreensharingAgent` (`agent_SSAgent_PostGestureEvent_rpc` trong lát arm64e, dựng `CGEvent` rồi `CGEventPost`). [QS] binary cho bố cục; **ngữ nghĩa vài trường là suy luận** [SL], vì chưa gửi thử vào Mac thật (cần người dùng cho phép).

**Khung**: `[23][cờ u8][u16 BE độ dài payload, < 50 001][payload]`. Cờ bit 0 = 1: cỡ tối thiểu tăng 8, ý nghĩa chưa rõ; gửi 0. Payload bắt đầu bằng `u16 BE phiên bản` và `u16 BE loại` (1…12); mọi số trong payload đều big-endian (server đảo trước khi chuyển). Payload ngắn hơn mức tối thiểu: server **đóng kết nối** ("message size too small %d %d closing connection"). Người xem đang ở chế độ chỉ xem: bỏ qua.

| Loại | Cỡ tối thiểu | Agent làm gì | Bố cục payload (offset: kiểu → nghĩa) |
|---|---|---|---|
| 1, 2 | 12 | sự kiện chuột (đường riêng, "lookup gesture") | 4: u32, 8: u16, 10: u16. Chưa giải |
| 3 | 16 (v1), 32 (v2) | `CGEvent` loại 29 (gesture), trường 110 = 8 (`kIOHIDEventTypeZoom`), trường 113 = độ phóng | 4: double → độ phóng (`magnification` của `NSEvent`); 12: u16 x; 14: u16 y (pixel framebuffer, đổi sang toạ độ màn hình bằng (địa chỉ đã lược bỏ)). v1: trường 133 = 4. v2 (phiên bản ≥ 2): 16: u64 → trường 132 ("phase"), 24: u64 → trường 133 ("mask") |
| 4 | 8 | gesture, trường 110 = 22, trường 133 = 2, log "zoom toggle" (phóng thông minh, chạm đúp hai ngón) | 4: u16 x; 6: u16 y |
| 5 | 16 (v1), 32 | gesture, trường 110 = 5 (`kIOHIDEventTypeRotation`), trường 114 = độ xoay | như loại 3 (4: double độ xoay, 12/14: x/y, v2 thêm phase/mask) |
| 6 | 48 | swipe/"fluid" ("x %f y %f motion %lld swipemask …") | 4…43: 10 số 32-bit; 44/46: x/y. Chưa giải |
| 8 | 32 | chưa đọc | 4…27: 6 số 32-bit; 28/30: x/y |
| 9 | 36 | "deprecated scroll wheel event" | bỏ, dùng loại 11 |
| 10 | 4 | không có dữ liệu | |
| 11 | 54 | `CGEvent` loại 22 (`kCGEventScrollWheel`), trường công khai | 4: s16 → `DeltaAxis2` (12, ngang, dòng); 6: s16 → `DeltaAxis1` (11, dọc); 8: s16 → `DeltaAxis3`; 10: s32 → `FixedPtDeltaAxis2` (94); 14: s32 → `FixedPtDeltaAxis1` (93); 18: s32 → `FixedPtDeltaAxis3` (95); 22: s32 → `PointDeltaAxis2` (97); 26: s32 → `PointDeltaAxis1` (96); 30: s32 → `PointDeltaAxis3` (98); 34: u32 → `ScrollPhase` (99); 38: u32 → `MomentumPhase` (123); 42: s32 → `ScrollCount` (100); 46: u32 cờ (bit 0 → trường 14 `InstantMouser`, bit 1 → trường 88 `IsContinuous`, bit 2 → trường 137); 50: u16 x; 52: u16 y |
| 12 | 22 | xử lý riêng trong `screensharingd` | chưa đọc |

Ý nghĩa cho app:
- **Cuộn mượt kiểu trackpad** (loại 11): gửi quãng theo point (`PointDelta`), pha cuộn (`kCGScrollPhase`: bắt đầu 1, đổi 2, kết thúc 4) và pha quán tính (`kCGMomentumScrollPhase`: bắt đầu 1, tiếp 2, kết thúc 3), cờ "liên tục". Mac tự cuộn mượt, bật nảy ở mép, như trackpad thật. Thay cho nấc bánh xe nút 4/5 của RFB chuẩn.
- **Chụm và xoay** (loại 3 và 5) cùng **phóng thông minh** (loại 4) có toạ độ: Preview, Bản đồ, Safari nhận như cử chỉ trackpad.

**Thử trên Mac thật** (macOS, màn hình 2560x1440 1x; một cửa sổ AppKit thử ghi `NSEvent`; `rfbprobe --apple-gesture-test`, `--apple-raw`): [QS]
- Loại 11: tới đủ. `scrollingDeltaY` = `PointDeltaAxis1` gửi (cùng dấu, cùng cỡ), `hasPreciseScrollingDeltas` = true. `kCGScrollPhase` 1/2/4 → `NSEvent.phase` began/changed/ended; quán tính 1/2/3 → `momentumPhase` began/changed/ended.
- Loại 3 và 5 **bản 1** (16 byte, không pha): server nhận, không đóng kết nối, nhưng **không ứng dụng nào nhận được sự kiện**.
- Loại 3 và 5 **bản 2** (32 byte): offset 16 u64 pha = 1 (began), 2 (changed), 4 (ended), như pha cuộn → `NSEvent.phase` began/changed/ended; `magnification`/`rotation` đúng bằng double gửi (xoay dương = ngược chiều kim đồng hồ). Offset 24 u64 "mask": 0, 2, 4, 8 cho cùng kết quả. App gửi bản 2, began và ended mang giá trị 0.
- Toạ độ x, y là pixel framebuffer như `PointerEvent`. Khi đang thu nhỏ phía server (loại 8) chưa rõ có đổi tỉ lệ không (cùng câu hỏi với `PointerEvent`).

