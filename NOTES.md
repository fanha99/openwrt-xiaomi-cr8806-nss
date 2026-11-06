# CR8806: ghi chép thử nghiệm RAM khi chạy NSS Wi-Fi offload

Branch `notes` chỉ chứa ghi chép, không chứa cây OpenWrt:
- `NOTES.md` (file này): các thử nghiệm RAM và Wi-Fi trên CR8806.
- `pr45-followup.md`: các bước test cho review PR 45 (tiếng Anh).
- `tools/`: script đo dùng trong hai file trên, và `tools/hzyitc2nss/` (converter cấu hình
  hzyitc -> bản DSA/NSS, xem mục 17).

Mỗi thử nghiệm một mục: sửa gì, vì sao, đo thế nào, kết quả. Code nằm ở các branch của
cây OpenWrt (bên dưới). Khi ổn định, code được cherry-pick sang `main`. Các commit
`DEBUG:` không đưa vào. Trước đây ghi chép nằm trong thư mục `cr8806-memtest/` của branch
`cr8806-memtest`. Lịch sử được giữ nguyên khi tách sang branch này.

Sau khi upstream nhận PR 50, 51 (`999-997`, fraglist GRO tắt), nss-packages PR 9 (0149) và
sửa issue 52 (`c3po-tag-8021q` 7930126b66), branch được dựng lại lần nữa:

1. `main` (nhánh mặc định của fork fanha99/openwrt-xiaomi-cr8806-nss): upstream + NSS 256M
   mặc định cho CR8806 + feed pin (nss lại là kuncy7, đã có 0149) + README trang đầu +
   ring RXDMA 1024 cho QCN6122 (mục 14, đã gửi PR). Release tag ở đây.
2. `testing`: `main` + những gì đang thử, hiện là `999-998` (mục 10). Thử ổn mới
   cherry-pick sang `main`.
3. `cr8806-memtest`: `testing` + `DEBUG: ... enable page_owner` (mục 3). Chỉ để đo, không
   gộp.
4. `notes`: ghi chép này.

Các bản dựng trước chỉ còn ở máy local (`archive/cr8806-memtest-v1`, `-v2`,
`-20261026`). Bản ngày 2026-10-26 tương ứng tag `cr8806-nss-2026.10.26`.

Phần qca-nss-drv dùng thẳng kuncy7/nss-packages `ipq50xx-rebase` (đã có profile
`NSS_MEM_PROFILE_LOW` cho CR8806 từ PR 7 và 0149 từ PR 9). Fork fanha99/nss-packages chỉ
còn giữ cho các tag release cũ.

## Phần cứng và cách đo

- Xiaomi CR8806: IPQ5018 + QCN6122, 256 MiB RAM (kernel thấy 169 MiB, 90 MiB bị giữ lúc
  boot cho NSS, Q6, TZ...). NSS offload bật cho cả Ethernet và Wi-Fi.
- Bài test: client là laptop Windows nối Wi-Fi 5 GHz HE160 (kênh 36, đứng gần AP), server
  là máy cắm dây trong LAN; `iperf3 -P 4 -t 60`, một chiều lên, một chiều xuống
  (`-R`), nghỉ 60 s. Một "lượt" = cả ba phần. Client bind vào IP Wi-Fi (`-B`) để chắc
  chắn đi qua Wi-Fi (đã kiểm tra bằng bộ đếm byte của station và của cổng LAN).
- `tools/memsample.sh`: chạy trên router (qua ssh), mỗi 2 s in MemAvailable, Slab,
  SUnreclaim, page cache, phần "không tên" (MemTotal trừ mọi counter đã biết), số payload
  NSS đang giữ (`drv_nss_skb_count`, `n2h_n2h_tot_payloads`) và `rx_desc_alloc_fail`.
- `tools/run-rounds.sh`: chạy 4 lượt từ WSL, chụp `/proc/meminfo` + page_owner trước và
  sau mỗi lượt. `tools/win-wifi-up.sh` nối lại Wi-Fi của laptop (sau mỗi lần router reboot
  laptop không tự vào lại).
- `tools/page-owner-top.py`, `tools/page-owner-diff.py`: tổng hợp và so sánh
  `/sys/kernel/debug/page_owner_stacks/show_stacks` theo call stack.

Đọc số: mỗi payload NSS là một object 4 KiB, nên "slab thuần" = SUnreclaim − payload × 4 KiB.

## 1. Đối chứng: b0aa337 + `ATH11K_MEM_PROFILE_256M` (chọn tay)

Profile ath11k 256M, `NSS_MEM_PROFILE_LOW`, chưa có profile NSS 256M.

| | trước | lượt Wi-Fi→LAN | lượt LAN→Wi-Fi | sau |
|---|---|---|---|---|
| MemAvailable (MiB) | 6-10 | 5-9 | **1-6** | 1-4 |
| SUnreclaim (MiB) | 45 | 47 | 54-60 | 52-54 |
| payload NSS giữ | ~4500 | 5100-5500 | **7200-8700** | ~4900 |
| rx_desc_alloc_fail | 899 | +590 | | |

- LAN→Wi-Fi: phía dây đẩy nhanh hơn Wi-Fi phát, gói xếp hàng trong hàng đợi TX Wi-Fi
  của NSS (8192 descriptor mỗi radio), mỗi gói giữ một payload 4 KiB của host.
- Sau mỗi lượt slab thuần tăng ~7 MiB và không về; đo lặp lại thì RAM "tụt dần".

## 2. `ATH11K_NSS_MEM_PROFILE_256M=y`

Sửa: bật profile có sẵn trong `patches/nss-extra/ath11k/999-991..995` (TX descriptor và
giới hạn TX theo radio 8192 → 4096, TX completion 4096, bỏ mảng TX phía host, cache
page-frag RX riêng, CE5 256). Vì sao: chặn đúng hàng đợi TX Wi-Fi ở mục 1.

Kết quả (6 lượt, upload 667-798, download 892-934 Mbit/s):

| | đối chứng | profile NSS 256M |
|---|---|---|
| payload giữ khi LAN→Wi-Fi | 7200-8700 | 5100-6700 |
| MemAvailable thấp nhất khi chạy | 0.9 MiB | 6.4 MiB |
| slab thuần qua các lượt | +7.4 MiB/lượt | đi ngang 26-29 MiB |
| MemAvailable khi nghỉ sau test | 1-4 MiB | ~11.5-12 MiB |

Phụ: radio 5 GHz báo `tx_desc_alloc_fail` ~1.25 triệu (hàng đợi đầy thì firmware từ chối
thay vì giữ RAM; TCP chỉ retransmit 45 lần/60 s), `rx_desc_alloc_fail` tăng ~10-30 nghìn
mỗi lượt upload (pool descriptor RX của NSS, 3 × 512; host không thiếu payload).

Đưa vào `cr8806-pr`: CR8806 vào default của `ATH11K_MEM_PROFILE_256M` (trước đó không có,
build mới sẽ ra profile 1G) và `ATH11K_NSS_MEM_PROFILE_256M`. `NSS_MEM_PROFILE_LOW` nằm
trong feed nss-packages: trước phải chọn tay, giờ có commit riêng (kuncy7/nss-packages#7).

## 3. page_owner: phần nào giữ RAM sau tải

Commit `DEBUG:` trên branch này: `CONFIG_PAGE_OWNER` + `page_owner=on` (tốn ~4.5 MiB
`page_ext`). So sánh show_stacks trước test và sau 4 lượt:

- Tăng duy nhất đáng kể: **+8.7 MiB** ở `__alloc_skb <- ... <- nss_core_handle_napi_non_queue`,
  tức payload host cấp cho pool bộ đệm trống của firmware NSS (patch 0105 của qca-nss-drv,
  `alloc_skb` → `kmalloc-4096`).
- Trong đó: firmware giữ nhiều payload hơn sau tải (~3500 → 4861, ~+5 MiB, giảm dần khi
  nghỉ) và **phân mảnh slab**: `kmalloc-4k` có 396 slab order-3 dở dang chứa 2168 object,
  ~1000 ô trống ≈ 4 MiB không ai dùng được.
- Giảm: page cache (~−20 MiB, bị đẩy ra), buffer CE của ath11k (~−2 MiB).
- Mốc boot còn đáng xem: buffer CE ath11k ~13 MiB, link descriptor ath11k 8 MiB (DMA),
  2 page pool stmmac × 2 MiB (eth0, eth1, RX 512), atomic pool `coherent_pool=2M` 6 MiB,
  zstd stream 4 MiB (chưa rõ ai dùng).

## 4. qca-nss-drv: payload pool bộ đệm trống bằng nguyên một trang

Sửa (nss-packages, patch `0149-nss_core-back-fw-empty-buffer-payloads-with-whole-pages`):
`alloc_page()` + `build_skb()` thay cho `alloc_skb()`; payload 2368 byte vẫn vừa một trang,
chi phí mỗi payload không đổi, trang trả lại ngay khi skb được giải phóng. Payload không
vừa một trang (MRU jumbo) vẫn dùng kmalloc. Vì sao: bỏ phần ~4 MiB kẹt trong slab dở dang
ở mục 3, và bỏ việc phải cấp khối order-3 trong ngữ cảnh atomic.

Kết quả (4 lượt, cùng bản debug page_owner, cùng profile NSS 256M; upload 718-773,
download 931-940 Mbit/s, không lỗi NSS trong dmesg):

| | không 0149 (trước → sau 4 lượt) | có 0149 (trước → sau 4 lượt) |
|---|---|---|
| page_owner: payload pool bộ đệm trống (MiB) | 16.1 → 25.4 | 14.3 → 15.6 |
| page_owner: `pskb_expand_head <- skb_segment_list` (MiB) | 0 → 0.4 | 0.1 → 7.6 |
| SUnreclaim (MiB) | 36 → 46 | 22 → 31 |
| MemFree + Cached (MiB) | 49 → 33 | 49 → 31 |
| MemAvailable (MiB) | 16 → 9 | 14 → 6-7 |

- Payload pool bộ đệm trống không còn phình: patch làm đúng việc của nó.
- **Nhưng RAM dùng được không khá hơn.** SUnreclaim thấp hơn ~14 MiB chỉ là đổi chỗ
  ghi sổ: payload giờ là trang rời, không còn tính vào slab. MemFree + Cached gần như
  bằng nhau ở cả hai bản.
- Phần phân mảnh `kmalloc-4k` chuyển sang chỗ khác: sau test vẫn còn ~267 slab order-3
  dở dang, chứa ~930 object. page_owner gán các slab này cho ai tạo ra chúng trước, ở đây
  là các segment GSO fraglist của đường chậm (`rx-gro-list` bật trên eth0, eth1,
  br-lan; ~106 nghìn gói `ipv4_tcp_no_icme` đi qua Linux trước khi ECM tăng tốc luồng).
  Object sống lâu (buffer RX CE của ath11k...) nằm lại trong đó nên slab không trả về
  được. Sau 5 phút nghỉ vẫn giữ 7.6 MiB. Tăng 4.8 → 6.3 → 7.3 → 7.6, chậm dần, giống
  phân mảnh hơn là leak.
- Kết luận lúc đó: chưa đưa 0149 vào branch chính. Muốn có lợi thật phải giảm việc trộn
  object sống ngắn và sống lâu trong `kmalloc-4k`, không chỉ riêng payload NSS (mục 5-6).

## 5. Tắt fraglist GRO (`rx-gro-list`) trên bản 0149

Sửa (lúc chạy, không lưu): `ethtool -K <if> rx-gro-list off` cho eth0, eth1, các cổng
LAN, br-lan, các VLAN của bridge và 3 interface Wi-Fi. Fraglist GRO được bật mặc định cho
mọi interface bởi `target/linux/generic/hack-6.18/600-net-enable-fraglist-GRO-by-default.patch`.
Vì sao: ở mục 4, các slab `kmalloc-4k` dở dang được tạo bởi `skb_segment_list`, tức các
gói đường chậm bị gộp thành fraglist rồi cắt lại lúc gửi. Khi NSS đã nắm data plane thì
fraglist GRO chỉ còn tác dụng với vài nghìn gói đầu của mỗi luồng.

Đo lại sau reboot (cùng điểm xuất phát ~9 phút uptime như mục 4), 4 lượt, upload
682-825, download 888-939 Mbit/s:

| sau 4 lượt | không 0149 | 0149 | 0149 + tắt fraglist GRO |
|---|---|---|---|
| SUnreclaim trước → sau (MiB) | 36 → 46 | 22 → 31 | **21 → 24** |
| MemFree + Cached sau (MiB) | 33 | 31 | **37** |
| MemAvailable sau (MiB) | 9 | 6 | **13** |
| page_owner `skb_segment_list` (MiB) | 0.4 | 7.6 | 0 |
| `kmalloc-4k` slab dở dang | 396 | 267 | **42** |

- Hết phân mảnh slab: SUnreclaim gần như đứng yên qua 4 lượt. Payload pool bộ đệm
  trống dao động 14-19 MiB và trả bớt khi nghỉ.
- Throughput không giảm (upload còn nhỉnh hơn), dmesg không có lỗi NSS.
- MemAvailable khi đang chạy vẫn xuống 7-11 MiB. Đó là payload firmware NSS giữ trong
  hàng đợi lúc có tải, nghỉ thì lấy lại.
- Mới đo một lần. Cần chạy lại để biết độ dao động, và thử tắt fraglist GRO trên bản
  không có 0149 để biết mỗi thay đổi đóng góp bao nhiêu (mục 6).

## 6. Tắt fraglist GRO trên bản không 0149

Cùng cách làm như mục 5 (reboot, ~9 phút uptime, tắt `rx-gro-list` mọi interface), trên
bản debug không có 0149. Upload 531 (lượt 1, Wi-Fi dao động) rồi 747-753, download
893-931 Mbit/s.

So sánh cả bốn, cùng bản debug page_owner, cùng profile NSS 256M, mỗi ô một lần đo:

| | không 0149 | không 0149 + tắt GRO | 0149 | **0149 + tắt GRO** |
|---|---|---|---|---|
| MemFree + Cached trước → sau (MiB) | 49 → 33 | 53 → 38 | 49 → 31 | **46 → 37** |
| mất qua 4 lượt (MiB) | 16 | 15 | 18 | **9** |
| SUnreclaim trước → sau (MiB) | 36 → 46 | 35 → 46 | 22 → 31 | **21 → 24** |
| page_owner payload pool bộ đệm trống (MiB) | 16 → 25 | 14 → 24 | 14 → 16 | 14 → 18 |
| MemAvailable sau (MiB) | 9 | 10 | 6 | 13 |

- Mỗi thay đổi đứng riêng không giúp gì: chỗ phân mảnh `kmalloc-4k` chỉ chuyển từ payload
  NSS (không 0149) sang segment fraglist (không tắt GRO), hoặc ngược lại.
- Cả hai cùng lúc thì lượng RAM mất qua 4 lượt giảm một nửa (9 so với 15-18 MiB), và slab
  không tăng.
- Không 0149 thì payload pool tăng ~9 MiB dù số payload firmware giữ gần như không đổi
  (~4250): phần chênh là ô trống trong slab order-3 dở dang.

## 7. Bản thường: 0149 + fraglist GRO tắt sẵn trong image

Sửa: commit `qualcommax: ipq50xx: cr8806: turn fraglist GRO off by default` (file
`base-files/etc/uci-defaults/15_cr8806_ecm_gro_list`). ECM vốn đã có tuỳ chọn
`ecm.general.disable_gro_list` (mặc định 0), script hotplug `net` và init của ECM áp nó cho
mọi interface vật lý. Commit chỉ bật tuỳ chọn đó cho CR8806. Build từ `cr8806-pr` + commit
này, không có commit `DEBUG:` (không page_owner), qca-nss-drv có 0149.

Sau khi flash (giữ config), không gõ `ethtool` tay: eth0, eth1, lan1-3, wan và 3 interface
Wi-Fi tự `rx-gro-list off`. br-lan và các VLAN của nó vẫn `on` (không phải interface vật
lý), và cũng không cần: GRO chạy ở interface nhận.

4 lượt, upload 788-841, download 933-940 Mbit/s (tốt nhất trong các lần đo):

| | trước | lượt 1 | lượt 2 | lượt 3 | lượt 4 |
|---|---|---|---|---|---|
| MemAvailable (MiB) | 18 | 12 | 13 | 12 | 12 |
| MemFree / Cached (MiB) | 24 / 29 | | | | 25 / 15 |
| SUnreclaim (MiB) | 21 | 23 | 23 | 23 | 23 |

- Sau test: `kmalloc-4k` chỉ còn 4 slab dở dang (bản đối chứng 396), payload NSS 4266,
  dmesg không có lỗi NSS.
- MemAvailable xuống một nấc sau lượt đầu (payload firmware giữ, page cache bị đẩy bớt)
  rồi đứng yên 12-13 MiB, không còn tụt dần theo từng lượt. Page cache còn 15 MiB sau 4
  lượt, các bản debug chỉ còn 5-6 MiB.
- Không có page_owner nên MemAvailable lúc đầu cao hơn các bản debug ~4.5 MiB (`page_ext`).

## 8. Hạ pool bộ đệm trống của firmware NSS: 4096 → 2048 (lúc chạy, không lưu)

Sửa: `sysctl -w dev.nss.n2hcfg.n2h_empty_pool_buf_core0=2048`. Giá trị 4096 đến từ
`NSS_LOW_MEM_EMPTY_POOL_BUF_SZ` (profile LOW); sysctl này ghi được lúc chạy, driver gửi
`N2H_EMPTY_POOL_BUF_CFG` cho firmware và chờ ACK. Vì sao: lúc nghỉ firmware giữ ~4200
payload × 4 KiB ≈ 16 MiB, phần lớn nhất trong page_owner sau buffer CE ath11k.

Bản thường (PR 45 + `coherent_pool=512K`), uptime ~17 giờ. Lần này laptop đặt xa AP
hơn 6 m (tín hiệu -65..-70 dBm, ~360-550 Mbit/s mỗi chiều), nên throughput không so được
với các mục trước. Đối chứng 4096 chạy 4 lượt ngay trước đó ở cùng chỗ.

| | 4096 (đối chứng) | 2048 |
|---|---|---|
| payload firmware giữ lúc nghỉ | ~4200 (`payload_free_count` ~2100-2270) | ~2100 (`payload_free_count` 0) |
| MemAvailable lúc nghỉ (MiB) | 12-16 | 20 (+7.5 MiB ngay sau khi đổi) |
| `n2h_payload_alloc_fails` | 8, không tăng qua 4 lượt | tăng ngay khi nghỉ, 3.2 triệu sau ~1 phút tải |
| lượt upload đầu tiên | 357 Mbit/s | **0 byte**, laptop rớt Wi-Fi |

- Firmware trả payload về ngay khi đổi (skb 4834 → 2096 trong 10 s), nên phần RAM này
  đúng là do pool giữ.
- Nhưng ở 2048 firmware hết payload trống: số firmware đang dùng lúc nghỉ đã ~2100, không
  còn dư. Gói bị bỏ, traffic dừng. Trả về 4096 thì chạy lại bình thường (401/491 Mbit/s).
- Ngay ở 4096, lúc LAN→Wi-Fi `payload_free_count` xuống ~560 và có vài chục lần alloc
  fail. Biên ở 4096 đã mỏng; một giá trị giữa (vd. 3072) chỉ lấy được ~4 MiB với rủi ro
  cạn pool khi tải, nên không theo hướng này.

Kết luận: không hạ pool. Giữ 4096.

Vì sao 2048 làm cạn (đọc lại 2026-11-06): vì 2048 **đúng bằng** ngưỡng low water của firmware.
Trên máy đang chạy: `dev.nss.n2hcfg.n2h_empty_pool_buf_core0` = 4096 (kích thước pool),
`n2h_low_water_core0` = 2048, `n2h_high_water_core0` = 16336. Ba giá trị water mark này do
firmware NSS báo về (`nss_n2h.c`, callback `nss_n2h_payload_stats_callback()` xử lý
`NSS_TX_METADATA_TYPE_GET_WATER_MARK`), không phải hằng số của host. Đặt pool = low water nghĩa
là firmware luôn ở hoặc dưới ngưỡng cấp bù, không bao giờ còn payload trống — khớp đúng với
`payload_free_count` = 0 và alloc fail tăng ngay lúc nghỉ. Driver không chặn: handler của sysctl
chỉ kiểm `*new_val < NSS_N2H_MIN_EMPTY_POOL_BUF_SZ` (= 32), không so với low water. Muốn thử lại
thì phải hạ `n2h_low_water_core0` trước, và pool phải còn dư trên ngưỡng đó; vẫn không đáng vì
mục 8 cho thấy biên ở 4096 đã mỏng.

## 9. Thu nhỏ ring RX stmmac lúc chạy: `ethtool -G eth1 rx 64`, rồi eth0

Vì sao: eth0 và eth1 mỗi cái có page pool 2 MiB (RX 512), nhưng sau 15 giờ eth0 nhận 0
gói, eth1 210 gói: NSS nắm data plane, ring của host không dùng.

Kết quả: router mất hẳn đường dữ liệu. Không ping được từ LAN, cắm dây vào cổng LAN không
nhận DHCP, Wi-Fi vẫn phát và client vẫn nối được nhưng không có IP. Đèn vẫn bình
thường, router không reboot. Phải rút điện; sau boot ring về 512, mọi thứ chạy lại (giá
trị `ethtool` không lưu).

Nguyên nhân (đọc code, chưa có log vì `/tmp` mất khi rút điện): patch
`0956-net-stmmac-add-a-data-plane-claim-API-for-the-NSS-firmware` cho qca-dwmac-nss
"claim" GMAC: dừng DMA của host, tắt NAPI và IRQ, firmware NSS chạy DMA bằng ring riêng.
Buffer RX của host "stay allocated but unused". `ethtool -G` gọi
`stmmac_reinit_ringparam()`, tức `stmmac_release()` + `stmmac_open()`, trong khi claim
vẫn giữ: DMA của host khởi động lại trên cùng controller firmware đang dùng. Claim không
chặn việc đổi ring.

- Bổ sung sau khi đọc `qca-dwmac-nss`: kuncy7 đã gặp đúng kiểu lỗi này khi đổi MTU. Comment
  ở `NETDEV_PRECHANGEMTU` trong `dwmac_nss_netdev_event()` nói `__stmmac_release()` trên GMAC
  đang claim gọi `napi_disable()` lần thứ hai, "blocks forever with rtnl held". Với MTU
  module trả GMAC lại trước; `ethtool -G`/`-L` không phát sự kiện netdev nào nên không được
  bảo vệ. Treo khi giữ rtnl khớp với việc router không reboot nhưng mạng không lên lại.
- Không thử được lúc chạy. Muốn lấy lại ~4 MiB phải sửa ở phía claim: giải phóng buffer
  RX của host khi claim (cấp lại khi release, vốn đã phải bounce interface), hoặc ring nhỏ
  từ lúc probe.
- Phần `-EBUSY` **đã xong và đã nằm trong bản đang chạy** (phát hiện lại 2026-11-06, mục này
  trước đó vẫn ghi là việc cần làm): kuncy7 nhận báo và viết
  `0958a-net-stmmac-refuse-ring-and-channel-changes-on-a-claimed-GMAC.patch` ngày 2026-10-26
  (commit `f6afff4714` trong fork, "Reported-by: fanha99", link issue 52). Chốt nằm sâu hơn
  mức ethtool: `stmmac_reinit_queues()` và `stmmac_reinit_ringparam()` gọi
  `stmmac_reinit_refuse_claimed()` và trả `-EBUSY` + `netdev_warn` khi `priv->dp_owner` còn
  giữ. Nên đừng viết lại lần nữa — tôi đã viết trùng một bản ở tầng ethtool rồi phải bỏ.

## 10. ath11k: cache riêng cho mỗi pipe CE, link descriptor cho 32 client, BPF JIT

Ba commit, build cùng bản debug page_owner, trên cây của PR 45 (`coherent_pool=512K`, 0149,
fraglist GRO tắt):

1. `999-997-ath11k-nss-256m-ce-rx-fragment-caches.patch`. Buffer RX của CE (2048 byte)
   lấy từ `dev_alloc_skb()`, tức cache page-fragment chung theo CPU, 13 buffer trong một
   chunk 32 KiB, chunk chỉ trả lại khi cả 13 được giải phóng. Ở mục 3, page_owner gán
   16-18 MiB cho việc nạp lại buffer CE (lúc boot chỉ ~1.3 MiB), trong khi số buffer
   thật là 800 mỗi radio (CE1 512, CE2 32, CE5 256), ~3.7 MiB cả hai radio. Không driver
   nào khác dùng cache này: các pipe tự trộn với nhau. CE1 (HTT) nạp liên tục, CE2 (WMI)
   và CE5 (pktlog) hiếm khi; một buffer của pipe chậm giữ cả chunk buffer HTT đến khi pipe
   đó quay vòng. Sửa: trong profile NSS 256M, mỗi pipe một `page_frag_cache` riêng, cấp
   dưới `ce_lock` (vốn đã khoá việc nạp), drain khi dọn pipe.
2. `999-998-ath11k-nss-256m-link-descriptors.patch`. Pool link descriptor WBM tính cho 64
   client × 2 TID: 18560 descriptor, làm tròn 32768 × 128 byte = 4 MiB DMA mỗi radio.
   Profile NSS 256M tính cho 32 client: 9279 → 16384, 2 MiB mỗi radio.
3. `16_cr8806_bpf_jit_off` (uci-defaults ghi `net.core.bpf_jit_enable=0` vào sysctl.d).
   **Không có tác dụng**: chương trình BPF duy nhất là `ptp_classifier_init`, kernel tạo
   và JIT trong `sock_init` lúc boot, trước mọi sysctl. Vùng `bpf_prog_pack` 2 MiB vẫn
   còn. Muốn bỏ phải tắt `CONFIG_BPF_JIT` trong kernel config, mà config đó dùng chung cho
   mọi board ipq50xx. Bỏ commit này khi gộp.

Đo: flash slot 1 (giữ config), page_owner lúc 9 phút uptime, rồi 4 lượt như mục 4-6,
laptop gần AP (-33 dBm, HE160 MCS 11).

page_owner lúc nghỉ, 9 phút uptime (MiB):

| | mục 5 (0149 + tắt GRO, `coherent_pool=2M`) | mục 10 |
|---|---|---|
| buffer RX của CE | 17.9 | **4.3** |
| link descriptor | 8.1 | **4.1** |
| atomic pool (`coherent_pool`, PR 45) | 6.0 | 1.5 |
| DP RX / monitor (cache riêng của 993) | 3.6 | 3.5 |
| payload pool bộ đệm trống NSS | 14.3 | 14.4 |
| page cache | 24.8 | 36.5 |
| MemAvailable | 14.2 | **25.2** |

4 lượt: upload 780-812, download 930-943 Mbit/s (bằng các lần trước).

| | trước | lượt 1 | lượt 2 | lượt 3 | lượt 4 |
|---|---|---|---|---|---|
| MemAvailable (MiB) | 24 | 21 | 26 | 21 | 22 |
| MemFree / Cached (MiB) | 25 / 37 | 23 / 36 | 28 / 36 | 23 / 36 | 24 / 35 |
| SUnreclaim (MiB) | 22 | 23 | 23 | 23 | 24 |

- Buffer CE đứng yên 4.32 MiB qua 4 lượt (mục 5 sau 4 lượt: 14.3). Link descriptor 4.07.
- Sau 4 lượt page cache còn 35 MiB (bản debug ở mục 5: 5 MiB), MemAvailable thấp nhất khi
  đang chạy 18 MiB (mục 5: 7-11). Đây là bản debug, bản thường còn thêm ~4.5 MiB
  (`page_ext`).
- Không lỗi ath11k/NSS trong dmesg. `rx_desc_alloc_fail` của radio 5 GHz +127 nghìn qua 4
  lượt, cùng cỡ với mục 2 (pool descriptor RX của NSS, không phải RAM host).
- `n2h_payload_alloc_fails` tăng một đợt 36 → 1180 lúc đầu lượt upload thứ 4 (MemFree
  ~18 MiB, gần `min_free_kbytes` 16 MiB), không tăng nữa; throughput lượt đó vẫn 790. Các
  bản trước đếm 8-34 cho cả bài test. Cần xem lại trên bản thường.

Kết luận: 999-997 và 999-998 lấy lại ~17.5 MiB lúc nghỉ, không giảm throughput.

## 11. Bản thường (999-997 + 999-998) và A/B chiều nhận với bản PR 45

Build `cr8806-main` (không page_owner) với hai patch ath11k ở mục 10, flash slot 0. Bản
đối chứng: bản PR 45 512K, flash slot 1.

4 lượt (9 phút uptime, laptop gần AP), so với bản PR 45 512K đo cùng cách:

| MemAvailable (MiB) | trước | sau lượt 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| PR 45 512K | 19.2 | 15.4 | 18.4 | 15.9 | 14.5 |
| 999-997 + 999-998 | **28.5** | 27.4 | 25.9 | 24.4 | 22.5 |

Page cache sau 4 lượt 36 MiB (bản PR 45: 20). `n2h_payload_alloc_fails` không tăng (34),
dmesg sạch. Download 900-931 Mbit/s; upload chỉ 388-690.

Upload thấp nên kiểm tra 999-998: REO và RXDMA dùng link descriptor khi nhận. Trên radio
5 GHz có `RXDMA Overflow` và `REO Frame OOR` tăng mỗi lần upload. A/B ngay sau boot (~2.5
phút uptime), 3 lượt upload 30 s + 1 download, laptop -33..-39 dBm:

| | PR 45 512K | 999-997 + 999-998 |
|---|---|---|
| upload (Mbit/s) | 652 / 657 / 652 | 679 / 692 / 634 |
| download (Mbit/s) | 926 | 920 |
| `RXDMA Overflow` sau 3 lượt | 40972 | 36745 |
| `REO Frame OOR` sau 3 lượt | 31400 | 26669 |
| MemAvailable trong lúc đo (MiB) | 15-22 | 25-35 |

- Hai bản như nhau ở chiều nhận; overflow có cả ở bản cũ. 999-998 không làm thiếu link
  descriptor với một client. Upload hôm đó thấp ở cả hai bản (sóng/laptop), không do patch.
- Chưa thử nhiều client cùng lúc.

## 12. Bản kuncy nhờ chạy: upstream 7930126b66 + `ATH11K_NSS_MEM_PROFILE_256M` (PR 50)

Build đúng cách release của upstream: `.github/ci/ipq50xx/common.config` + `256m.config` +
`CONFIG_ATH11K_NSS_MEM_PROFILE_256M=y`, không LuCI, không `999-998`. Flash slot 0, chạy dài
với `memlong.sh` (mỗi 10 phút: meminfo, payload NSS, số client, `reo_reaped`,
`tx_desc_alloc_fail`, `Frame OOR` của hai radio) và `climon.sh` (mỗi phút mỗi client: tín
hiệu, byte, ping IPv6 link-local; sự kiện hostapd/ath11k/NSS).

Sau 12,5 giờ, 3 client 5 GHz (một client xem camera liên tục 1,3-2,4 Mbit/s). Tải nhẹ: khoảng 7,5 giờ có lưu lượng, ban đêm gần như không có gì, không có đợt dồn dập (xem mục 13):
- MemAvailable 16,5-25 MiB theo tải, `SUnreclaim` về lại 23,3 MiB khi rảnh.
- `n2h_payload_alloc_fails` 36, tất cả trong 2 phút đầu, sau đó không tăng.
- 5 GHz: `Frame OOR` 11.138, `tx_desc_alloc_fail` 58.758 / 3,81 M TX (1,5 %). Chưa có số
  đối chứng không profile.
- Issue 53 (QCN6122 ngừng nhận client sau 3-14 giờ): chưa gặp, `reo_reaped` vẫn tăng,
  client mới vào được ở 9,9 và 11,1 giờ.

`simulate_fw_crash` (12,7 giờ): trên IPQ5018 hai radio là hai user PD trên cùng một Q6, nên
assert radio nào cũng là lỗi root PD. q6wcss khởi động lại trong 0,15 s, cả hai radio
khôi phục. Client 5 GHz vào lại sau 4-35 s. Không mất bộ nhớ, payload fail không tăng.
Lần assert 5 GHz thiếu dòng `successfully recovered` vì `__ath11k_warn()` bị
ratelimit sau 11 cảnh báo WMI -108 lúc firmware đang tắt.

## 13. Tải nặng 5 GHz cho issue 53 (ring RXDMA 512)

Issue kuncy7/openwrt-nss-edma#53: trên AX53 v2 (cũng QCN6122, 256 MB), sau 3-14 giờ 5 GHz
ngừng nhận. Khoảng 800 buffer RX vào phần cứng rồi không ra, `rx_desc_in_use` 1324. kuncy
nghi ring RXDMA/refill 512 phần tử (patch 999-990) bị cạn khi có đợt dữ liệu dồn dập.

Cùng bản ở mục 12, uptime 14,5 giờ. 5 lượt, mỗi lượt: upload `-P 8` 60 s, upload `-P 4`
60 s, download `-P 4` 60 s, nghỉ 60 s. Một client HE160 ở xa hơn các lần trước (−67 đến
−74 dBm), server cắm dây.

| | trước | sau 5 lượt |
|---|---|---|
| `reo_reaped` 5 GHz | 2.769.683 | 47.290.877 |
| `rx_desc_in_use` | 511 | 511 ở mọi lần chụp |
| `rxdma_hw_desc_unavailable` / `rx_desc_alloc_fail` | 0 / 0 | 0 / 0 |
| RXDMA `Overflow` | 1.721 | 171.850 |
| REO `Frame OOR` | 12.635 | 58.275 |
| MemAvailable | 19 MiB | 13-25 MiB trong lúc chạy, 24 MiB sau |
| `kmalloc-4k` partial | 39 | 3-115 trong lúc chạy, 18 sau |
| `tx_desc_alloc_fail` 5 GHz | 58.758 | 9.300.862 |

- Upload 357-455 Mbit/s, download 639-740 Mbit/s. Thấp hơn các lần trước vì client xa
  hơn (PHY 0,5-1,4 Gbit/s).
- Ring 512 có tràn: `Overflow` tăng khoảng 170 nghìn, toàn bộ trong các phút upload.
  Nhưng lần nào cũng hồi phục, không kẹt.
- Số buffer "bị giữ" (`rxdma_buf_replenished` − `reo_reaped` − `wbm_src_dma` −
  `wbm_src_reo`):
  - Trước hai lần crash là 517.
  - Ngay sau hai lần crash là 1.539. Mỗi lần firmware khởi động lại nạp lại ring (+511),
    còn bộ đếm không reset.
  - Trong lúc tải nặng, số này trôi thêm khoảng 165 sau 44 triệu khung, trong khi
    `rx_desc_in_use` vẫn 511.
  - Kết luận: dựa vào `rx_desc_in_use`, không dựa vào hiệu số.
- `tx_desc_alloc_fail` 5 GHz (wifili hết TX descriptor khi gửi gói ra Wi-Fi) tăng khoảng
  9,2 triệu, chỉ trong lúc tải nặng. Trước đó đứng ở 58.758 từ sáng; sau đó 2,5 giờ dùng
  bình thường không tăng thêm.
  - `memlong.sh` lấy mẫu 10 phút một lần, nên không tách được upload với download:
    10:40-10:50 (lượt 1, phần lớn lượt 2) +247 nghìn; 10:50-11:00 (hết lượt 2, lượt 3, 4)
    +6,4 triệu; 11:00-11:10 (lượt 5) +2,6 triệu. Download (LAN → Wi-Fi) là nguồn TX lớn
    nhất nên dễ là nguyên nhân, nhưng chưa chứng minh; upload cũng gửi ACK TCP ra Wi-Fi.
  - Đính chính (mục 14): `tx_desc_alloc_fail` đếm số lần thử cấp phát, không đếm gói. Ở
    2.4 GHz nó tăng 24 triệu trong một phút download ~85 Mbit/s (~400 nghìn/s, trong khi
    chỉ ~7 nghìn gói/s). Nên chỉ xem có tăng hay không, độ lớn không có ý nghĩa.
  - Bản này bật `ATH11K_NSS_MEM_PROFILE_256M`, profile giới hạn pool TX descriptor ở
    4096 (`ATH11K_NSS_256M_TX_DESC_LIMIT`, patch 999-992).
    Chưa biết có phải do profile không: cần chạy cùng tải trên bản không profile (A/B ở
    "Việc còn lại"), và lần sau ghi `tx_desc_alloc_fail` theo từng phút (thêm vào
    `rxsnap.sh`).
- Đã gửi lên #53. `memlong.sh` trên router tự lưu danh sách kuncy cần nếu `reo_reaped`
  5 GHz đứng yên khi còn client.

## 14. Kích thước ring RXDMA cho issue 53: 512, 2048, rồi tách 1024 (5 GHz) / 512 (2.4 GHz)

Cùng commit 7930126b66, cùng config với mục 12, chỉ đổi ring. Tải: 5 lượt như mục 13 (upload
`-P 8`, upload `-P 4`, download `-P 4`, nghỉ, mỗi pha 60 s), đọc số sau mỗi pha bằng
`tools/rxsnap.sh` (5 GHz) và `tools/rxsnap24.sh` (2.4 GHz). Các lần chạy nối nhau trong cùng
buổi chiều, laptop để một chỗ.

Đọc code (`backports` sau khi áp patch):
- Chỉ `DP_RXDMA_BUF_RING_SIZE` là kích thước ring: `ath11k_dp_rx_pdev_srng_alloc()` tạo ring
  bằng nó, và `ath11k_nss_pdev_init()` đặt `num_rx_swdesc = 3 × DP_RXDMA_BUF_RING_SIZE`.
- `ATH11K_DP_RXDMA_REFILL_RING_SIZE` là kích thước buffer (byte): nó vào tham số
  `rx_buf_size` của `ath11k_dp_tx_htt_rx_filter_setup()`. Khi NSS bật chỉ đường monitor dùng;
  đường dữ liệu dùng `DP_RXDMA_NSS_REFILL_RING_SIZE` (1816). Patch 999-990 và đề nghị
  2048/2048 ở issue 53 đều coi nó là kích thước ring. Đổi nó không ảnh hưởng ring dữ liệu.
- `rx_desc_in_use` lúc nghỉ = kích thước ring − 1 (511, 1023, 2047), dùng để xác nhận bản
  đang chạy.

5 GHz (QCN6122):

| ring | 512 (mục 12, uptime 17,8 h) | 2048 cả hai radio, lần 1 / lần 2 | 1024 chỉ QCN6122 |
|---|---|---|---|
| RXDMA `Overflow` qua 5 lượt | +78.325 | +49 / +102 | +433 |
| MemAvailable lúc nghỉ giữa lượt | 18-22 MiB | 12-15 / 14-16 MiB | 17-20 MiB |
| MemAvailable thấp nhất | 12 MiB | 6 / 9 MiB | 17 MiB |
| upload Mbit/s | 308-389 | 246-325 / 315-408 | 405-533 |
| download Mbit/s | 579-666 | 584-630 / 725-831 | 714-813 |
| `n2h_payload_alloc_fails` | không tăng | không tăng | không tăng |

2.4 GHz (IPQ5018) ở 512, qua một SSID tạm trên mạng lan (kênh 1, HE20, −52 dBm):
upload 40-57, download 74-85 Mbit/s, `Overflow` 0. `rx_desc_in_use` lên tới 565 lúc upload
(buffer đang chờ REO), về 511 ở mọi lần nghỉ. `Frame OOR` ~30 nghìn mỗi phút upload dù không
tràn ring, nên OOR không dùng để đánh giá ring.

- Ring 512 ở 5 GHz cạn khi upload dồn dập. 1024 đã bỏ gần hết tràn; 2048 bớt thêm vài trăm.
- RAM: ngay sau boot, bản 2048 giữ 7058 payload so với 4050 ở bản 512, MemAvailable 17,7 so
  với 28,4 MiB (~3000 buffer 4 KiB, 1536 mỗi radio). 1024 chỉ cho QCN6122 thêm 512 buffer
  (~2 MiB) cộng descriptor wifili.
- Đính chính giả định ở "Việc còn lại" trước đây: pool payload NSS không cạn khi ring lớn.
  Host tự cấp thêm khi `payload_free_count` dưới `n2h_low_water_core0` (2048, trần
  `n2h_high_water_core0` 16336). `payload_free_count` giữ 2050-2300 ở mọi lần chạy. Mục 8
  cạn có lẽ vì hạ pool xuống bằng đúng mức low water; chưa kiểm lại.
- Upload thấp ở lần 1 của bản 2048 là do sóng: lần 2 cùng bản cao hơn bản 512.
- Không bản nào bị kẹt, kể cả 512. Kết quả chỉ cho thấy ring 512 cạn, chưa chứng minh đó là
  nguyên nhân kẹt ở AX53.
- Hạn chế: bản 512 đo sau 17,8 h, các bản khác dưới 1 h, nên số RAM chưa so công bằng. Lần
  1024 có sóng tốt nhất trong ngày. Mới reboot, chưa rút điện khởi động lại.

Kết quả: patch `999-9901-ath11k-256m-1024-entry-rxdma-ring-on-qcn6122.patch` thêm
`ATH11K_DP_RXDMA_BUF_RING_SIZE(ab)` (1024 cho `ATH11K_HW_QCN6122_HW10`, còn lại
`DP_RXDMA_BUF_RING_SIZE`), dùng cho cả ring và pool descriptor wifili. Đã gửi PR
kuncy7/openwrt-nss-edma#55, đưa vào `main` và release `cr8806-nss-2026.10.27` (có LuCI).

Image release (slot 1, uptime 20-40 phút, cùng 5 lượt 5 GHz): `Overflow` +54, MemAvailable
lúc nghỉ 16-23 MiB, thấp nhất 14 MiB, upload 209-366, download 403-687 Mbit/s (tín hiệu tụt
xuống −72 dBm ở lượt 3-5), `n2h_payload_alloc_fails` không tăng. Lần đo đầu bị lẫn băng: sau
reboot laptop vào SSID tạm 2.4 GHz trước (5 GHz còn chờ DFS 60 s), nên mỗi lần reboot phải
kiểm tra laptop ở SSID nào trước khi đo.

Upstream (2026-10-27): kuncy7 merge PR 55 nguyên commit (`d1c21dcf09`), rồi thêm `c36db6321c`
bỏ hunk `ATH11K_DP_RXDMA_REFILL_RING_SIZE` 512 khỏi 999-990, trả độ dài buffer RX về 2048. Với
NSS, ring dữ liệu dùng 1816 nên không đổi gì; hunk đó chỉ ảnh hưởng ring monitor, và ring dữ
liệu của board 256 MB chạy không NSS (báo firmware buffer 512 byte trong khi host cấp 2048).
kuncy7 thấy không cần giới hạn theo `ab->nss.enabled`. `main` rebase lên `c36db6321c`, bỏ
commit ring riêng vì đã có ở upstream.

Router: slot 1 = release `cr8806-nss-2026.10.27`, soak qua đêm tới trưa 2026-10-28; slot 0 =
bản thử tách ring (cùng code, không LuCI). SSID tạm 2.4 GHz giữ tới lúc đo lại.

## 15. Release `cr8806-nss-2026.10.27` sau 16 h: soak và đo lại hai băng

Image release ở slot 1 (ring 1024 QCN6122 / 512 IPQ5018, NSS offload cả hai radio: `nss init
soc` if_num 203 cho IPQ5018, 215 cho QCN6122), boot 2026-10-27 18:04, 1-3 client 5 GHz, không
client 2.4 GHz qua đêm. `memlong.sh` ghi mỗi 10 phút, tự lưu snapshot nếu REO 5 GHz đứng 10 phút
khi có client.

Qua đêm (18:06 → 10:07, trước khi đo):
- MemAvailable 16-33 MiB, lên xuống theo tải, không giảm dần. `SUnreclaim` 23-31 MiB, `Slab`
  31-41 MiB, về lại mức cũ khi bớt client. Không thấy rò.
- Không có thư mục `reo-stall-*`; REO 5 GHz chạy liên tục. Không lỗi ath11k/NSS trong dmesg,
  logread. hostapd không restart AP nào, radio không reset (`PDEV resets` 0 ở 2.4 GHz). 6 lần
  client rời mạng qua đêm đều khớp với thiết bị tắt/ra ngoài (laptop ngủ, TV tắt, điện thoại),
  client vào lại bình thường. Một lần `lan1` mất link 26 s lúc ~21:37 (phía thiết bị nối dây).
- `n2h_payload_alloc_fails` đứng ở 34 (giá trị lúc boot) suốt 16 h.

Đo lại sau 16 h (5 lượt như mục 13). Laptop đặt chỗ khác hôm qua nên tốc độ chỉ để tham khảo:

| | 5 GHz (HE160, −47..−50 dBm) | 2.4 GHz (HE20 kênh 1, −44 dBm) |
|---|---|---|
| upload Mbit/s | 345-573 | 50-65 |
| download Mbit/s | 710-823 | 100-124 |
| RXDMA `Overflow` qua 5 lượt | +726 (ring 512 ở mục 14: +78.325) | 0 |
| `rx_desc_in_use` | 1023 suốt | 511-610, về 511 lúc nghỉ |
| MemAvailable thấp nhất / lúc nghỉ | 12 / 14-20 MiB | 11 / 15-19 MiB |
| `tx_desc_alloc_fail` | không tăng | không tăng (lần ở mục 14: +24 triệu) |

- `n2h_payload_alloc_fails` 34 → 1480 trong đúng một phút: lượt 5 upload `-P 8` ở 5 GHz,
  cùng lúc laptop mở video trên mạng (thêm luồng tải xuống). Sau đó đứng yên ở 1480, kể cả qua
  5 lượt 2.4 GHz. Bộ đếm này do firmware NSS báo (`nss_n2h.h`: số lần cấp pbuf thất bại vì
  không còn payload trống), không phải lỗi cấp phát của host: `drv_nbuf_alloc_errors` và
  `drv_paged_buf_alloc_errors` vẫn 0, `payload_free_count` lúc đọc vẫn ~2050. Nghĩa là pool
  payload trống của firmware chạm đáy trong khoảnh khắc lúc tải hai chiều dồn dập, host cấp bù
  kịp; gói rơi trong lúc đó TCP tự gửi lại (phút đó vẫn 538 Mbit/s). ~1446 lần trên ~5,7 triệu
  gói nhận trong phút đó. Đáng theo dõi nếu nó tăng đều khi dùng bình thường.
- `PDEV resets` (firmware `pdev_stats`) ở 5 GHz: 1 lúc 10:31 (16,5 h), 4 lúc 11:12. 2.4 GHz
  vẫn 0. Không có dòng nào trong dmesg/logread, không DFS/radar, kênh không đổi, client không
  rời mạng. Ba lần tăng rơi vào lúc laptop đã sang 2.4 GHz (5 GHz chỉ còn điện thoại và TV).
  Chưa rõ firmware reset vì gì; cần ghi bộ đếm này theo thời gian để biết có đi kèm sự cố nào.
- Ngoài điểm trên, không thấy vấn đề ở bản release. Ring 1024 vẫn giữ `Overflow` thấp sau 16 h.
- Lúc chuyển laptop sang 2.4 GHz, Windows quét không thấy SSID 2.4 nào của router (thấy hàng
  xóm ở kênh 4, 8, 10). Router vẫn phát (`pdev_stats` phy0 ~20 PPDU/s, khớp beacon 2 SSID), nối
  tay thì vào ngay: lỗi quét phía laptop, không phải router.

Rút điện khởi động lại (cold boot, 2026-10-28 11:28):
- Lên lại đúng slot 1, cờ boot không đổi, không có `flag_try_sys*_failed`.
- NSS khởi tạo cả hai radio như lúc reboot thường (`NSS 256 MiB: active`, `nss init soc` 203 /
  215). dmesg không có lỗi ath11k/NSS. 2.4 GHz phát ngay (11:28:17), 5 GHz sau CAC DFS 60 s
  (11:29:18), kênh 36 HE160 như cũ. hostapd báo `Can't set DFS state` cho 5200-5240 MHz như
  log boot của bản soak mục 12.
- Lúc 1 phút: MemAvailable 25,4 MiB, `n2h_payload_alloc_fails` 35, `payload_free_count` 2065,
  `PDEV resets` 0 cả hai radio. Lúc 7 phút, sau khi laptop vào 5 GHz HE160: MemAvailable
  18 MiB, `Overflow` 0.
- Laptop lại vào SSID 2.4 GHz trước (5 GHz còn chờ DFS), phải chuyển tay về 5 GHz.
- `memlong.sh`/`climon.sh` không tự chạy sau boot, phải chạy lại.

## 16. PHY4 bỏ quảng bá 1000BASE-T: sửa ở lõi DSA thay cho hook preinit

Issue [openwrt/openwrt#26157](https://github.com/openwrt/openwrt/issues/26157): trên các board
IPQ5018 nối GE PHY của SoC thẳng vào PHY4 của QCA8337 (CR8806, Redmi AX5400, CMCC PZ-L8), nếu
không có gì mở `eth0` sớm thì PHY4 bỏ quảng bá 1000BASE-T sau ~13 s và link chỉ còn 100 Mbps.
Board này đang che bằng hook `05_cr8806_eth0_up` (`ip link set eth0 up` lúc preinit).

Vì sao: CPU port của switch mô tả bằng `phy-handle` chứ không phải `fixed-link`, nên hai đầu
link là hai PHY của hai driver khác nhau. DSA attach và start PHY phía switch ngay trong
`dsa_port_setup()` lúc probe, còn PHY của conduit thuộc netdev `eth0` và stmmac chỉ attach nó
trong `stmmac_init_phy()`, mà hàm này chỉ chạy từ `stmmac_open()`. Đến khi chưa ai mở conduit,
PHY4 autoneg với một đối tác không quảng bá gì; nó bỏ 1000BASE-T và khởi động lại autoneg sau
đó cũng không lấy lại được.

Vì sao build cũ của hzyitc (QSDK, swconfig) không bị: `qca-ssdk` sở hữu cả switch lẫn mọi PHY
và khởi tạo chúng ngay lúc nạp module (không power-down), còn `qca-nss-dp` gọi `phy_connect()`
trong probe, nên `phy_attach_direct()` → `phy_init_hw()` + `phy_resume()` đã bật GE PHY và để
nó quảng bá trước lần autoneg đầu của PHY4. Kiểm lại trên một máy thứ hai cùng phần cứng (OpenWrt
21.02.7, kernel 5.4, build `redmi,ax3000` của hzyitc): có `qca_ssdk`/`qca_nss_dp`, không có
`dsa`/`qca8k`; `dp1` khai `qcom,link-poll` và `qcom,phy-mdio-addr = 7`; `switch_cpu_bmp` =
0x60 (port 5+6), `port_phyinfo` map port 5 ↔ phy 4; `eth0` carrier 1, speed 1000, MIB
`RxGoodByte` của port 5 khớp đúng `tx_bytes` của `eth0`. Nhánh DSA duy nhất hzyitc từng thử
(`dsa-5.15`, 2/2024) chỉ giữ CPU port SGMII, port 5 là user port thường tên "cpu2", không có
`ethernet =`, nên link PHY–PHY chưa bao giờ là conduit ở đó. Kết luận: không phải port sai.

Sửa: patch `714-net-dsa-open-the-conduit-of-a-PHY-to-PHY-CPU-link.patch` (generic, pending-6.18).
Trong `dsa_shared_port_link_register_of()`, nếu port không có `fixed-link` mà có `phy-handle`
thì gọi `dev_open(dp->conduit)` trước khi register phylink, để hai PHY cùng lên cho lần autoneg
đầu. Conduit `fixed-link` (tức mọi board khác) không bị ảnh hưởng. Bỏ luôn hook
`05_cr8806_eth0_up`.

Lưu ý khi đọc patch 711-08 upstream: `qca8k_preferred_default_local_cpu_port()` chỉ trả về
port 0 rồi port 6, không bao giờ port 5. Nên thứ tự node trong DTS **không** quyết định conduit
mặc định: CR8806, PZ-L8 và AX5400 đều mặc định `eth1`. Việc sửa thứ tự `ethernet-port@5`/`@6`
trong DTS CR8806 không giải quyết gì.

Đính chính (2026-11-06, đọc lại openwrt main): trước đây mục này viết "AX5400 thoát vì
`02_network` đặt conduit của `wan` là `eth0`". Sai, vì `02_network` của main đặt **y hệt** cho
cả hai board:

```
	cmcc,pz-l8|\
	xiaomi,redmi-ax5400)
		ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" "wan"
		ucidef_set_network_device_conduit "lan1" "eth1"   (lan2, lan3 tương tự)
		ucidef_set_network_device_conduit "wan" "eth0"
```

Nghĩa là cả hai đều có một user port mà conduit là link PHY–PHY. Việc có bị lỗi hay không phụ
thuộc **thời điểm** có ai mở conduit đó so với hạn ~13 s của PHY4: cấu hình nào mở `wan` sớm
(netifd dựng interface `wan` ngay lúc boot) thì thoát, cấu hình nào không có interface `wan`
(bản AP của pz-l8 bridge cả 4 cổng) hoặc mở muộn thì mắc. Mở conduit ngay lúc probe xoá hẳn
cuộc đua này. Commit bật phy-to-phy cho PZ-L8 trong main là `9dfc0c3eea96` (PR #21496, merge
2026-04-14, tác giả viết 2026-01).

Build test (nhánh `dsa-conduit-open-test` = main + bỏ hook + patch 714), flash slot 0, chạy
không hook:

| | |
|---|---|
| GE PHY attach | 2,12-2,15 s (`eth0: PHY [88000.mdio-1:07]`) |
| PHY4 attach | 2,22-2,25 s (`qca8k …: PHY [90000.mdio-1:04]`), tức sau ~98 ms |
| `eth0: Link is Up - 1Gbps/Full` | 4,636 s |
| `ethtool eth0` | 1000Mb/s Full, autoneg on, link detected yes |
| Số lần boot đạt gigabit | 5/5 (1 lần flash + 3 reboot mềm + 1 cold boot rút điện) |

Các phép thử phục hồi đều giữ 1000Mb/s: `/etc/init.d/network restart`, `ifdown wan`/`ifup wan`,
`ip link set eth0 down` 45 s rồi up. Cắm laptop vào cổng WAN (mạng riêng của cổng đó): `ethtool wan`
1000Mb/s Full, iperf3 378 Mbit/s 1 luồng, 466 Mbit/s 4 luồng, 233 Mbit/s chiều ngược — traffic
kết thúc tại router nên bị giới hạn CPU (NSS chỉ offload traffic đi qua router, nên bộ đếm
netdev của `eth0` gần như không tăng), nhưng vẫn vượt xa mức ~94 Mbit/s của một link
100BASE-TX, đủ để chứng minh PHY4 không rút 1000BASE-T. Bộ đếm switch cổng `wan` qua các lượt:
rx 1,73 GB / tx 1,11 GB. Không có `mdio-tools` trong image nên không đọc trực tiếp được reg 9
của PHY4.

Soak 5 ngày 16 h (boot 2026-10-31, đọc 2026-11-06 09:17), dùng thường ngày, 3 client Wi-Fi:
- `eth0` vẫn 1000Mb/s Full, link detected yes; `eth1` 1000Mb/s.
- MemAvailable 24,6-27,8 MiB, `SUnreclaim` 31,5 MiB, `Slab` 39,9 MiB. Không rò.
- `n2h_payload_alloc_fails` = 35, đúng giá trị lúc boot, không tăng suốt 5,7 ngày.
  `drv_nbuf_alloc_errors`/`drv_paged_buf_alloc_errors` = 0, `payload_free_count` 2072.
  Thêm 2026-11-06: con số 35 không phải trùng hợp của một máy. Máy thứ nhất ngay sau boot là 8,
  trong ~30 phút đầu lên 34-35 rồi dừng hẳn; máy thứ hai sau 4,7 h uptime cũng đúng 35. Tức nó
  sinh ra trong giai đoạn đầu sau khi firmware chạy, không phải do tải thường ngày.
- `PDEV resets`: 5 GHz (phy1, QCN6122) 25 lần trong 5,7 ngày (~4,4/ngày), 2.4 GHz 0 — cùng
  hiện tượng như mục 15, không có dòng nào trong dmesg/logread, client không rời mạng.
- logread (3 ngày còn lưu) chỉ có 30 dòng `dnsmasq-dhcp: no address range available`; không có
  lỗi ath11k/NSS, không `reo-stall-*`, không radio reset trong log.
- dmesg: chỉ `lan2: Link is Down` vài lần (thiết bị nối dây đầu kia), không có lỗi qca8k/DSA.

Upstream sau khi cập nhật (origin/c3po-tag-8021q `fb7e09acfe`, kernel 6.18.55 → **6.18.60**,
~250 commit mới): không có commit nào liên quan đến vấn đề này. `net/dsa` chỉ bị các bản bump
kernel chạm tới, `711-06/07/08` không đổi, slot `714` vẫn trống (upstream openwrt main cũng
vậy: 713 và 715 đã dùng, 714 trống). Patch 714 áp được vào 6.18.60 không cần refresh. Các thay
đổi upstream đáng để mắt cho board này: `2e20111fda` qca8k MIB autocast/management frame v2,
`a60e90b7b1` ath11k REO hash buckets → SW1 khi chạy NSS, `82774126e3` chặn danh sách trang
per-CPU của qca-nss-pbuf ở profile 256 MB, `04_set_netdev_label` đổi sang hai pha park/rename.

Build lại trên upstream mới (`r38062+309-c36db6321c`, kernel 6.18.60) và flash slot 1, giữ
config: kết quả trùng khít bản 6.18.55.

| | 6.18.55 | 6.18.60 |
|---|---|---|
| GE PHY attach | 2,12-2,15 s | 2,12-2,16 s |
| PHY4 attach | 2,22-2,25 s | 2,23-2,26 s |
| `eth0: Link is Up - 1Gbps/Full` | 4,636 s | 4,636-4,646 s |
| boot đạt gigabit | 5/5 | 4/4 (1 lần flash + 3 reboot) |
| `failed to open conduit` trong dmesg | 0 | 0 |

Các phép thử phục hồi trên bản mới cũng giữ 1000Mb/s: `/etc/init.d/network restart`,
`ifdown wan`/`ifup wan`, `ip link set eth0 down` 40 s rồi up. Lưu ý: hạ `eth0` (conduit) làm
user port `wan` xuống admin DOWN và netifd không tự dựng lại — phải `ifup <interface của wan>`.
Không phải lỗi của patch (DSA vốn hạ user port khi conduit xuống), nhưng nhớ khi test tay.

Nhánh `dsa-conduit-open` (từ `origin/c3po-tag-8021q`, 2 commit: patch 714 + bỏ hook) để mở PR
vào kuncy7/openwrt-nss-edma. Patch generic cũng dùng được trực tiếp cho openwrt/openwrt.

Một máy thứ hai gặp đúng lỗi này, và nó đã nằm trong upstream: PR openwrt/openwrt #21496
"qualcommax: ipq5018: pz-l8: enable PHY-to-PHY CPU link" (merge 2026-04-14) bỏ đoạn DT bị
comment kèm chú thích *"WAN cannot work if added"* và bật `port@5 { phy-handle = <&qca8337_4>;
phy-mode = "gmii"; ethernet = <&dp1>; }` cho CMCC PZ-L8 (IPQ5018 + QCA8337, cùng cách nối
GE PHY ↔ PHY4 như CR8806), đồng thời đặt `ucidef_set_network_device_conduit "wan" "eth0"`. Bản
build CrazyBoyFeng/openwrt-pz-l8 sau đó phải ghim `OPENWRT_SHA` về trước #21496 (commit
`983cec577e`, "fix(wan): revert OPENWRT_SHA to a5c5ca06 (pre phy-to-phy)") vì *"WAN-not-working
(DWMAC + ge_phy SGMII link not coming up)"*, và chịu mất 2 Gbps còn 1 Gbps. Đó chính là hiện
tượng mục này mô tả: không ai mở conduit `eth0` lúc probe nên PHY4 đàm phán với một đầu không
quảng bá gì. Vậy patch 714 nên là bản sửa cho họ — cần nhờ họ kiểm chứng, và nhắc PR #21496
trong phần mô tả PR.

Đính chính lần hai (2026-11-06, đo trực tiếp trên cả hai máy): lý thuyết "cấu hình nào mở `wan`
sớm thì thoát" ở trên không đứng được. netifd **có** mở conduit — `dsa_user_open()` gọi
`dev_open(dp->conduit)` trong `net/dsa/user.c`, nên chỉ cần netifd dựng interface của cổng WAN là
`eth0` được mở — nhưng muộn. Cả hai máy (đều có `option conduit 'eth0'` cho cổng `wan`, đúng như
PZ-L8 và AX5400 trong main) cho **hai** dòng link up trên `eth0`:

```
[    4.636] eth0: Link is Up - 1Gbps/Full    <- patch 714, ngay lúc probe
[   21.228] eth0: Link is Up - 1Gbps/Full    <- netifd dựng tới cổng WAN (máy thứ hai: 21,920 s)
```

21 s là **~8 s sau** mốc ~13 s mà PHY4 đã bỏ quảng bá 1000BASE-T. Tức trên board này netifd không
bao giờ kịp, và "mở sớm" không phải đường thoát: board nào không bị thì vì lý do khác (timing phần
cứng khác, hoặc có hook ở user space). Báo cáo WAN chết của PZ-L8 sau #21496 khớp đúng với kết
luận này.

PR [openwrt/openwrt#26511](https://github.com/openwrt/openwrt/pull/26511) đã mở (patch 714 + bỏ
hook `05_cr8806_eth0_up`). Phần Testing của PR viết lại theo đúng số đo trên: bỏ câu sai "nothing
ever opens eth0" và câu suy đoán "usually in time", thêm cột máy thứ hai vào bảng, và thêm một mục
loại trừ NSS offload là nguyên nhân `eth0` lên (trên máy thứ hai firmware NSS chỉ được giao GMAC1
— `fw_mask` suy ra `0x2`, xem mục 18 — nên `eth0` nằm hẳn trên host stack, vậy mà vẫn 1Gbps/Full ở
4,73 s với 0 cảnh báo `failed to open conduit`). CI của openwrt: 3/3 pass. File patch trong ba cây
(`openwrt-nss`, `pr-wt`, `openwrt-upstream-wt`) giống nhau từng byte (md5 `d7d01cac…`), nên thứ PR
mang đi đúng là thứ đã test trên phần cứng; cây upstream chỉ để đóng gói.

## 17. Bản build có mesh offload + usteer, và nạp nó cho AP thứ hai

Thêm vào config của bản CR8806 đang dùng:

```
CONFIG_ATH11K_NSS_MESH_SUPPORT=y   -> tự select kmod-qca-nss-drv-wifi-meshmgr,
                                      NSS_DRV_WIFI_MESH_ENABLE, PACKAGE_MAC80211_MESH
CONFIG_PACKAGE_wpad-mesh-mbedtls=y (thay wpad-basic-mbedtls)
CONFIG_PACKAGE_usteer=y
```

- `wpad-mesh-*` có `LOCAL_VARIANT=mesh`, và Makefile của hostapd map mesh -> `CONFIG_VARIANT=full`,
  tức dùng `hostapd-full.config` + `wpa_supplicant-full.config`: vẫn `CONFIG_IEEE80211R=y`, thêm
  `CONFIG_WNM=y`. Đổi sang bản mesh **không** mất 802.11r.
- Patch mesh được apply đủ: `nss/mesh/0001`, `0001a`, `0002`, `0003` và `nss-extra/mesh/999-992`.
  Build sạch, không cần sửa gì.
- Giá: `factory.ubi` +262 KB (17,43 -> 17,69 MB), `sysupgrade.bin` +287 KB. Lúc chạy có thêm
  module `qca_nss_wifi_meshmgr` 28 KB nạp sẵn; MemAvailable trên AP thứ hai (3 SSID) 35,1 MiB.
- Chưa cấu hình 802.11s ở đâu: muốn backhaul mesh thì AP còn lại cũng phải chạy bản có mesh.

### Máy thứ hai là cùng phần cứng M79, chỉ khác tên profile của bản hzyitc

Bản hzyitc khai compatible `redmi,ax3000` và model "Redmi AX3000" nên rất dễ tưởng là board M81.
Cách phân biệt chắc chắn mà không cần mở máy, đọc ngay trên bản đang chạy:

- `dmesg` của ath11k in `board_id`: M79 (CR880x) = `0x10`, M81 (Redmi AX3000 thật / RA81) = `0x24`.
- Radio 5 GHz của M79 là `qcn6122` (M81 là QCN6102).
- Bảng MTD của hai máy giống hệt nhau (`rootfs`/`rootfs_1` 36 MiB + `overlay` + `data`).

Sau khi nạp, DTS của mình báo đúng `Xiaomi CR8806 (M79)`. Mốc đối chiếu nếu sau này gặp máy M81
thật: openwrt main và immortalwrt đều chưa có board đó; chỉ có repo cộng đồng (`7noemo/ra81-support`
có DTS cho layout qualcommax + BDF, `IcySakura/redmi-ax3000-openwrt-nss` dựng trên cây kuncy7 và
báo NSS chạy). Đừng nạp ảnh CR8806 cho M81.

Đo lại patch 714 (mục 16) trên máy thứ hai: `eth0: Link is Up - 1Gbps/Full` ở **4.636 s**, 0 cảnh
báo `failed to open conduit` — khớp từng con số với máy thứ nhất. Thêm một điểm dữ liệu cho PR 26511.

### Nạp cho máy đang chạy hzyitc: cấu hình đi bằng `sysupgrade.tgz`, không restore backup cũ

Quy trình: `ubiformat` slot **không** chạy -> verify kernel + `bytes_used` của squashfs -> đặt
tarball cấu hình (kết quả converter) thành `sysupgrade.tgz` ở gốc `rootfs_data` của slot mới ->
đổi flag -> reboot. Backup cấu hình hzyitc chỉ để lưu, không restore (swconfig không dùng được).

Hai cái bẫy, đã sửa cả hai trong script nạp:

1. Tarball đóng từ WSL mang uid/gid 1000. Dropbear **bỏ qua** `authorized_keys` không thuộc root,
   nên mất đường vào bằng key (vẫn vào được bằng mật khẩu hoặc LuCI). Phải đóng bằng
   `tar --owner=root --group=root --numeric-owner`, và script giờ chặn tarball có entry khác root.
2. Slot mới sinh host key dropbear mới, `ssh` từ chối trước cả bước auth; vòng chờ của script vì
   thế báo sai là "máy không lên" dù máy đã chạy. Xoá entry `known_hosts` trước khi chờ.

Mở: ở lần first boot, `option conduit 'eth0'` của cổng wan bị đổi thành `eth1` cả trong file lẫn
trong runtime (file bị uci ghi lại và mất comment — init của ECM commit `network` cho
`packet_steering`). Đặt lại `eth0` + `network reload` thì giữ cả file lẫn runtime. Không script nào
trong cây ghi `conduit`; chỉ `netifd` đọc `network_device` của `board.json`, mà board.d đặt mọi cổng
= `eth1`. Đã xem lại (2026-11-06): cả hai máy vẫn còn `option conduit 'eth0'` trong file và
`upper_wan` thật trên `eth0`, sau nhiều lần reboot (máy thứ hai uptime 4,6 h; máy thứ nhất vừa
reboot để test ở mục 18). Vậy việc bị ghi lại chỉ xảy ra ở first boot của slot mới, không tái diễn.

### Dựng thật một link 802.11s và đo

Cả hai AP đều nối dây với nhau (trunk), nên mesh **không** bridge vào `br-lan`: bridge mà không
bật STP là tạo vòng lặp lớp 2 cho cả LAN. Cấu hình đã dùng: một `wifi-iface` `mode mesh` trên
radio0 (2.4 GHz, hai AP vốn đã cùng kênh 1 — hai đầu mesh buộc phải cùng kênh), `encryption sae`,
netdev mesh mang một /24 riêng và một zone firewall riêng (input ACCEPT, forward REJECT).
Script: `tools/mesh-setup.sh <ip> <mesh-ip>` (khoá SAE truyền qua stdin, không nằm trong argv).

NSS mesh offload **có chạy** — lần đầu đo được trên board này (Kconfig chỉ ghi đã đo trên
GL-B3000 và Archer AX55), với profile 256 MiB và firmware NSS 12.5:

```
nss_wifi_meshmgr_init_module: Module Build Id ... loaded
nss_wifi_meshmgr_if_create_sync: Successfully registered encap and decap iface for Mesh
nss_wifi_meshmgr_if_create_sync: WiFi Mesh interface count:1
wpa_supplicant[w-mesh]: MESH-PEER-CONNECTED   (SAE, -42..-49 dBm)
```

- `iw station dump` của peer: **HE-MCS5 NSS2 40 MHz = 275,2 Mbit/s** PHY, tx retries 0, tx failed 0.
- `iw mpath dump` rỗng dù ping chạy — khớp với việc bảng mesh path nằm dưới NSS, không ở host.
- Thông lượng, traffic **kết thúc trên router** (iperf3 giữa hai AP): TCP 1 luồng 9,4 Mbit/s,
  4 luồng 10,2, chiều về 16,5; UDP ép 100 Mbit nhận 17,9 Mbit/s mất 7,9%. Trong khi đó kênh 1
  `busy 72%` (111429/153923 ms) vì cả hai AP cùng phát 2.4 GHz trên ch1 cộng client IoT.
  Chưa tách được phần do contention với phần do thiếu aggregation trên link mesh / đường
  exception về host. Muốn số thật của một backhaul thì phải đo traffic **đi xuyên** (client sau
  AP này tới host sau AP kia), và nếu cần backhaul nhanh thì phải chuyển mesh sang 5 GHz, tức
  đưa hai AP về cùng một kênh 5 GHz (hiện cố ý tách ch36/ch100 cho roaming).
- Giá RAM của mesh khi chạy: MemAvailable 35,7 -> 32,8 MiB ở máy thứ nhất, 35,1 -> 32,4 ở máy thứ hai.

Đo lại sau khi chuyển mesh sang 5 GHz (radio1) và đưa cả hai AP về **cùng ch36 HE160**
(ch36 hơn ch100 ở chỗ 80 MHz đầu không phải DFS), vẫn traffic kết thúc trên router:

| | mesh 2.4 GHz ch1 | mesh 5 GHz ch36 HE160 |
|---|---|---|
| TCP 1 luồng | 9,4 Mbit/s | **281** Mbit/s |
| TCP 4 luồng | 10,2 | **446** |
| TCP chiều về | 16,5 | **261** |
| UDP (ép 100M / 400M) | 17,9 (mất 7,9%) | 173 (mất 11%) |
| PHY tx/rx | 275,2 / 275,2 (HE-MCS5 NSS2 40 MHz) | **1729,6 / 1441,3** (HE-MCS8/7 NSS2 160 MHz) |
| kênh busy | 72% (111429/153923 ms) | 23,5% (25340/107706 ms) |
| tx retries / failed | 0 / 0 | 0 / 0 |

Tức là link 2.4 GHz không phải lỗi mesh mà là kênh 1 đã kín. Con số 446 Mbit/s đã **sát mức
CPU** của traffic kết thúc trên router (mục 16 đo iperf3 qua cổng WAN được 378-466 Mbit/s), nên
nó là *sàn* chứ chưa phải trần của backhaul: traffic đi xuyên thì đi đường NSS, không lên host.
Đổi lại, hai AP giờ cùng một kênh 5 GHz nên chia nhau thời gian phát - cái giá phải trả để hai
đầu mesh gặp nhau. Không có lỗi nào từ meshmgr (`WiFi Mesh interface count:1`, 0 dòng
fail/error/nack), MemAvailable lúc rỗi 27,4 MiB (máy thứ nhất, sau tải nặng) và 32,7 (máy thứ hai).

Cùng lần này: đổi SSID của máy thứ nhất cho trùng máy thứ hai (khoá vốn đã trùng) để có roaming
thật; 802.11r sẵn trong `wpad-mesh-mbedtls`, `usteer` cài sẵn nhưng **chưa bật**.

Hai điều rút ra khi sửa Wi-Fi qua ssh:

1. `wifi reload` trên board này có thể lâu hơn 60 s. Đặt timeout ssh ngắn thì lệnh bị kill giữa
   lúc reload.
2. Sau `uci commit wireless` (chỉ đổi 3 SSID), một section `wifi-iface` đang có trong file biến
   mất — chưa rõ cơ chế. Nên sao lưu `/etc/config/wireless` trước khi commit, và kiểm lại số
   section sau đó. (Dựng lại được từ tarball `sysupgrade -b` của cùng ngày.)

Thêm một dữ kiện cho câu hỏi conduit ở trên: máy thứ nhất **giữ** `conduit 'eth0'` qua reboot sau
khi nạp lại (config đi bằng `sysupgrade -b`), nên cú đổi sang `eth1` ở máy thứ hai nghiêng về
"chỉ xảy ra ở lần first boot có restore tarball tự đóng".

### Bridge mesh vào br-lan + STP: đã thử, đã gây sự cố, đã trả về dùng dây

Topology thật (quan trọng cho kết luận): router chính -> một cổng VLAN của AP thứ hai -> cổng
VLAN còn lại sang AP thứ nhất. Tức hai AP **nối trực tiếp bằng một sợi dây**, không qua switch
trung gian. Bridge sợi mesh vào `br-lan` ở cả hai đầu là tạo loop giữa đúng hai máy đó.

Đã làm: thêm `w-mesh` vào `ports` của `br-lan` và vào cả ba `bridge-vlan` dạng tagged, bật
`stp=1`, bỏ mạng mesh L3 và zone của nó. Máy thứ nhất chạy tốt (STP lên, `w-mesh` forwarding, đủ
địa chỉ). Khi áp cho máy thứ hai thì mạng sập: cổng mesh của nó vào forwarding trong khi cổng dây
cũng đang forwarding mà STP chưa chặn xong -> loop sống. Người dùng phải reset máy thứ hai và rút
điện máy thứ nhất. Guard 180 s trên máy thứ hai (script `tools/mesh-bridge.sh`) có tác dụng: nó
giữ bản `/etc/config/network`+`wireless` cũ và rollback phục hồi nguyên trạng.

Hai điều ghi lại cho lần sau:

- **Đừng** để cổng thứ hai của một loop vào forwarding rồi mới trông vào STP. Linux bridge dùng
  STP 802.1D (không RSTP trong kernel), listening + learning = 2 x `forward_delay` = 30 s mặc
  định, và trong cửa sổ đó loop là loop thật. Muốn làm lại thì hoặc hạ `forward_delay`, hoặc bật
  STP ở cả hai đầu **trước** khi thêm cổng mesh, hoặc bỏ STP và dùng một script đổi cổng theo
  carrier của cổng dây (xác định, không có cửa sổ hở).
- Một lần đọc `root_id`/`bridge_id` giữa lúc hội tụ cho thấy "cả hai tự nhận là root" và tôi kết
  luận sai là BPDU không qua được VLAN trunk. Đọc lại `brport/designated_root` thì thấy máy thứ
  nhất đã nhận máy thứ hai làm root, tức BPDU qua được bình thường. Muốn biết STP có thấy nhau
  thì đọc `/sys/class/net/<port>/brport/designated_root`, đừng đọc `root_id` của bridge một lần
  rồi kết luận.

Trạng thái cuối (cả hai AP, `tools/mesh-teardown.sh`): không còn `wireless.mesh0`, `network.mesh`,
zone `mesh`, `w-mesh` ra khỏi `br-lan` và các `bridge-vlan`, `stp` về 0, AP thứ hai về lại kênh
5 GHz cũ nên hai AP lại khác kênh. Giữ lại phần làm nên "mesh có dây": SSID + khoá trùng nhau ở
cả hai, `usteer` chạy sẵn.

Roaming: đã bật 802.11r/k/v **chỉ trên SSID chính** của cả hai AP (`ieee80211r=1`,
`ft_psk_generate_local=1`, `mobility_domain` giống nhau, `ieee80211k=1`, `bss_transition=1`;
script `tools/enable-11r.sh`). Kiểm trong `/var/run/hostapd-phy1.conf` thấy đúng:
`wpa_key_mgmt=SAE FT-SAE WPA-PSK WPA-PSK-SHA256 FT-PSK`, `ft_psk_generate_local=1`,
`ft_over_ds=0` (FT qua sóng, không qua DS - mặc định của OpenWrt), `rrm_neighbor_report=1`,
`rrm_beacon_report=1`, `bss_transition=1`. Lưu ý uci `ieee80211r` **không** sinh ra dòng
`ieee80211r=` nào trong hostapd.conf (hostapd không có khoá đó), nó thêm FT-* vào
`wpa_key_mgmt` - nên muốn xác minh thì đọc `wpa_key_mgmt`. SSID IoT và Guest để nguyên: FT là
chỗ thiết bị cũ hay hỏng, và chúng không cần roaming nhanh. Bản lùi: `/root/wireless.bak-before-11r`
trên mỗi máy.

### Một dòng `gateway` thừa do converter mang sang

Máy thứ hai hiện khối **"IPv4 Upstream"** trong LuCI (proto static, địa chỉ của cổng rời, gateway
là router LAN) còn máy thứ nhất thì không. Nguyên nhân: interface của cổng rời (cổng WAN, dùng
làm đường cứu hộ) trong cấu hình hzyitc cũ có `option gateway`, và converter mang nguyên văn;
cấu hình của máy thứ nhất làm tay nên chưa từng có dòng đó.

Hai điều học được:

- **Khối "IPv4 Upstream" của LuCI là *khai báo*, không phải đường đi thật.** Nó liệt kê interface
  nào khai một default route trong trạng thái netifd. Kiểm bằng
  `ubus call network.interface.<tên> status`: máy thứ hai có `target 0.0.0.0 mask 0 nexthop <router>`
  trong mảng route của interface đó, máy thứ nhất không có gì. Còn trong kernel thì **hai máy giống
  hệt nhau**: đúng một default route, đi qua VLAN uplink, lấy từ lease DHCP (`ip route get` xác nhận).
- Gateway đó không thể thành route vì nó nằm ngoài subnet của chính interface (không on-link trên
  device đó), cộng thêm cổng không có cáp. Vô hại ở hiện tại, nhưng là bẫy ngủ: cắm một sợi từ LAN
  vào cổng đó là có default route thứ hai cùng metric 0, và traffic do router tự phát ra (DNS, NTP,
  cập nhật) đi cổng nào trở thành không xác định.

Đã xoá dòng đó trên máy thứ hai (hai máy giờ giống nhau) và sửa `Convert-HzyitcConfig.ps1`: bỏ
`option gateway` khi proto không phải `static`, hoặc khi gateway nằm ngoài subnet của interface;
cả hai trường hợp ghi lý do **kèm giá trị** vào `report.md` để đặt lại bằng tay nếu interface đó
thật sự là uplink. Gateway nằm trong subnet thì giữ nguyên. Kiểm lại bằng chính backup thật (diff
so với bản sinh trước đó: đúng một dòng, không có thay đổi nào khác) và một fixture dựng riêng để
chạy cả hai nhánh (gateway trong subnet -> giữ; `proto dhcp` + gateway -> bỏ).

## 18. `fw_mask` của nss-tools bỏ sót GMAC mang cổng WAN

`nss-tools` tự suy ra `nss.general.fw_mask` (GMAC nào giao cho firmware NSS) trong
`nss_dsa_fw_mask()` của `package/nss/nss-tools/files/functions.sh`. Nhánh DSA của hàm duyệt mọi
GMAC nhưng rồi `[ "$n" = "$NSS_CONDUIT" ] || continue` — chỉ giữ **một** conduit, cái mà
`nss_dsa_conduit()` chọn vì có nhiều user port nhất. Board nào có cổng `wan` nằm trên CPU port còn
lại thì firmware chỉ nhận trunk LAN, còn đường dữ liệu WAN ở lại host stack.

Phát hiện ra vì board này đúng là như vậy: cả hai máy suy ra `0x2` trong khi `eth0` thật sự là
conduit của user port `wan` (`/sys/class/net/eth0/upper_wan` có thật) — và đó là lý do cả hai máy
đang mang `fw_mask=0x3` ghi tay trong `/etc/config/nss`. Không phải chuyện riêng của board này:
`board.d/02_network` của ipq50xx trong **openwrt main** đặt `ucidef_set_network_device_conduit
"wan" "eth0"` cho `cmcc,pz-l8` và `xiaomi,redmi-ax5400`, fork thêm `cudy,p5`. Gốc rễ là một comment
sai ngay trong hàm đó, viết rằng CPU port thứ hai là cái "DSA không dùng".

Sửa (nhánh `nss-tools-fw-mask`, 1 commit trên `main`):

- Thêm `nss_dsa_user_ports <netdev>`: user port DSA của netdev đó = những `upper_*` có
  `phys_switch_id`. CPU port mà DSA không giao user port nào thì rỗng.
- `nss_dsa_fw_mask()` gộp **mọi** CPU port có user port, không chỉ `NSS_CONDUIT`.
- `nss_dsa_conduit()` và `nss_dsa_tagger()` dùng lại helper (trước mỗi chỗ tự duyệt `upper_*`), và
  comment đầu hàm viết lại cho đúng: `nss_dsa_conduit` là **bình chọn theo số user port**, không
  phải "the conduit".
- `nss-dwmac-probe` in thêm cột `users` cho mỗi GMAC để cái mask tự giải thích được:
  `eth0 … users wan` / `eth1 … users lan1,lan2,lan3`.

Không thể làm xấu hơn hiện tại: thay đổi duy nhất về kết quả là "CPU port **có** user port thì
được tính vào"; board nào không có uppers trên CPU port thứ hai thì hàm trả về đúng giá trị như
hôm nay.

Test: `package/nss/nss-tools/tests/dsa-fw-mask.test.py` dựng `/sys/class/net` giả trong tempdir
(dir `dsa/` cho CPU port, `flags`, symlink `device` tới `39c00000.ethernet`/`39d00000.ethernet`,
`upper_<port>`, `phys_switch_id`, `device/driver` -> `qca8k`) rồi chạy bản `functions.sh` đã thay
đường `/sys/class/net`. Năm hình: `wan` trên CPU port thứ hai -> 0x3; mọi user port trên một
conduit -> 0x2; board có PHY WAN riêng, up -> 0x3; cùng board, down -> 0x2; không switch -> 0x1.
Đã kiểm là test **fail trên code cũ** (ra 0x2 ở ca thứ nhất, kiểm bằng cách tạm gỡ bản sửa). CI
`nss-tools.yml` chạy test hai lần: python3 + `sh` của host, rồi `NSS_TEST_SH` = `sh` của busybox.

Thử thật, trên **máy thứ nhất**: máy thứ hai đang làm cầu nối giữa router chính và máy thứ nhất
(lan1 + lan2 đều 1000Mb), nên nó là máy *không* được reboot để test — chỉ reboot cái ở nhánh lá.
Xoá override trong `/etc/config/nss`, đặt `functions.sh` mới vào `/lib/nss/`, reboot:

```
19:56:58 nss: topology dsa: GMAC map read off the board: 0:eth0,1:eth1
19:57:06 nss-dwmac-up: topology dsa: eth1 is the DSA conduit (tagger qca-8021q)
19:57:37 nss-dwmac-up: topology dsa: fw_mask 0x3 from the board (conduit eth1 = phys_if 1, …)
```

Thứ tự boot không thành vấn đề: `nss-dwmac-up` chỉ gọi helper khi `fw_mask` chưa đặt, và nó đã chờ
`trunk` operstate up + `ubus network.interface.lan status` up + `sleep 3`. Khoảng cách đo được giữa
netifd (`Interface 'lan' is now up`, 19:57:06) và lúc suy ra mask (19:57:37) là **31 s**, và lúc đó
`upper_wan` của `eth0` đã có sẵn. Sau test, đặt lại override `0x3` mà **không** reboot: mask chỉ
được đọc lúc boot, mà mask đang chạy vốn đã là `0x3`.

Hai cái bẫy gặp trong lúc test:

- Script **không có shebang** chạy qua `start-stop-daemon -S -b -x /tmp/x.sh` thì chết im lặng:
  exec trong tiến trình con fail ENOEXEC, mà `start-stop-daemon` vẫn trả 0 và không in gì. Gọi
  trực tiếp từ `ash` thì lại chạy, vì shell tự fallback. Luôn viết shebang.
- `/lib/upgrade/keep.d/nss-tools` chỉ giữ `/root/auto-recovery` và `/root/pstore`, nên `/lib/nss/*`
  vá tay **không** sống qua sysupgrade — tốt cho test (không có drift ngầm), nhưng nhớ là bản vá
  tay sẽ mất khi nạp ảnh mới.

Trạng thái: nhánh đã push lên fork, **chưa build** (logic đã chứng minh xong, chỉ cần build khi
nào flash). md5 `functions.sh`: bản đang chạy `6cb4749c…`, bản sửa `9c4c6f2e…`.

## 19. usteer: hoá ra nó đã chạy, nhưng không steer gì cả

Mục 17 và "Việc còn lại" trước đây ghi usteer "chưa bật, chưa cấu hình". **Sai**: gói usteer
bật service mặc định, nên `usteerd` đã chạy trên cả hai AP từ lúc nạp bản mục 17, với
`/etc/config/usteer` nguyên bản của gói (chỉ đặt `network lan`, `syslog 1`, `local_mode 0`,
`debug_level 2`; mọi thứ khác để comment = mặc định của daemon).

Những gì nó **đang** làm, kiểm bằng ubus:

- Hai AP thấy nhau: `ubus call usteer remote_hosts` trên mỗi máy trả về đúng máy kia.
  Giao tiếp đi qua `br-lan.68` (uci `option network lan`), UDP 16720.
- `ubus call usteer local_info` liệt kê cả ba BSS mỗi máy kèm `rrm_nr` — tức usteer đang cấp
  danh sách neighbor 802.11k cho hostapd. Đây là phần có ích nhất và nó miễn phí.
- `ubus call usteer get_clients` cho **góc nhìn chéo**: với một client, máy thứ hai có cả số đo
  của chính nó (`hostapd.<bss>`) lẫn số đo máy thứ nhất nghe được (`<ip máy kia>#hostapd.<bss>`).
  Ví dụ thực tế: một client ở −65 dBm trên AP đang nối, mà AP kia chỉ nghe −90 dBm.

Những gì nó **không** làm — và đây là điểm dễ tưởng sai: `roam_events` của mọi BSS trên cả hai
máy đều `source 0, target 0`, nghĩa là chưa từng có một lần steering nào. Đọc source
(usteer 2026-05-19, `policy.c`) thì rõ vì sao, cả hai đều do giá trị mặc định `0`:

```c
better_signal_strength(...)  { if (!config.signal_diff_threshold) return false; ... }
usteer_local_node_roam_check(...) {
	if (config.roam_scan_snr) ... else if (config.roam_trigger_snr) ... else return;
}
```

- `signal_diff_threshold 0` → hàm "AP kia tốt hơn" **luôn** trả false.
- `roam_scan_snr 0` **và** `roam_trigger_snr 0` → máy trạng thái roam return ngay, không bao giờ
  gửi roam scan, không BSS transition request, không kick.
- `min_snr 0`, `assoc_steering 0`, `load_kick_enabled 0` → không đuổi ai vì tín hiệu yếu, không
  từ chối association, không kick vì tải kênh.

Nói cách khác: mặc định của usteer là **chỉ chia sẻ trạng thái + cấp neighbor report**, hoàn toàn
thụ động. Muốn nó thật sự điều hướng thì phải tự đặt ngưỡng.

Một cái bẫy về đơn vị, đọc `usteer_snr_to_signal()` mới thấy: giá trị **âm** được dùng làm mức
tín hiệu tuyệt đối (dBm), giá trị **dương** được coi là SNR và cộng vào `noise` mà node báo. Trên
board này `noise` báo −116 / −113 dBm, nên để SNR dương sẽ ra ngưỡng vô nghĩa (SNR 20 → −96 dBm).
**Luôn dùng số âm.**

Đã bật mức nhẹ nhất trên cả hai máy (backup `/root/pre-sync-20261106/usteer.before-steering`):

```
uci set usteer.@usteer[0].roam_trigger_snr='-72'      # chỉ xét client yếu hơn -72 dBm
uci set usteer.@usteer[0].signal_diff_threshold='8'   # chỉ chuyển nếu AP kia hơn >= 8 dB
uci set usteer.@usteer[0].aggressiveness='1'          # BSS transition request thụ động, không
                                                      # disassoc imminent, không kick
```

Giữ nguyên `min_snr 0`, `assoc_steering 0`, `load_kick_enabled 0`, và **không** đặt `ssid_list`:
`usteer_check_node_enabled()` tắt hẳn node nào có SSID ngoài danh sách, nên đặt nó sẽ mất luôn
neighbor report của các SSID còn lại. `signal_diff_threshold 8` là cái chống ping-pong.

Còn lại là phép thử đi vòng (cần người): mang laptop/điện thoại đi từ AP này sang AP kia, rồi xem
`roam_events` có nhảy không và client có dính AP xa không. Công cụ: `tools/watch-roam.sh <ip1>
<ip2> [giây]` in mỗi vòng xem client nào đang ở AP nào, **cả hai** AP nghe nó bao nhiêu dBm, và
`roam_events` của từng BSS; MAC rút còn 5 ký tự cuối để dán đi đâu cũng được. Mẫu đọc được
ngay lúc bật: một client −66 dBm ở AP đang nối mà AP kia nghe −77 dBm → đúng là không nên
chuyển, và ngưỡng hiện tại cũng không chuyển. Ghi chú thêm: có một client ngồi ở **−94 dBm**
trên SSID khách của máy thứ hai mà máy thứ nhất không nghe thấy gì — usteer không làm gì được
cho ca này (không có AP nào tốt hơn để chuyển tới), nhưng đáng xem đó là thiết bị nào.

### Phép thử đi vòng: usteer có tác dụng, nhưng công lao thuộc về 802.11k

Vòng thứ nhất không có gì xảy ra, và đó là **đúng**: hai client trên SSID chính lúc đó ở −64/−68
dBm (ngưỡng −72), và AP kia nghe cái laptop ở −77 dBm, tức tệ hơn 9 dB — `signal_diff_threshold 8`
đòi AP đích phải **tốt hơn** ≥ 8 dB. Không có gì để sửa thì usteer không làm gì.

Vòng thứ hai, có ghi đường cong 2 s một mẫu (`tools/roamlog.sh` chạy trên cả hai AP, ghi `/tmp`
nên không mòn flash). Một điện thoại trên SSID chính đi từ máy thứ hai sang máy thứ nhất:

| giờ | việc |
|---|---|
| 21:16:11-21:17:04 | ở máy thứ hai, −50…−65 dBm |
| 21:17:08 → 21:17:28 | tụt: −77, −86, −93, −81 dBm |
| **21:17:20** | hostapd máy thứ hai: `BEACON-REQ-TX-STATUS … ack=1` rồi `BEACON-RESP-RX` — usteer xin **đo beacon 802.11k** và client **trả lời** |
| **21:17:30** | hostapd máy thứ nhất: `associated (aid 1)`, `AP-STA-CONNECTED auth_alg=sae`, client ở −64 dBm |
| 21:17:31 | usteer máy thứ hai ghi: `roaming station … to <bssid w-lan máy 1> disassociation timer 0, signal -88` |

Đọc kỹ thứ tự: hai AP lệch đồng hồ **0 giây** (cùng một giây epoch), nên client đã associate sang
máy thứ nhất **1 giây trước khi** usteer kịp gửi BSS transition request. Nên công lao không phải
là cái lệnh đẩy; nó là **beacon measurement request 10 giây trước đó**: usteer bắt client đi đo,
client thấy AP kia tốt hơn 24 dB rồi tự chuyển. Lệnh đẩy của usteer đến sau, vô hại
(`disassociation timer 0` = `aggressiveness 1`, thuần lịch sự).

**Đính chính chỗ tôi đọc sai**: `roam_events` **không** nằm trong `local_info`. Nó được đếm trên
đối tượng **node remote** (`local_node.c` tăng `source`, `remote.c` tăng `target`), nên phải xem
bằng `ubus call usteer remote_info`. Sau lượt roam này: máy thứ nhất thấy `…#w-lan` của máy thứ
hai có `source=1`, máy thứ hai thấy `…#w-lan` của máy thứ nhất có `target=1`. `local_info` vẫn
0/0 mãi mãi — nhìn vào đó mà kết luận "usteer chưa làm gì" là sai.

Hai điều chưa tốt, đo được từ cùng lượt này:

1. **Client đu tới −88/−93 dBm mới nhả.** Từ lúc vượt ngưỡng −72 (21:17:08) tới lúc chuyển
   (21:17:30) là 22 giây, trong đó có một nhịp −93. Muốn sớm hơn thì nâng `roam_trigger_snr` lên
   khoảng −68, hoặc `aggressiveness` lên 2 (thêm "disassociation imminent").
2. **Không dùng 802.11r.** Client vào bằng `auth_alg=sae`, tức SAE đầy đủ chứ không phải fast
   transition. Cấu hình không thiếu gì ở mức cơ bản: `mobility_domain=4f57` **giống nhau** trên
   cả hai máy, `wpa_key_mgmt=SAE FT-SAE WPA-PSK WPA-PSK-SHA256 FT-PSK`, `bss_transition=1`,
   `rrm_neighbor_report=1`, `rrm_beacon_report=1`, `ft_over_ds=0`. Thiếu chỗ khác:
   `ft_psk_generate_local=1` mà **không** có `r0kh`/`r1kh`/`nas_identifier`. Sinh khoá tại chỗ chỉ
   hợp lệ cho **FT-PSK**; **FT-SAE** thì PMK đến từ chính cuộc bắt tay SAE nên buộc phải có cặp
   key holder R0KH/R1KH khai hai chiều giữa hai AP. SSID đang là `sae-mixed`, nên client WPA3/SAE
   (tức các máy mới) **không** có fast transition, còn client WPA2-PSK thì có FT-PSK. Đây là việc
   đáng làm tiếp nếu muốn roaming mượt.

### Bật FT-SAE thật, và netifd tự lo khoá

Chỗ thiếu ở trên (`ft_psk_generate_local=1` chỉ hợp lệ cho FT-PSK) sửa bằng **một** option, không
cần sinh khoá bí mật nào. Đọc `/lib/netifd/hostapd.sh`: khi `ft_psk_generate_local=0` mà không
khai `r0kh`/`r1kh`, netifd **dẫn xuất** khoá FT bằng

```sh
ft_key=$(echo -n "$mobility_domain/${auth_secret:-${key}}" | md5sum | awk '{print $1}')
r0kh=ff:ff:ff:ff:ff:ff,*,$ft_key          # nhận PMK-R0 từ bất kỳ NAS id nào
r1kh=00:00:00:00:00:00,00:00:00:00:00:00,$ft_key
```

Hai AP cùng `mobility_domain` và cùng khoá SSID thì ra **cùng** `ft_key`, nên chỉ cần đặt giống
nhau trên cả hai máy là xong. Đã đặt cho SSID chính (`default_radio1`) trên cả hai:

```
uci set wireless.default_radio1.ft_psk_generate_local='0'
uci set wireless.default_radio1.nasid='<mac của w-lan, bỏ dấu hai chấm>'   # mỗi máy một giá trị
uci set wireless.default_radio1.pmk_r1_push='0'                            # pull khi cần
```

`nasid` là bắt buộc: không có nó thì netifd không ghi `nas_identifier`, mà đó chính là R0KH-ID.
Kiểm sau `wifi reload`: hai conf có **cùng** `r0kh`/`r1kh` key (md5 giống nhau từng ký tự) và
`nas_identifier` **khác** nhau — đúng yêu cầu. hostapd thay BSS gọn gàng
(`bss w-lan changed in ft_psk_generate_local, nas_identifier, r0kh, r1kh, pmk_r1_push, replacing
it`), client rớt một nhịp rồi vào lại. Lưu ý: khoá này không phải thứ mình chọn nên không có gì
để lưu riêng, nhưng nó **đổi theo khoá SSID**: đổi mật khẩu Wi-Fi là FT tự khớp lại trên cả hai.

SSID khách chưa bật `ieee80211r` nên chưa có FT; để dành.

Cùng lúc, siết usteer một bậc sau khi thấy client đu tới −88 dBm mới nhả:

```
uci set usteer.@usteer[0].roam_trigger_snr='-68'
uci set usteer.@usteer[0].aggressiveness='2'   # thêm "disassociation imminent"
```

Backup trước khi sửa: `/root/pre-sync-20261106/wireless.before-ftsae` và `usteer.before-tighten`
trên cả hai máy. (Lưu ý: thư mục đó trên máy thứ nhất **mất theo lần flash** ở mục 20 —
`keep.d` chỉ giữ `/root/auto-recovery` và `/root/pstore`. Bản chụp `/etc/config` trước khi
flash vẫn còn trong tarball ở `private-backups/`.) Kết quả thử: xem ngay dưới.

### FT vẫn không chạy, và đây là tất cả những gì đã loại trừ được

Tin tốt trước: **không cần đi vòng để test roaming nữa.** Đẩy client bằng chính lệnh 802.11v:

```sh
ubus call hostapd.w-lan bss_transition_request \
  '{"addr":"<mac>","disassociation_imminent":false,"disassociation_timer":0,
    "validity_period":30,"neighbors":["<NR hex của AP đích>"],"abridged":true}'
```

NR lấy bằng `ubus call hostapd.w-lan rrm_nr_get_own` trên AP đích. Client trả lời
`BSS-TM-RESP status_code=0` và chuyển trong **~1 giây**. Hai cái bẫy khi đo: (1) **đừng** dùng
`iw dev … station dump` để biết client đã chuyển chưa — entry cũ còn đọng lại hàng phút nên nó
báo "đã ở đây" sai; đọc dòng `associated` trong log của AP đích. (2) `ubus call` sẽ lỗi nếu client
không còn trên AP mình gọi.

Kết quả: FT **chưa bao giờ hoàn tất**. Mọi lần roam đều ra đúng một mẫu:

```
FT: Missing required pairwise in pull response from <AP nguồn>
STA <mac> IEEE 802.11: associated
AP-STA-CONNECTED <mac> auth_alg=sae      <- SAE đầy đủ, không phải ft
```

Đối xứng cả hai chiều, và không đổi khi: dùng wildcard `r0kh`/`r1kh`, hay khai **tường minh** cả
hai AP bằng MAC + nasid thật với một khoá 256-bit chung, hay bật `pmk_r1_push=1`.

Đọc source hostapd 2026.08.07 thì thông điệp đó chỉ ra đúng một chỗ: trong `wpa_ft_rrb_rx_pull()`,
nếu `wpa_ft_fetch_pmk_r0()` **không tìm thấy** thì hostapd vẫn gửi response nhưng dựng bằng
`wpa_ft_rrb_build()` thay vì `wpa_ft_rrb_build_r0()`, tức **không có TLV PMK/pairwise**; bên xin
kéo nhận được, giải mã được, rồi báo "Missing required pairwise". Nghĩa là:

- **Vận chuyển và khoá RRB đều đúng** — response giải mã được thì khoá r0kh/r1kh phải khớp, và
  frame L2 qua `ft_iface` (`br-lan.68`) đi được cả hai chiều.
- Thứ thiếu là **PMK-R0 ở AP nguồn**.

Phía client không có vấn đề gì: assoc request của điện thoại khai AKM `00-0f-ac:09` = **FT-SAE**,
có Mobility Domain đúng `4f57`, và có **PMKID**. (Nhưng laptop thì chỉ khai `SAE` trần — **nó sẽ
không bao giờ dùng FT** dù cấu hình thế nào. Đáng biết trước khi đi sửa.)

Đã loại trừ được, bằng cách đọc source chứ không đoán:

- `r0_key_lifetime` mặc định **1209600 s** (`ap_config.c`), không phải 0 → không phải hết hạn tức thì.
- `wpa_key_mgmt_sae()` trong `defs.h` **có** gồm `WPA_KEY_MGMT_FT_SAE` → nhánh lấy PMK của SAE
  không bị bỏ qua vì sai kiểu AKM.
- `nas_identifier` có trên cả hai máy và khác nhau; `mobility_domain` giống nhau; khoá FT giống nhau.

Chưa loại trừ được, và cần log hostapd mức `-d` mới biết: ở `SM_STATE(WPA_PTK, INITPSK)`
(`wpa_auth.c`), `sm->xxkey` — gốc của cả cây khoá FT — chỉ lấy từ PMK của SAE khi
`wpa_auth_uses_sae(sm) && sm->pmksa`. Nếu `sm->pmksa` chưa gắn vào station lúc đó thì trên SSID
`sae-mixed` hostapd đã copy **PSK** vào `xxkey` ở nhánh trên, và PMK-R0 sinh ra sẽ có PMKR0Name mà
client không bao giờ tính ra → đúng y hiện tượng "No matching PMK-R0-Name". Lưu ý
`wpa_auth_pmksa_add_sae()` chỉ thêm vào **cache**, nó **không** gán `sm->pmksa`.

Kết luận thực dụng: để nguyên cấu hình tường minh (đúng hơn wildcard, và vô hại), và **không đổi
SSID sang WPA2 chỉ để lấy FT-PSK**. Roaming đã chạy tốt bằng 802.11k/v + usteer; FT chỉ rút ngắn
thời gian xác thực lại. Muốn truy tiếp thì bước kế là chạy hostapd với `-d` (phải sửa
`/etc/init.d/wpad` và restart, Wi-Fi cả hai máy nhấp một nhịp), xem nó in gì quanh
`FT: Derived PMK-R0` / `XXKey`.

## 20. Vòng 1 tiết kiệm RAM: 999-998 + tắt BPF JIT, đo bằng page_owner

Nhánh `ram-round1` = bản đang chạy (`main` + 2 commit test DSA) + ba commit: 999-998 (mục 10),
`DEBUG: enable page_owner` (mục 3), và `TEST: tắt CONFIG_BPF_JIT` cho subtarget ipq50xx. Nạp vào
**slot 1** của máy thứ nhất, giữ config; **slot 0** còn bản mesh làm đường về. Kiểm trong kernel
config của ảnh: `# CONFIG_BPF_JIT is not set`, `CONFIG_PAGE_OWNER=y`, và `page_owner=on` có trong
ảnh. Phiên bản báo `r38369+5-0ee7daae5b`.

Đo lúc nghỉ, uptime 2 phút, không client Wi-Fi (`page_owner_stacks/show_stacks`, tổng 112,4 MiB
trong 486 stack):

| nhóm | lần này | đối chiếu |
|---|---|---|
| `ath11k_dp_link_desc_setup` (link descriptor) | **4,01 MiB** | 8,1 MiB ở mục 5 (không có 999-998); 4,07 MiB ở mục 10 (có) |
| mọi stack có chữ `bpf` | **5 trang = 20 KiB** | mục 10: vùng `bpf_prog_pack` **2 MiB** |
| `ath11k_ce_cleanup_pipes` (buffer CE, 999-997) | 1,38 + 1,34 + 0,62 ≈ **3,3 MiB** | 4,3 MiB ở mục 10, 17,9 MiB ở mục 5 |
| `nss_core_send_cmd` (payload pool NSS) | 15,30 MiB | 14,3-14,4 MiB ở mục 5/10 |
| `arch_execmem_alloc <- load_module` | 4,91 MiB | — (module kernel, không phải BPF) |
| MemAvailable | 36,9 MiB (gồm ~4,5 MiB `page_ext`) | bản mesh cùng máy, cùng mốc sau boot: 35,8 MiB |

Kết luận: **999-998 làm đúng việc** (4 MiB cho cả hai radio thay vì 8, tức 2 MiB mỗi radio), và
**tắt BPF JIT lấy lại đúng ~2 MiB**. Trừ ~4,5 MiB overhead của page_owner thì bản này hơn bản
mesh khoảng 5,6 MiB — khớp với dự đoán 4,1 + 2 MiB.

Một cái bẫy khi kiểm BPF: `/proc/vmallocinfo` **không** cho thấy vùng pack đó. Trên cả hai máy
(một bật JIT, một tắt) nó chỉ có đúng một dòng `bpf_prog_alloc_no_stats` 8 KiB. Phải dùng
page_owner mới thấy, nên đừng kết luận bằng vmallocinfo.

**Mục tiêu của vòng 2 hiện ra ngay trong cùng bảng** — hai stack, mỗi stack đúng 2,00 MiB:

```
2.00 MiB  512 pages  __page_pool_alloc_netmems_slow <- __init_dma_rx_desc_rings <- init_dma_desc_rings
                     <- stmmac_setup_dma_desc <- stmmac_open <- __dev_open
2.00 MiB  512 pages  __page_pool_alloc_netmems_slow <- __init_dma_rx_desc_rings <- init_dma_desc_rings
                     <- stmmac_setup_dma_desc <- stmmac_change_mtu <- netif_set_mtu_ext
```

Tức **4,00 MiB** page pool RX của hai GMAC, đúng bằng con số mục 9 suy ra từ việc đọc code, mà
firmware NSS đang nắm data plane nên hai ring này không nhận một gói nào. (Chi tiết nhỏ: một GMAC
được cấp qua `stmmac_open`, GMAC kia qua `stmmac_change_mtu` — lúc boot có thứ đổi MTU của nó.)

Sức khoẻ sau khi nạp: `eth0` 1000Mb/s link detected yes (patch 714 vẫn làm việc), `fw_mask` 0x3,
ba SSID lên, `NSS offload: active`, firmware `NSS.FW.12.5-210-MP.R`, VLAN 68/6/7 đủ.

## Việc còn lại

- ~~PR 50: chạy ngắn cùng commit không profile để so `Frame OOR`, `Overflow`,
  `tx_desc_alloc_fail`~~ — **bỏ, không làm nữa** (quyết định 2026-11-06). Bản mục 12 đã soak
  17,8 h và kuncy7 đã merge PR 50; phép A/B này chỉ còn giá trị học thuật, mà nó đòi một lần
  build + flash nữa.
- ~~Mục 15: soak tiếp nhiều ngày~~ — xong ở mục 16: 5 ngày 16 h trên bản DSA,
  `n2h_payload_alloc_fails` không tăng, MemAvailable 24-28 MiB, không rò.
- `PDEV resets` 5 GHz: 25 lần trong 5,7 ngày, chưa biết nguyên nhân. Đã bật ghi theo thời gian
  (memlong 10 phút ghi `pdr2`/`pdr5`); còn phải xem có đi kèm sự cố nào, và so với bản không
  NSS Wi-Fi offload. Đã loại trừ việc rút điện/di dời: bộ đếm nằm trong phiên firmware nên mỗi
  lần boot nó về 0, mà 25 lần đó tích trong một phiên uptime liền 5 ngày 16 h.
  Đo thêm 2026-11-06: máy thứ hai (cùng build, uptime 4,7 h) `PDEV resets` = 0 cả hai radio —
  chưa đủ dài để kết luận gì (4,4 lần/ngày thì 4,7 h mới ~0,9 lần). Từ 2026-11-06 20:21
  `memlong.sh` chạy lại trên **cả hai** máy (`start-stop-daemon -S -b -m -p /var/run/memlong.pid`,
  ghi `/root/memlong.log` mỗi 10 phút) để có hai chuỗi thời gian so sánh được; nhớ là nó không
  tự chạy lại sau boot.
- ~~Thử `CONFIG_ATH11K_NSS_MESH_SUPPORT`~~ — xong ở mục 17: build, nạp cho cả hai AP, dựng link
  802.11s thật, NSS mesh offload tạo được interface. **Dừng ở đây** (quyết định 2026-11-06):
  chỉ dùng backhaul **dây**, nên không đo thông lượng mesh đi xuyên và không thử mesh 5 GHz
  nữa. Hai AP giữ nguyên: cùng SSID, cùng khoá, 802.11r/k/v, nối nhau bằng một sợi trunk.
  Việc test còn ý nghĩa là **roaming trên backhaul dây**: đi vòng với laptop/điện thoại, xem
  hostapd có `FT` reassociation hay không, client có dính AP xa không, và quyết định có cần
  `usteer` không. Bản build vẫn mang `wpad-mesh-mbedtls` + `CONFIG_ATH11K_NSS_MESH_SUPPORT`
  (tốn ~262 KB ảnh, 28 KB module); không gỡ, để dành đường thử lại sau.
- ~~Thêm `usteer`~~ — xem **mục 19**: nó đã tự chạy sẵn trên cả hai AP (mặc định của gói bật
  service), chỉ là không steer gì vì mọi ngưỡng mặc định bằng 0; đã bật mức nhẹ nhất ngày
  2026-11-06. Còn lại: phép thử đi vòng, rồi quyết định có nâng `aggressiveness` không.
  `luci-app-usteer` vẫn chưa thêm. 802.11r sẵn trong `wpad-mesh-mbedtls` như cũ, và usteer
  **không** liên quan gì đến mesh — nó điều hướng client giữa các AP qua LAN, backhaul dây hay
  vô tuyến đều dùng được.
- ~~Script chuyển cấu hình từ bản hzyitc (swconfig, OpenWrt 23.05.3) sang bản DSA này~~ —
  `Convert-HzyitcConfig.ps1` đã kiểm bằng một backup thật, kết quả đã chạy trên máy thứ hai
  (xem mục 17), và nay đã commit vào `tools/hzyitc2nss/` của branch này. Còn lại: nếu muốn ai
  khác dùng thì nên đưa ra repo riêng, và README đang là tiếng Anh + một mục "dùng nhanh" tiếng Việt.
- ~~Mục 8: vì sao hạ pool xuống 2048 làm cạn~~ — xong, xem cuối mục 8: 2048 = `n2h_low_water_core0`.
- ~~Mục 16: gửi patch 714 lên openwrt/openwrt~~ — xong: PR #26511, CI 3/3 pass, mô tả đã sửa
  theo số đo ở đính chính lần hai. Còn lại: theo phản hồi reviewer, nhờ người có Redmi AX5400 /
  PZ-L8 kiểm chứng, và gửi bản `[PATCH net-next]` lên netdev. PR bỏ hook vào
  kuncy7/openwrt-nss-edma **hoãn** tới khi patch vào được `c3po-tag-8021q`.
- 999-998: đã đo lại ở **mục 20** (4,01 MiB cho cả hai radio, đúng như thiết kế). Còn lại:
  thử nhiều client (điện thoại, laptop, IoT) để chắc 16384 link descriptor đủ.
  **Lưu ý quan trọng (kiểm 2026-11-06)**: patch này chỉ có trên nhánh `testing`, **không** có
  trong bản đang chạy. Hai máy đang chạy `main` + 2 commit test DSA (`2a54850797`); log build
  cho thấy 999-990…997 đều được apply, **999-998 thì không**. Nghĩa là hai AP hiện dùng kích
  thước gốc (64 client, 32768 descriptor, 4 MiB DMA mỗi radio), nên số liệu lẻ "4 client trong
  4,7 h, mọi `*_desc_alloc_fail` = 0" là **đường cơ sở của bản không có patch**, không nói gì về
  việc 16384 có đủ hay không. Muốn thử thật thì phải build nhánh `testing` rồi flash.
- BPF JIT: được gì — vùng `bpf_prog_pack` **2 MiB** cấp lúc boot cho đúng một chương trình BPF
  (`ptp_classifier_init`, dùng để nhận gói PTP; board này không dùng PTP). Tắt `bpf_jit_enable`
  bằng sysctl **không** có tác dụng vì nó JIT trong `sock_init` trước mọi sysctl (mục 10, phần
  3), nên chỉ còn cách tắt `CONFIG_BPF_JIT` trong kernel config, mà config đó dùng chung cho
  mọi board ipq50xx — phải hỏi upstream trước.
- Mục 18: mở PR nhánh `nss-tools-fw-mask` vào `main` của fork, và build một ảnh mang bản sửa
  (chỉ cần trước lần flash kế tiếp — hai máy đang có override `0x3` nên hành vi y hệt).
- Giải phóng buffer RX stmmac khi NSS claim (mục 9, sửa patch 0956): được ~**4 MiB** (mỗi GMAC
  một page pool 2 MiB cho ring RX 512, mà khi firmware NSS đã claim data plane thì ring của
  host không nhận gói nào). Phần `-EBUSY` của việc này **đã xong từ 2026-10-26**, xem mục 9.
- `coherent_pool`: xem PR 45. Pool bộ đệm trống NSS: mục 8, không hạ được.
