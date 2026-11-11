# CR8806: ghi chép thử nghiệm RAM khi chạy NSS Wi-Fi offload

Branch `notes` chỉ chứa ghi chép, không chứa cây OpenWrt:
- `NOTES.md` (file này): các thử nghiệm RAM và Wi-Fi trên CR8806.
- `pr45-followup.md`: các bước test cho review PR 45 (tiếng Anh).
- `tools/`: script đo dùng trong hai file trên, `tools/publish-packages.sh` (dàn kho package cho
  release, xem mục 27), và `tools/hzyitc2nss/` (converter cấu hình
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

## 21. Vòng 2: trả lại buffer RX của host khi firmware NSS nắm GMAC

Patch `0958b-net-stmmac-give-the-host-RX-buffers-back-while-the-data-plane-is-claimed.patch`,
nhánh `ram-round2` (= `ram-round1` + 1 commit). Mục tiêu là đúng hai stack 2,00 MiB tìm được ở
mục 20.

Vì sao chúng tồn tại: `__alloc_dma_rx_desc_resources()` tạo một `page_pool` với
`pool_size = dma_rx_size` (mặc định **512**), rồi `__init_dma_rx_desc_rings()` nạp đủ 512 trang
vào ring. Với trang 4 KiB là **2 MiB mỗi GMAC**, board này hai GMAC nên **4 MiB** — mà sau khi
`qca_dwmac_dp_claim()` chạy thì kênh DMA của host đã stop và firmware dùng ring riêng của nó,
nên 512 trang đó không bao giờ nhận một byte nào.

Một chi tiết quan trọng: **không thể chỉ "free buffer"**. `page_pool` tái dùng trang — trả trang
về pool chỉ cho nó vào ptr_ring của pool chứ không về lại cho hệ thống, mà `pool_size` đúng bằng
512 nên pool giữ được hết. Phải `page_pool_destroy()` mới thật sự nhả, tức phải giải phóng cả
*resources* của ring, không chỉ buffer.

Patch làm ba việc:

1. **Lúc claim**, sau khi TX đã tắt, NAPI đã tắt và DMA đã stop — tức không còn gì chạm vào ring
   — gọi `qca_dwmac_dp_park_rx()`: `__free_dma_rx_desc_resources()` cho từng queue RX.
2. **Lúc release**, trước khi bỏ mask IRQ và trước khi NAPI được bật lại, gọi
   `qca_dwmac_dp_unpark_rx()`: `__alloc_dma_rx_desc_resources()` + `__init_dma_rx_desc_rings()`,
   bỏ qua queue nào vẫn còn resources, và chỉ làm khi `netif_running(dev)`. (Hợp đồng của 0956
   vẫn bắt chủ claim bounce interface sau release, nên ring vừa cấp lại chỉ sống một nhịp; cấp
   lại để đường free/poll phía sau gặp đúng trạng thái nó mong đợi thay vì NULL.)
3. Làm `__free_dma_rx_desc_resources()` **idempotent**: xoá con trỏ sau khi free
   (`buf_pool`, `page_pool`, `dma_rx`, `dma_erx` = NULL) và return sớm khi không còn gì. Cần,
   vì giờ ring bị free hai lần: một lần lúc claim, một lần khi interface down.

Ba chỗ bảo hiểm, vì đây là lối đi dễ panic:

- Nếu cấp lại lúc release **thất bại** (ENOMEM — đúng cái mình vừa cho đi), patch **không** bỏ
  mask IRQ (giữ `dp_irq_off`, để đường `stmmac_free_irq()` cân lại sau), và log `netdev_err`.
- `stmmac_rx()` return 0 ngay nếu `rx_q->page_pool == NULL`. Dòng đầu hàm này là
  `page_pool_get_dma_dir(rx_q->page_pool)` nên không có cái guard này là NULL deref.
- `unpark` bỏ qua queue còn resources, nên nếu interface bị init lại trong lúc đang claim
  (ví dụ `change_mtu`) thì không cấp đè lên và không rò.

Vì sao **không** chọn cách "ring nhỏ ngay từ probe": nó làm hỏng đường host của bản không dùng
NSS (và của chính board này lúc chưa claim), trong khi cách này chỉ ảnh hưởng đúng lúc firmware
đang nắm data plane. Phần chặn `ethtool -G/-L` lúc đang claim thì **đã có sẵn** từ 2026-10-26
(`0958a-...refuse-ring-and-channel-changes...`), không viết lại.

Trạng thái: **build xong, EXIT=0** (`build23-ram-round2.log`). Patch apply sạch (`using
plaintext`), và trong cùng build vẫn có `999-998` + cả hai `0958a-*` của kuncy7. Ảnh giữ ở
`images-ramround2-343b135181/`. Bằng chứng code thật nằm trong kernel đã build: chuỗi
`host RX rings not restored` có trong `vmlinux` (trong `sysupgrade.bin` thì không thấy vì kernel
đã nén). Kernel config của ảnh: `# CONFIG_BPF_JIT is not set`, `CONFIG_PAGE_OWNER=y`.

### Đã nạp và đo: đúng 4 MiB, không hỏng gì

Nạp vào **slot 0** máy thứ nhất 2026-11-06 22:23 (`r38369+6-0ee7daae5b`), **slot 1 giữ vòng 1
làm đường về** (`fw_setenv flag_last_success 1; fw_setenv flag_boot_rootfs 1; reboot`). Backup
config trước khi nạp: `private-backups/home1-20261106-2222-pre-slot0.tar.gz`.

| đo lúc uptime 1 phút, không client | vòng 1 | vòng 2 |
|---|---|---|
| MemAvailable | 37188 kB | **41220 kB** (+4,03 MiB) |
| `__init_dma_rx_desc_rings` 512 trang | 2 stack × 2,00 MiB | **không còn** |
| `ath11k_dp_link_desc_setup` | 4,01 MiB | 4,01 MiB (999-998 vẫn đúng) |
| mọi stack `bpf` | 20 KiB | 12 KiB (JIT vẫn tắt) |

Chỗ `stmmac_setup_dma_desc` giờ chỉ còn 4 + 2 + 1 trang, và sáu trang còn sót dưới
`page_pool_dma_map` là slab của xarray dùng để tra địa chỉ DMA (24 KiB) — sinh ra ở nhịp ngắn
trước khi claim kịp park, không phải trang RX.

`dmesg` có `qca-dwmac: data plane claimed` cho **cả hai** GMAC và **không** có
`host RX rings not restored`. Cả hai cổng 1000Mb/s, `NSS offload` active, ba SSID lên.

**Phép thử đường release/unpark** (chạy tách bằng `start-stop-daemon` để nếu treo thì không kéo
theo phiên ssh): bounce `eth0` — chọn `eth0` vì nó là GMAC của cổng WAN, trên máy này không có
thiết bị nào cắm vào, còn `eth1` là trunk duy nhất đi ra. An toàn vì glue xử lý đúng:
`NETDEV_GOING_DOWN` → `dwmac_nss_port_unwind(..., restart_host=false)` → release **trước** khi
stmmac đóng (nếu không thì `stmmac_release` sẽ `napi_disable` lần hai trên queue mà claim đã
disable → treo vĩnh viễn với rtnl đang giữ, chuyện đã được ghi trong 0956).

```
ip link set eth0 down -> qca-dwmac: data plane released, bounce the interface to restore host DMA
                         MemAvailable 42264 kB
ip link set eth0 up   -> phys_if 0 waits for link before the NSS fw data plane
                         qca-dwmac: data plane claimed
                         fw DMA rings restored on phys_if 0, resumed at rx ... tx ...
                         MemAvailable 41612 kB, carrier 1, ping gateway 2/2
```

Điểm tinh ở đây: **unpark thành công là chứng minh được**, vì hàm chỉ im lặng khi trả về 0 —
mọi đường thất bại đều in `host RX rings not restored`. Không có dòng đó, mà sau đó
`dev_close`/`dev_open` của glue vẫn chạy sạch và firmware resume đúng ring đã lưu.

(Đính chính đơn vị: 41220 kB = **40,3 MiB**, không phải "41,2 MiB" — chỗ này tôi đã viết lẫn kB
thành MiB một lần.) Vòng 2 vẫn còn page_owner ngốn ~5 MiB, nên con số thật phải đo bằng bản
không page_owner — xem bảng tổng ở cuối mục này.

Nhắc lại cái bẫy `keep.d`: sau lần flash này `/root` của máy thứ nhất trống trơn, `memlong.sh`
mất theo. Đã copy lại (md5 `5d46cf13...`, khớp bản trong `tools/router-monitor/`) và chạy lại
bằng `start-stop-daemon -S -b -m -p /var/run/memlong.pid`.

Còn thiếu: **chưa đo thông lượng** — ảnh không có `iperf3` (gói thêm không sống qua sysupgrade),
nên muốn có số thì phải cài lại gói trên router.

### Bản sạch, không page_owner (để lấy con số RAM thật)

Nhánh `ram-round2-nopageowner`, tạo bằng `git rebase --onto <999-998> <commit page_owner>`, tức
**bỏ đúng commit DEBUG** chứ không revert: còn lại 999-998 + tắt BPF JIT + 0958b trên nền bản
đang chạy. Lúc rebase có conflict ở `config-default` vì hai commit cùng nối vào cuối file — giữ
lại duy nhất dòng `# CONFIG_BPF_JIT is not set`.

Build (`build24-nopageowner.log`) EXIT=0. Vì kernel config đổi nên OpenWrt **tự xoá cả cây
kernel** và làm lại từ đầu, nên hai patch được apply lại và kiểm được: `999-998` + `0958b` đều
có; `.config` của ảnh: `# CONFIG_PAGE_OWNER is not set`, `# CONFIG_PAGE_EXTENSION is not set`,
`# CONFIG_BPF_JIT is not set`; `bootargs-append` chỉ còn
`root=/dev/ubiblock0_1 swiotlb=1 coherent_pool=512K` (hết `page_owner=on`); chuỗi
`host RX rings not restored` vẫn có trong `vmlinux`, tức code vòng 2 nằm trong ảnh. Ảnh ở
`images-nopo-<commit>/`.

Đây là **bản đầu tiên không còn knob debug nào**, nên nó cũng là ứng viên để làm release.

Đã nạp vào **slot 1** máy thứ nhất 2026-11-07 00:18 (`r38369+5-0ee7daae5b`; số commit nhỏ hơn
bản trước đúng 1 vì đã bỏ commit page_owner), ghi đè `ram-round1`; **đường về giờ là slot 0** =
vòng 2 + page_owner, bản đã chạy ổn từ tối trước
(`fw_setenv flag_last_success 0; fw_setenv flag_boot_rootfs 0; reboot`). Backup config trước khi
nạp nằm trong `private-backups/`.

### Bảng tổng: RAM lấy lại được, đo cùng một script ở cùng mốc ~1 phút sau boot

| bản | MemAvailable | so với bản mesh |
|---|---|---|
| mesh (mục 17) — không patch nào, BPF JIT bật, ring RX host giữ nguyên | 35744 kB | — |
| vòng 1 (999-998 + tắt BPF JIT) **+ page_owner** | 37188 kB | +1,41 MiB |
| vòng 2 (+ trả buffer RX) **+ page_owner** | 41220 kB | +5,35 MiB |
| **vòng 2, bỏ page_owner** | **46224 kB** | **+10,23 MiB** |

Ba con số chênh nhau đúng như thiết kế: vòng 2 hơn vòng 1 **4032 kB** (≈ 4 MiB page pool RX của
hai GMAC), và bỏ page_owner lấy thêm **5004 kB** (`page_ext` + stackdepot). Tổng **10,23 MiB**
khớp gần như tuyệt đối với dự đoán 4,1 (999-998) + 2 (BPF JIT) + 4,0 (vòng 2) = 10,1 MiB.

Kiểm sau khi nạp: `qca-dwmac: data plane claimed` cho cả hai GMAC, **không** có
`host RX rings not restored`; `/sys/kernel/debug/page_owner_stacks` **không tồn tại** (đúng, đã
tắt); ba SSID lên; `NSS offload` active; VLAN 68/6/7 đủ. Lúc đo không có client nào trên máy
(reboot đẩy hết sang máy thứ hai) nên **46292 kB** đo lại sau đó là số lúc nghỉ thật.

`memlong.sh` lại mất theo flash (`keep.d`) — đã copy lại và chạy lại.

### Biết client đang nối máy nào, khi hai máy chung SSID

Ba cách, từ nhanh đến chắc:

1. **Kênh**: hai máy khác kênh 5 GHz (36 và 100) nên chỉ cần nhìn kênh. Trên Windows gọi được
   thẳng từ WSL: `netsh.exe wlan show interfaces` → in `AP BSSID`, `Channel`, `Signal`.
   **Bẫy**: SSID IoT của *cả hai* máy đều ở kênh 1, nên với client 2.4 GHz trick này vô dụng.
2. **BSSID**: dùng được cho mọi băng, và BSSID đã ghim cố định (mục trước) nên không đổi sau
   reboot — byte thứ năm khác nhau giữa hai máy.
3. **Hỏi từ phía router**: `tools/router-monitor/which-ap.sh` (để ngoài repo vì chứa IP LAN) —
   một lệnh in cả hai máy, cả ba SSID, kèm BSSID/kênh/signal từng client. Nó **lọc station
   chết** bằng cách đối chiếu `iw station dump` với `ubus call hostapd.<bss> get_clients`, vì
   station dump giữ entry cũ hàng phút (đúng cái bẫy đã làm đọc nhầm log ở mục 19).

Muốn client *nằm* trên một máy cụ thể để test thì đẩy bằng `bss_transition_request` (~1 giây,
mục 19), đừng trông vào may mắn. Đo thông lượng thì nên cắm dây vào `lan3` (VLAN 68 untagged) để
bỏ hẳn Wi-Fi khỏi phép đo.

## 22. Nạp bản sạch cho cả hai máy, và soát lại cấu hình roaming / backhaul dây

Nạp bản `ram-round2-nopageowner` cho **máy thứ hai** 2026-11-07 00:33, vào **slot 1** (máy đó
đang chạy slot 0), nên **đường về của máy thứ hai là slot 0 = bản mesh mục 17**. Giờ **cả hai
máy chạy cùng một build** (`r38369+5-0ee7daae5b`) — nghĩa là không còn máy nào làm đối chứng
"BPF JIT còn bật" nữa.

MemAvailable ở mốc ~1 phút: máy thứ hai **46768 kB**, máy thứ nhất 46224 kB — cùng hạng, lệch
do số client và DUID/hostname khác nhau. Trước đó bản mesh trên máy thứ nhất là 35744 kB.

Lưu ý khi reboot máy thứ hai: nó là cầu nối máy chính xuống máy thứ nhất, nên lúc nó reboot thì
**cả nhà mất mạng** ~40 s và laptop phải nhảy AP. Ghi vào slot không chạy nên nếu đứt giữa đường
thì slot đang chạy vẫn còn nguyên.

### Soát cấu hình: giống nhau ở đúng chỗ, khác ở đúng chỗ

Soát bằng `tools/router-monitor/check-roaming.sh` (để ngoài repo vì chứa IP LAN; nó in **md5**
của khoá chứ không in khoá).

| | giống nhau hai máy | khác nhau (đúng) |
|---|---|---|
| SSID + khoá | cả ba SSID cùng tên, cùng `key.md5` | — |
| FT | `mobility_domain 4f57`, cùng `ft_key.md5`, `ft_psk_generate_local=0`, `pmk_r1_push=1`, `r0kh`/`r1kh` 2 entry | `nasid` (= R0KH-ID) |
| 802.11k/v | `rrm_neighbor_report=1`, `rrm_beacon_report=1`, `bss_transition=1` trong conf đang chạy | — |
| PMF | `ieee80211w=1` trên SSID chính (bắt buộc cho SAE/FT-SAE) | — |
| usteer | chạy trên cả hai, `-68` / diff 8 / aggressiveness 2, `network lan`, `rrm_nr` cho cả **3** BSS | mỗi máy thấy đúng máy kia trong `remote_hosts` |
| VLAN | `bridge-vlan` 68/6/7 giống hệt nhau, lan3 untagged ở VLAN 68 | — |
| mesh | **0 wifi-iface nào `mode='mesh'`** trên cả hai → đúng quyết định chỉ dùng dây | — |
| kênh | 2.4 GHz: **cả hai đều kênh 1** | 5 GHz: 36 / 100 |

### Ba điểm hở tìm thấy — hai cái đầu đã vá ngay (2026-11-07)

1. **SSID IoT (2.4 GHz) và SSID khách không có 802.11k/v.** usteer vì thế gần như **không điều
   hướng được** client ở hai SSID đó: nó cần `rrm_nr` (11k) để gợi ý AP đích và
   `bss_transition` (11v) để đẩy; không có thì chỉ còn cách kick thô. Thêm `ieee80211k=1` +
   `bss_transition=1` cho hai SSID đó là rẻ, **không** cần FT, không đổi khoá. Rủi ro: vài
   thiết bị IoT cũ dị ứng 11k/v, nên bật rồi phải soát lại từng thiết bị.
2. **Hai máy cùng phát 2.4 GHz ở kênh 1** → đồng kênh, tự nhiễu nhau. Đổi một máy sang kênh 11
   thì giảm nhiễu nhưng roaming 2.4 chậm hơn (client phải scan sang kênh khác mới thấy AP kia).
   Với IoT phần lớn đứng một chỗ thì nên ưu tiên giảm nhiễu.
3. **`ft_over_ds=0`** trong conf đang chạy, tức FT chỉ đi over-the-air. Đây **không** phải
   nguyên nhân FT đang hỏng (nguyên nhân là thiếu PMK-R0, mục 19), nhưng nếu sau này sửa được FT
   thì có thể bật để roam ở vùng biên nhanh hơn.

### Đã vá: 802.11k/v cho IoT + khách, và tách kênh 2.4 GHz

Áp dụng trên **cả hai máy** (script chạy tách bằng `start-stop-daemon`, backup
`/root/pre-sync-20261107/wireless.before-kv`, và tự `cp` lại backup + `wifi reload` nếu không đủ
3 SSID lên lại):

```
uci set wireless.default_radio0.ieee80211k='1'   # SSID IoT, 2.4 GHz
uci set wireless.default_radio0.bss_transition='1'
uci set wireless.wifinet2.ieee80211k='1'         # SSID khách, 5 GHz
uci set wireless.wifinet2.bss_transition='1'
uci set wireless.radio0.channel='11'             # CHỈ máy thứ hai
```

Kết quả: cả ba SSID trên cả hai máy đều có `rrm_neighbor_report=1`, `rrm_beacon_report=1`,
`bss_transition=1` trong conf đang chạy; 3 SSID lên lại trên cả hai; kênh giờ là **36/1** ở máy
thứ nhất và **100/11** ở máy thứ hai; usteer vẫn thấy nhau, vẫn `rrm_nr` cho cả 3 BSS; ping
gateway ~1,1 ms từ cả hai.

Bằng chứng đi đến tận hostapd: `ubus call hostapd.<bss> rrm_nr_list` giờ trả **2 entry cho cả ba
BSS** trên cả hai máy — trước đó chỉ SSID chính có, vì hai SSID kia chưa bật `ieee80211k`. Tức
usteer đã thật sự cấp neighbour report cho IoT và khách, không chỉ là cờ trong file config.

**Chưa xác nhận được phần rủi ro**: lúc đổi không có **client IoT nào** đang nối (0 client ở
`w-iot` trên cả hai máy, cả trước và sau). Nên vẫn phải soát lại từng thiết bị IoT khi chúng
bật lên: nếu có cái nào dị ứng 802.11k/v thì nó sẽ không vào lại được, và cách lùi là bỏ hai
dòng `ieee80211k`/`bss_transition` của `default_radio0`.

Không đụng tới `ft_over_ds` (điểm hở thứ ba) — giữ 0.

Và nhắc lại cái đã biết: `wpa_key_mgmt` của SSID chính là
`SAE FT-SAE WPA-PSK WPA-PSK-SHA256 FT-PSK`, tức `sae-mixed` — đúng cấu hình nằm trong giả thuyết
còn lại về vì sao FT không hoàn tất (hostapd copy **PSK** vào `xxkey` khi `sm->pmksa` chưa gắn).

## 23. Người test báo 999-998 chặn TX: trả lại pool link descriptor theo thượng nguồn

Báo cáo nhận được 2026-11-07, từ người đang chạy bản có `ATH11K_NSS_MEM_PROFILE_256M` trên
CR8806 thật, nhiều client hơn hai máy ở nhà rất nhiều:

> On the first CR8806 AP running this build, the 2.4 GHz radio already serves 35 clients, above
> the 32 the halved WBM idle link pool is sized for. The 5 GHz radio also tops out near
> 200 Mbit/s to a wired iperf3 server (UDP 600 Mbit/s offered: NSS enqueues all of it without
> drops, TQM receives about a third, the rest completes as tx_failed with no retries while the
> channel is only 44% busy). Go back to the stock link descriptor pool (+2 MiB per radio) and
> measure again.

### Dấu vết nói gì

Mất gói **giữa TCL và TQM**, không retry, kênh mới 44% busy: frame không hề lên sóng. Đó đúng là
hình dạng của việc hết link descriptor — TQM lấy MSDU link descriptor từ WBM idle list, không lấy
được thì frame bị release kèm trạng thái lỗi. Không phải giới hạn của radio, không phải nhiễu.
999-998 chính là chỗ cắt một nửa cái list đó, nên nó là thứ phải bỏ trước.

### Nhưng con số 35 > 32 **không** tự nó giải thích được

`ath11k_wbm_idle_ring_setup()` cộng bốn nhóm rồi **làm tròn lên luỹ thừa của 2**, và chính phép
làm tròn đó cho rất nhiều dư:

| client | mpdu | queue | tx msdu | rx msdu | cần | pool sau làm tròn |
|---|---|---|---|---|---|---|
| 32 (999-998) | 1365 | 113 | 2340 | 5461 | 9279 | **16384** = 2 MiB |
| 35 | 1493 | 124 | 2560 | 5973 | 10150 | 16384 |
| 56 | 2389 | 199 | 4096 | 9557 | 16241 | 16384 |
| 64 (thượng nguồn) | 2730 | 227 | 4681 | 10922 | 18560 | **32768** = 4 MiB |

Tức pool bị cắt vẫn là 16384 descriptor, theo đúng công thức của driver thì đủ cho **56** client,
chứ không phải 32. Nên nếu bỏ 999-998 mà hết triệu chứng thì cơ chế thật không phải "quá số
client" mà là **độ sâu burst trên một pool dùng chung**: cả bốn nhóm rút từ cùng một WBM idle
list, và `DP_AVG_*` chỉ là số trung bình, không phải trần. Cắt từ 32768 xuống 16384 là lấy đi
phần dư mà phép làm tròn ở thượng nguồn vô tình tạo ra — 3,2 lần nhu cầu của 35 client còn 1,6
lần. Đừng ghi lại bài học này thành "sizing cho 32 client là sai vì có 35 client".

### Đã làm

- Revert `560ff3143e` → commit `f7703924de` trên `ram-round2-nopageowner`, xoá hẳn file
  `999-998-ath11k-nss-256m-link-descriptors.patch`. Nó độc lập: không patch nào khác tham chiếu
  `ATH11K_NSS_256M_NUM_TIDS`, phần Kconfig help của 999-991 cũng không nhắc link descriptor.
- Build lại: `build25-linkdesc-stock.log`, `EXIT=0` (có `make package/kernel/mac80211/clean`
  trước, vì patch ath11k thay đổi). Kiểm trong log: 31 patch `nss-extra/ath11k` được apply và
  **không** có 999-998; kernel config vẫn `# CONFIG_BPF_JIT is not set` /
  `# CONFIG_PAGE_OWNER is not set`. Ảnh cất riêng ở `images-linkdesc-stock/`.
- Nạp vào **slot 0 của máy thứ nhất** 2026-11-07 08:35 (`flash-linkdesc-stock-home1.log`), giữ
  config. Ghi đè bản `ram-round2` + page_owner cũ ở slot 0; **slot 1 vẫn là
  `ram-round2-nopageowner` có 999-998**, tức đường về và đồng thời là nhánh B của phép A/B. Máy
  thứ hai không đụng tới. Sau khi nạp: `eth0` 1000Mb/s link yes, ba SSID lên, `nss_offload=1`,
  cả hai radio báo `NSS 256 MiB: active`.
- `iperf3 3.22` **có sẵn trong ảnh** (`CONFIG_PACKAGE_iperf3=y` từ trước, manifest dòng
  `iperf3 - 3.22-r1`), không phải cài tay. Nó **không** nằm trong `keep.d` nên mất nếu flash bản
  không có nó. Máy thứ hai cũng có.
- `memlong.sh` cài lại và chạy lại (`start-stop-daemon -S -b -x /bin/sh -- /root/memlong.sh`;
  `nohup ... &` qua ssh **không** sống sót khi phiên đóng, đã thử hai lần). Chuỗi 51 dòng của
  bản cũ cất ở `soak-slot1-logs/home1-slot1-memlong.log`. Hai file `/root` có SSID/khoá
  (`pre-sync-20261107/wireless.before-kv`, `roamcfg.log`) chuyển vào `private-backups/` mode 600.

So RAM bằng chính `memlong.sh` trên cùng máy, cùng trường:

| bản | uptime | MemAvailable |
|---|---|---|
| `ram-round2-nopageowner` (có 999-998) | 122 s | 46668 kB |
| bản này (không 999-998) | 227 s | 43800 kB |

Chênh 2,8 MiB, và bản này đọc muộn hơn 105 s (MemAvailable còn tụt tiếp lúc đầu) — khớp với 4 MiB
trả lại trong phạm vi sai số. `/proc/vmallocinfo` đếm **6** vùng `dma-coherent` cỡ 2 MiB
(2101248 B tính cả guard page): bank link descriptor cấp theo `DP_LINK_DESC_ALLOC_SIZE_THRESH` =
2 MiB, nên thượng nguồn là 2 bank mỗi radio thay vì 1. `payfail` 25 so với 26 của bản cũ ở cùng
mốc boot, tức không đổi.

RAM: trả lại 4 MiB (2 MiB mỗi radio). Đúng bằng 4 MiB mà patch park RX ở mục 21 lấy về, nên so
với bản đang chạy trên hai máy thì gần như đứng yên — mục 20 đo MemAvailable 36,9 MiB.

### Đo thật 2026-11-07: không lặp lại được, và một mảnh bằng chứng của người test là ảo

Topo: laptop (client 5 GHz 2×2 HE160) → AP chỉ bridge → backhaul dây → router chính → server
iperf3 trên dây. Không AP nào kết thúc TCP, nên đây đúng là đường NSS. `iperf3` trên laptop cài
**không cần root**: `apt-get download iperf3 libiperf0 libsctp1` rồi `dpkg -x` vào một thư mục
riêng, chạy với `LD_LIBRARY_PATH` (thiếu `libsctp1` là nó báo không tìm thấy `libsctp.so.1`).

Laptop lúc đó đang ở **máy thứ hai**, tức bản **CÓ 999-998** — đúng nhánh cần đối chứng:

| phép đo (10 s, 4 luồng) | kết quả |
|---|---|
| TCP xuống (`-R`, AP truyền xuống client) | **921 Mbit/s**, 0 retransmit |
| TCP lên | 788 Mbit/s, 490 retransmit |
| `tx failed` của station trong lúc đo xuống | +28 trên +844k gói = 0,003% |
| `wifili[0..2]_tx_desc_alloc_fail` / `ext_` / `rx_` | **0** hết |
| `err ring pkts` | +374 |

921 Mbit/s là **trần của dây gigabit**, không phải trần của Wi-Fi. Nghĩa là **có 999-998 vẫn đạt
tốc độ dây**, và ~200 Mbit/s của người test không lặp lại được ở đây với một client nặng.

**Và `tx retries` của ath11k ở đường NSS luôn bằng 0.** Trên cả hai máy, 6 station, 2,4 triệu gói
và 720 lần `tx failed`, counter `tx retries` **không bao giờ** khác 0 — nó không được điền. Vì
vậy câu "tx_failed with no retries" trong báo cáo **không chứng minh** được gói chưa lên sóng;
rất có thể nó chỉ là counter chưa cài. Đây là mảnh bằng chứng tôi đã dựa vào để nói "đúng dấu vết
hết link descriptor" ở trên — phải hạ xuống thành *không loại trừ được*, chứ không còn là dấu vết.

Thêm một điểm phản bác chính giả thuyết: 2.4 GHz (`c000000.wifi`) và 5 GHz (`b00a040.wifi`) là
**hai `ath11k_base` riêng** (hai thư mục debugfs `ahb-*`, hai dòng `NSS 256 MiB: active`,
`ath11k_dp_alloc()` chạy một lần cho mỗi ab), nên mỗi radio có WBM idle list riêng. 35 client ở
2.4 GHz **không** rút được descriptor của 5 GHz.

Nhánh A (máy thứ nhất, **không** 999-998) chưa đo được: từ chỗ laptop đang ngồi,
`netsh wlan show networks mode=bssid` chỉ thấy **một** BSSID cho SSID chính — của máy thứ hai.
BSSID ch 36 của máy thứ nhất không hiện, tức ngoài vùng phủ. Muốn đo nhánh A phải mang laptop lại
gần máy thứ nhất. Mà vì dây đã là trần ở 921 Mbit/s thì nhánh A cũng chỉ ra con số đó — nó chỉ
còn giá trị kiểm tra không thụt lùi.

**Giữ hay bỏ revert?** Giữ: nó trả lại đúng hành vi thượng nguồn, và 4 MiB đó đã được patch park
RX ở mục 21 bù lại, nên không mất gì. Nhưng lý do phải ghi đúng: **chưa tái hiện được lỗi, một
mảnh bằng chứng là ảo, và vẫn không loại trừ được** — chứ không phải "đã xác định 999-998 chặn
TX".

### Nghi phạm thứ hai, để dành cho vòng sau

Nếu 5 GHz vẫn dừng ở ~200 Mbit/s sau khi bỏ 999-998 thì tới lượt
**`999-992-ath11k-nss-256m-tx-descriptor-pools.patch`**: nó vừa hạ pool TX descriptor của NSS từ
`ATH11K_WIFILI_DBDC_NUM_TX_DESC` = 8192 xuống 4096 mỗi radio, **vừa** kẹp
`ath11k_nss_radio_buf_cfg()` từ `ATH11K_NSS_RADIO_TX_LIMIT_RANGE3` = 8192 xuống 4096 — tức trần
buffer TX đang bay của mỗi radio cũng bị chia hai. Dòng boot `tx_desc=4096 tx_comp=4096` là nó.
Điểm chống lại nghi phạm này: người test nói NSS nhận hết, không drop, mà hết pool TX descriptor
thì phải thấy drop ngay ở chỗ enqueue. Vì vậy: **một biến một lần**, bỏ 999-998 trước, đo lại, rồi
mới tính đến 999-992 (nó tiết kiệm ~2 MiB).

### Lần sau nên xin người test số gì

`ethtool -S` không có ở đường NSS, nên xin `cat /sys/kernel/debug/ath11k/*/htt_stats` với
`stats_type` 1 (PDEV TX) và 5 (TX HWQ), cộng `tx_desc_alloc_fail`, `n2h_payload_alloc_fails` ở
`/sys/kernel/debug/qca-nss-drv/stats/`, và số client của **từng** radio lúc đo. Hiện tại không có
cách nào phân biệt "hết link descriptor" với "hết TX descriptor của NSS" từ dữ liệu đã nhận.

## 24. Cắt USB, ext4 và iperf3 khỏi ảnh; và vì sao giữ `wpad-mesh-mbedtls`, bỏ `zram-swap`

Máy không có cổng USB, mà DTS của nó (`target/linux/qualcommax/dts/ipq5018-cr8806.dts`) **không
có node `usb` nào**. Dù vậy trên router vẫn thấy nạp đủ driver, toàn bộ **0 user**, và
`/sys/bus/usb/devices/` rỗng — chúng nạp chỉ vì nằm trong `DEFAULT_PACKAGES` của target:

| module | kích thước |
|---|---|
| `xhci_hcd` | 147 KB |
| `dwc3` | 52 KB |
| `dwc3_qcom`, `dwc3_qcom_legacy`, `xhci_pci`, `xhci_plat_hcd` | 57 KB |
| **tổng USB** | **256 KB** |
| `ext4` (0 user) + `jbd2` + `mbcache` | **540 KB** |

`e2fsprogs`/`losetup`/`kmod-fs-ext4` cũng ở `DEFAULT_PACKAGES`, và chúng chỉ có nghĩa khi có ổ
ngoài — không USB thì không có ổ ngoài. Bỏ cả. `iperf3` + `libiperf3` bỏ theo yêu cầu (512 KB
flash); nhớ là **ảnh trước đó có sẵn iperf3 3.22**, nếu cần đo lại thì hoặc thêm lại vào build,
hoặc cài qua `apk` sau khi nạp (`/root` và gói thêm đều bị `keep.d/nss-tools` xoá mỗi lần flash).

### Cái bẫy: dấu `-` trong `DEVICE_PACKAGES` **không đủ**

Thêm `-kmod-usb3 -kmod-usb-dwc3 -kmod-usb-dwc3-qcom -kmod-fs-ext4 -e2fsprogs -losetup` vào
`DEVICE_PACKAGES` của `Device/xiaomi_cr8806`. Nó vào được metadata:

```
Target-Profile-Packages: ath11k-firmware-ipq5018-qcn6122 ipq-wifi-xiaomi_cr8806
                         -kmod-usb3 -kmod-usb-dwc3 ... -losetup
```

**Nhưng ảnh vẫn có chúng.** `build26` vẫn chạy `(142/197) Installing kmod-usb3`, ảnh chỉ nhỏ đi
đúng 512 KB của iperf3. Lý do: `filter_packages` (`include/target.mk`) chỉ áp lên danh sách
profile, còn `DEFAULT_PACKAGES` của target đã biến thành `CONFIG_PACKAGE_x=y` lưu trong `.config`
và cái đó thắng. Xoá hẳn mấy dòng đó rồi `make defconfig` thì chúng **quay lại `=y`**.

Cách chạy được: ghi thẳng `# CONFIG_PACKAGE_<x> is not set` cho cả 7 gói USB (3 gói đầu + 4 gói
phụ thuộc `kmod-usb-core`/`-common`/`-roles`/`-xhci-hcd`) và 3 gói storage, rồi `make defconfig`.
Kconfig chốt lại thành **`=m`** — build thành gói nhưng **không cài vào ảnh**, đúng thứ cần.

Giữ **cả hai**: dòng `-...` trong `ipq50xx.mk` (đúng ý nghĩa thiết bị, và có tác dụng với
ImageBuilder hoặc khi sinh config mới) và `.config` tắt dứt khoát (cái này mới chặn ở build này).

Kết quả `build27-nousb-noiperf.log`, `EXIT=0`:

| | trước | sau |
|---|---|---|
| gói trong manifest | 197 | **187** |
| `sysupgrade.bin` | 16.814.351 B | **16.240.911 B** |
| grep `usb|iperf|ext4|e2fsprogs|losetup` trong manifest | 10 dòng | **0** |

`fstools` và `mtd` vẫn còn (cần cho overlay UBIFS và sysupgrade); `block-mount` chưa bao giờ được
cài. Ảnh cất ở `images-nousb-noiperf/`. **Chưa nạp** — dự kiến lấy lại ~800 KB module memory,
phải nạp mới đo được. Muốn hoàn lại thì xoá ba chữ `-kmod-fs-ext4 -e2fsprogs -losetup` và bật lại
`=y` trong `.config`.

Kernel vẫn còn `CONFIG_USB=y` built-in (usbcore đăng ký 3 interface driver lúc boot). Tắt nó là
thay đổi `target/linux/qualcommax/config-6.18`, tức **toàn target** — mà GL-X2000 cùng subtarget
ipq50xx thì có USB thật (`kmod-usb-net-qmi-wwan`). Không làm, cái giá còn lại rất nhỏ.

### `wpad-mesh-mbedtls`: giữ nguyên

`wpad` = một binary chứa **cả `hostapd` (phía AP) và `wpa_supplicant` (phía station)**; trên
router nó được symlink thành hai chỗ nên `ps` thấy hai process riêng. Tên gói có hai trục: hậu tố
crypto (`-mbedtls`/`-openssl`/`-wolfssl`/không có = crypto nội bộ) và mức tính năng
(`mini` < `basic` < `mesh` < `full`).

Đọc `package/network/services/hostapd/Makefile`: variant `mesh` đặt `CONFIG_VARIANT:=full`, tức
dùng **đúng template cấu hình của full** rồi thêm `CONFIG_AP=y CONFIG_MESH=y CONFIG_WPS_NFC=1`,
nhưng không thêm những thứ chỉ `full` có (`OWE`, `SUITEB192`, `EAP_PWD`, `DPP`/`DPP2`).

Hạ xuống `wpad-basic-mbedtls` (gói 570 KB thay vì 859 KB) **không được**:

```
hostapd-basic.config:162:  #CONFIG_WNM=y     <- bị comment
hostapd-full.config:162:    CONFIG_WNM=y
```

`CONFIG_WNM` chính là 802.11v BSS Transition Management, tức `bss_transition` đã bật cho cả ba
SSID ở mục 22. 802.11r thì basic **có** (`CONFIG_IEEE80211R=y` ở cả hai file), 802.11v thì không.
Và 290 KB chênh lệch gần như không tốn RAM: text được demand-page thẳng từ squashfs, phần code
EAP/WPS không ai gọi thì không vào RAM. RSS thật lúc chạy: `hostapd` 4176 kB,
`wpa_supplicant` 3472 kB. → `wpad-mesh-mbedtls` là variant nhỏ nhất còn có WNM, giữ.

### `zram-swap`: không thêm

Gói ở `package/system/zram-swap`, cần thêm `kmod-zram` + thư viện nén: nó tạo một block device
nén trong RAM rồi `swapon`, trang bị swap ra được nén 2-3:1 và vẫn nằm trong RAM. Ba lý do không
dùng:

1. Áp lực RAM ở đây là **bộ nhớ kernel không swap được**: DMA coherent (link descriptor),
   `page_pool` RX của hai GMAC, payload pool NSS 15,3 MiB, buffer CE. Swap chỉ nhận trang
   anonymous của userspace.
2. Userspace bé tí: đo trên router `AnonPages: 5960 kB`. Đó là **trần tuyệt đối** của những gì
   zram có thể nén; nén nửa ở 3:1 thì lãi ~2 MiB.
3. Khi cạn bộ nhớ DMA coherent, kernel **OOM trong lúc swap vẫn trống** — zram không che được
   đúng chế độ lỗi mình đang lo.

Đổi lại là metadata zsmalloc, CPU nén/giải nén trên đường nóng, và một tầng nữa phải loại trừ khi
debug. So với 4 MiB của patch park RX và 2 MiB của tắt BPF JIT thì không đáng. Nếu sau này RAM
căng thật, thứ đáng nhắm là **payload pool 15,3 MiB của NSS**, không phải swap.

## 25. Cập nhật thượng nguồn 137 commit, dọn lịch sử `main`, và release `cr8806-nss-2026.11.07`

### Thượng nguồn

Không có remote `upstream`; thượng nguồn của cây này là `origin` = kuncy7/openwrt-nss-edma, nhánh
`c3po-tag-8021q`. Lúc kiểm: **137 commit mới**, 275 file, +29.143/−1.640. Phần lớn không liên quan
(backport driver DSA Motorcomm YT921x, realtek, airoha, busybox), **nhưng** có hai cái đụng đúng
chỗ mình: `ea585ed832` đổi số thứ tự các giá trị DSA tag protocol ngoài cây, và `d1b5d4f8ec` mở
rộng hook bridge VLAN của 0959b. Chỉ **3 file patch mình đang dựa vào** bị sửa:

```
M target/linux/qualcommax/patches-6.18/0955-net-dsa-tag_qca-add-a-variant-behind-an-ethertype.patch
M target/linux/qualcommax/patches-6.18/0959-...-Airoha-AN8855.patch
M target/linux/qualcommax/patches-6.18/0959b-net-dsa-retain-vlan-upper-filtering-for-vlan-taggers.patch
```

Không commit nào của mình đụng vào chúng, nên rebase `main` (6 commit) rồi rebase nhánh build (7
commit) **sạch, không một xung đột**. `build28-upstream-1107.log` `EXIT=0`, và quan trọng nhất:
**không một hunk nào fail** — cả `714-net-dsa-open-the-conduit...` và `0958b-net-stmmac-give-the-
host-RX-buffers-back...` vẫn apply lên nền DSA mới. Kernel 6.18.55 → **6.18.60**.

### Dọn lịch sử `main`

Quyết định 2026-11-07: đưa 6 commit của nhánh build lên `main` rồi tag `main` (giống cách làm
release 2026.10.27), thay vì tag tip một nhánh tên `ram-round2-nopageowner`. Ba việc đã làm:

1. Bỏ tiền tố `TEST:` khỏi ba commit, và sửa phần thân nói "for testing only" / "to be tested".
2. **Xoá hẳn cặp thêm-rồi-revert 999-998** (hai commit triệt tiêu nhau). Đã kiểm `git diff` giữa
   nhánh build và `main` mới → **rỗng**, hai cây y hệt nhau.
3. Dịch commit tắt BPF JIT sang tiếng Anh cho đồng bộ với phần còn lại của `main`.

Trong commit 714 viết `openwrt/openwrt issue 26157` và `PR 26511` **không dấu `#`**, để không dán
thêm reference event lên issue/PR của người khác (bài học mục 23).

**Bảng đổi SHA** — những số cũ mà các mục trên còn nhắc tới:

| mục nào nhắc | SHA cũ | giờ là |
|---|---|---|
| 0958b trả buffer RX (mục 21) | `94d1d1c23d` | `46b15a658e` |
| cắt USB/ext4 (mục 24) | `157f92e5d6` | `7735441d3c` |
| thêm 999-998 / revert nó (mục 23) | `560ff3143e` / `f7703924de` | **không còn trên `main`** |
| `main` trước rebase | `0ee7daae5b` | `7735441d3c` |

Hai commit 999-998 chỉ còn trong `backup/main-pre-rebase-20261107` và
`backup/ram-round2-nopageowner-pre-rebase-20261107` (cả hai còn trong repo gốc), cộng nhánh
`ram-round2-nopageowner` vẫn nguyên chưa xoá.

### Một cái bẫy nữa: `DISTRIB_REVISION` đếm commit

`getver.sh` sinh chuỗi `r<N>+<số commit>-<hash>`. Nhánh build có **150** commit tính từ
`fb7e09acfe`, `main` sau khi xoá cặp 999-998 còn **148** — tức chuỗi nướng trong ảnh **khác nhau**,
và ảnh của `build28` không còn khớp với tag. Phải build lại từ `main` đã dọn (`build29`, có
`make package/base-files/clean` trước). Kết quả `r38363+148-fb7e09acfe`, đúng số.

Và lưu ý con số **trông như đi lùi**: 2026.10.27 là `r38064+2`, các bản sáng nay `r38369+5`, bản
này `r38363+148`. Không phải lùi: kuncy7 merge một nhánh có lịch sử sắp xếp lại, nên `getver.sh`
chọn một commit cũ hơn làm mốc rồi đếm 148 commit trên nó.

### Nạp và kiểm trước khi phát hành

Nạp `images-release-20261107/` vào **slot 1 của máy thứ nhất** 2026-11-07 10:20
(`flash-release-20261107-home1.log`). Đường về là slot 0 = bản sáng nay. Lưu ý điều này **ghi đè
bản có 999-998** ở slot 1, nên nhánh B của phép A/B tại nhà giờ chỉ còn ở **máy thứ hai**.

| kiểm | kết quả |
|---|---|
| lên slot mới sau reboot | 30 s |
| `DISTRIB_REVISION` | `r38363+148-fb7e09acfe` |
| `eth0` (patch 714, không hook preinit) | **1000Mb/s, Full, Link detected: yes** |
| DSA / switch | `DSA: tree 0 setup`, rồi `qca-dsa-nss: firmware vlan nodes for tag_8021q DSA ports` và một vlan node cho mỗi cổng LAN |
| VLAN 68/6/7, `lan1:t lan2:t lan3:u*`, ba SSID | đủ |
| `nss_offload` | 1, cả hai radio `NSS 256 MiB: active` |
| module usb/xhci/dwc3/ext4/jbd2/mbcache | **không còn cái nào** |
| `iperf3` | không có |
| `dmesg` lỗi | chỉ 3 dòng quen cũ (psci firmware bug, `rdinit=/init failed`, cảnh báo ECC `qcom_snand`) |
| MemAvailable 1-2 phút sau boot | 44372 / 44448 kB, 1 client 5 GHz |

Chính là chỗ mà 137 commit DSA có thể làm đổ — `tag_8021q` trên AN8855 — và nó không đổ.

### Và một kết quả âm, phải ghi đúng

MemAvailable lúc 1 phút: **44372 kB**, so với **44520 kB** của bản sáng nay (vẫn còn
USB/ext4/iperf3). Tức ~800 KB module bỏ đi **không hiện ra thành lợi** — có vẻ kernel mới
6.18.55→6.18.60 lấy lại. `lsmod` xác nhận module đã biến mất thật, nên cái mất là ở chỗ khác.
Đừng ghi 800 KB đó vào cột lãi. Hai con số 4 MiB (park RX) và 2 MiB (BPF JIT) thì mỗi cái đã đo
với nền riêng của nó và vẫn đúng.

### Release

**`cr8806-nss-2026.11.07`** — pre-release, tag trỏ `7735441d3c`, 7 asset (sysupgrade.bin,
factory.ubi, initramfs.itb, manifest, config.buildinfo, feeds.buildinfo, sha256sums). `fork/main`
đã force-push từ `0ee7daae5b` sang `7735441d3c` (dùng `--force-with-lease`).

Release notes viết **tự chứa**: nhánh `notes` chưa push nên không link tới mục 20-25, mọi số liệu
cần để đánh giá đều nằm trong trang release. Có cả phần "Not tested" nói thẳng: chưa soak, chưa
cold boot, chưa đo throughput **trên bản này** (921 Mbit/s là đo trên nền cũ, ở máy thứ hai), chưa
thử nhiều client, chưa đo lại roaming sau rebase.

## 26. Hai GMAC, một con switch: conduit là gì, cái bug DSA chặn conduit thứ hai, và patch

Mục này trả lời một câu hỏi tưởng đơn giản mà hoá ra là gốc của cả mục 16 và mục 18: **cổng WAN
"chạy trên eth nào", tách nó ra khỏi LAN thì được gì, và vì sao thượng nguồn tắt hẳn CPU port thứ
hai.** Kết thúc bằng một patch DSA, một PR gửi kuncy7 và một release. Kết luận sau ba ngày đo, theo
thứ tự quan trọng:

1. **Một conduit trần ~930 Mbit/s routed, tính cả hai chiều cộng lại** — vì một frame routed qua
   conduit của nó hai lần.
2. **Bật CPU port thứ hai trong DTS mà để nguyên là tai hoạ**: không mang cổng nào, không được
   arm, vẫn tốn 932 → 723 Mbit/s và trọn một core (softirq cpu0 91%). Nên `a67d696c5d` của thượng
   nguồn **đúng** — đúng cả thay đổi lẫn cơ chế nó nêu, với cấu hình mặc định.
3. **Nhưng cái tai hoạ đó là một bug của DSA, sửa được** — và sửa rồi thì hai conduit **phá được
   trần**: trần một conduit là 927–929 Mbit/s hai chiều (ba lượt lệch 2 Mbit/s), hai conduit cho
   **1104–1458** — luôn vượt, tán rộng là vì máy đo chứ không phải router — với softirq ~2,5% và
   ECM accelerate 9 flow. Nguyên nhân là `dsa_port_tag_8021q_vlan_match()` cho **mọi** CPU port làm
   member của **mọi** VLAN tag_8021q, nên traffic của một cổng standalone bị nhân sang CPU port thứ
   hai. Sửa đúng là một patch DSA, 1 hàm + 2 helper — xem "Patch DSA: viết, build, nạp, đo". Chưa
   có patch thì workaround là cho cổng standalone vào một bridge VLAN-aware ("Phá trần lần đầu").

Mục này ghi lại cả chuỗi kết luận sai của tôi trên đường tới đó, vì chúng sai lặp cùng một kiểu.

### Sơ đồ thật của board

Bốn cổng RJ45 (3 LAN + 1 WAN) **không** phải bốn card mạng. Cả bốn đều là cổng của một con switch
QCA8337. SoC IPQ5018 có hai MAC, nối vào con switch đó bằng hai đường vật lý khác nhau:

```
              ┌─ port 1 ── LAN1
              ├─ port 2 ── LAN2
              ├─ port 3 ── LAN3
   QCA8337 ───┤
              ├─ port 4 ── WAN (jack)
              │
              ├─ port 0 ──── SGMII 1G ─────────────── GMAC1 = eth1
              └─ port 5 ──── PHY4 ↔ GE PHY (PHY-to-PHY) ── GMAC0 = eth0
```

`port 0` và `port 5` là hai **CPU port**. Trong DSA, MAC của SoC mà frame của một cổng người dùng
đi qua để lên CPU gọi là **conduit** của cổng đó (tên cũ: master). Mỗi cổng RJ45 được gán một
conduit, và gán ở hai chỗ:

- `board.d/02_network` lúc first boot → `ucidef_set_network_device_conduit`, ra `option conduit`
  trong `/etc/config/network`;
- lúc chạy: netlink `IFLA_DSA_CONDUIT` (netifd làm thay).

**Mặc định trong cây này:** cả 4 cổng → `eth1`. `eth0` không ai dùng.

**Cấu hình của máy thứ nhất (và thứ hai):** `lan1-3` → `eth1`, `wan` → **`eth0`**. Trong
`/etc/config/network` là `option conduit 'eth0'` ở device `wan`, và kiểm được bằng
`/sys/class/net/eth0/upper_wan`. Dòng đó do một lần first boot cũ viết ra và **không tự sinh lại**
(xem mục 18), nên nó theo cấu hình qua mọi lần flash giữ config.

### Vì sao eth0 cần patch 714 (nối mục 16)

`port 5` không nối thẳng vào GMAC0: nó đi qua **PHY4 của switch ↔ GE PHY trong SoC**, hai con PHY
nối lưng nhau, không có MAC nào ở giữa. Hệ quả về thời gian:

- DSA bật PHY4 ngay lúc probe (~2,2 s), PHY4 bắt đầu autoneg;
- GE PHY chỉ được khởi tạo khi **eth0 được open** (`stmmac_open` → `phylink_fwnode_phy_connect`);
- nếu sau ~13 s PHY4 không thấy đối tác quảng bá 1000BASE-T, nó **bỏ gigabit** và link không lên.

Nên nếu không ai mở eth0 sớm thì **eth0 không có carrier**, và nó không dùng được làm conduit.
Hook `05_cr8806_eth0_up` (`ip link set eth0 up`) và sau đó patch 714 (DSA tự mở conduit của một
CPU port kiểu PHY-to-PHY, trước `dsa_shared_port_phylink_register()`) đều chỉ làm **một** việc:
mở eth0 đủ sớm. Chúng **không** phải là cái "tách WAN" — việc tách là do `conduit 'eth0'`.

### Thượng nguồn 2026-11-07: tắt hẳn port 5

PR kuncy7/openwrt-nss-edma 63 (merge 09:27 ngày 2026-11-07) mang **3 commit**:

| commit | nội dung |
|---|---|
| `99c4508138` | thêm profile `xiaomi_redmi-ax3000-ubootmod`; tách `ipq5018-cr8806.dts` → `ipq5018-cr880x.dtsi` dùng chung |
| `a67d696c5d` | **`status = "disabled"` cho `ethernet-port@5`** trên toàn bộ CR880x + xoá `05_cr8806_eth0_up` |
| `f3588d3871` | thêm profile mới vào CI group 256m |

Lý do của `a67d696c5d` là issue 66 (Cathgao, đã close): `qca8k_setup()` ghi `GLOBAL_FW_CTRL1` với
destination mask = `dsa_cpu_ports(ds)`, tức **tất cả** CPU port. Có hai CPU port thì mọi frame
unknown-unicast / broadcast / multicast được switch nhân bản sang **cả hai**. Trên máy anh ấy
(cấu hình mặc định: 4 cổng đều ở eth1, eth0 lên link nhờ hook nhưng không mang cổng nào), frame
đến eth0 → `dsa_conduit_find_user()` không tìm được cổng người dùng nào → drop trong softirq:
CPU0 softirq **30-60%** khi iperf3 routed, dmesg đầy `eth0: dropped frame ... src_port=-1`. Tắt
port 5 thì về 0%.

Diff đã kiểm: `ipq5018-cr880x.dtsi` so với `ipq5018-cr8806.dts` cũ **giống từng dòng**, chỉ khác
hai chỗ — bảng `qcom,smem-part` ở lại file board, và `ethernet-port@5` thêm `status = "disabled"`.
Tức với CR8806 **thay đổi chức năng duy nhất là tắt port 5**. Tên profile (`xiaomi_cr8806`),
`board_name`, model string, compatible sysupgrade, tên file ảnh: **không đổi gì**. "cr880x" chỉ là
tên file DTS dùng chung.

### Hệ quả cho cây này

- `eth0` **không còn là conduit**: `qca8k` chỉ đăng ký port 0. Dòng `option conduit 'eth0'` ở
  device `wan` thành vô nghĩa — kernel từ chối, `wan` rơi về conduit mặc định `eth1`. Nên dọn.
- Override `nss.general.fw_mask=0x3` (mục 18) **hết cần**: eth0 không mang cổng nào nữa, giá trị
  dẫn xuất đúng là `0x2`. Bug `nss_dsa_fw_mask()` bỏ sót GMAC mang cổng WAN **vẫn là bug** cho
  AX5400 / PZ-L8 (board.d của chúng đặt wan ở eth0), chỉ là CR880x không còn chạm vào nó.
- Patch 714 vẫn apply sạch nhưng **thành no-op trên CR880x**: không còn CPU port PHY-to-PHY nào
  để mở. Nó vẫn đúng và vẫn cần cho upstream — AX5400 và PZ-L8 có wan ở eth0 từ board.d nên
  **không** tắt được port 5 ở đó. Nhưng board duy nhất trong cây này minh hoạ được vấn đề thì nay
  không minh hoạ nữa; nếu reviewer PR 26511 hỏi "sao không tắt port đi cho xong" thì đó là câu
  trả lời.
- Commit `qualcommax: ipq50xx: drop the CR8806 eth0-up preinit hook` của mình bị git **drop khi
  rebase** ("patch contents already upstream") — thượng nguồn đã xoá đúng file đó.

### Đo: cái giá của một CPU port thứ hai

Lý do duy nhất đáng cân nhắc khi tách conduit là thông lượng **routed** (LAN ↔ WAN, phải lên CPU
vì khác L3 domain; traffic bridged trong LAN thì switch tự chuyển, không lên CPU). Nên phải đo
routed, và trước ngày 2026-11-07 **chưa bao giờ đo** — xem "Vì sao mấy tuần không thấy" ở dưới.

**Cách đo.** Cùng một sợi cáp, cùng cổng, cùng vị trí. Đường đo toàn bộ là dây: laptop (card
Ethernet) → jack WAN → Home1 routed+NAT → cổng lan → router chính → một host gigabit có dây làm
iperf3 server (đường sau Home1 là switch cứng toàn tuyến). 20 s, 4 luồng, `iperf3.exe` chạy
**trên Windows** với `-B <địa chỉ card Ethernet>` — iperf3 trong WSL không ép được route vì WSL
nằm sau NAT của Windows; có `-B` thì không cần tắt Wi-Fi. Phép NAT dùng một zone riêng cho cổng
WAN + masq ở zone lan. Mỗi phép đo tự đọc **trong lúc chạy**: `/sys/class/net/wan/speed`,
`ls /sys/class/net/eth*/upper_*` (conduit của từng cổng), `ethtool -S eth0|eth1` (MMC), `/proc/stat`
(softirq), và `accelerated_count` của ECM.

Hai đợt đo, khác nhau ở một chỗ quan trọng:

- **Đợt 1 (2026-11-07 tối), nhánh `port5-ab`** = `main` + một commit `TEST:` xoá dòng
  `status = "disabled"`. Đổi `fw_mask` bằng cách **ghi debugfs lúc đang chạy**.
- **Đợt 2 (2026-11-08 khuya), nhánh `port5-2conduit`** = `main` + bật port 5 + lấy lại patch 714 +
  `CONFIG_PACKAGE_ip-bridge=y`. Đổi `fw_mask` bằng **uci + reboot**.

Khác biệt ấy hoá ra quyết định: **ghi `fw_mask` lúc đang chạy không arm nổi một GMAC mới** (xem
dưới), nên mọi dòng `0x3` của đợt 1 **chưa bao giờ thật sự là hai conduit**. Bảng dưới là đợt 2,
và nó là bảng duy nhất đáng tin.

| # | port 5 | eth0 | `fw_mask` | conduit `wan` | up / down / bidir (Mbit/s) | softirq cpu0/cpu1 | eth0 MMC RX |
|---|---|---|---|---|---|---|---|
| 1 | **tắt** (`a67d696c5d`) | — | 0x2 | eth1 | **932** / 920 / 859+71 | 0,3% / 1,8% | — |
| 2 | bật | up, `idle` | 0x2 | eth1 | **723** / — / — | **98,3%** / 3,3% | **1.675.825 fr** |
| 3 | bật | up, `idle` | 0x2 | **eth0** | 80 / — / — | 93,5% / 53,1% | 192.424 |
| 4 | bật | **`started`** | **0x3** | **eth0** | 111 / 211 / 113 | 95,9% / 60,8% | 192.928 |
| 5 | bật | **`started`** | **0x3** | eth1 | 95 / 209 / 104 | 97,0% / 97,8% | 417.786 |

**Phép A/B sạch nhất là dòng 1 so dòng 2.** Khác đúng **một** biến — port 5 bật trong DTS. Cấu
hình phía trên y nguyên: bốn cổng đều trên eth1 (`eth1 upper: lan1 lan2 lan3 wan`, `eth0 upper:`
rỗng), `fw_mask=0x2`, eth0 **không được arm** (`phys_if 0: idle dev=eth0 (not in fw_mask)`). Kết
quả: **932 → 723 Mbit/s**, softirq cpu0 **0,3% → 98,3%**.

Và eth0 — không mang cổng nào, không được arm — **nhận một bản sao gần như nguyên vẹn của chiều
ingress**:

```
eth0 MMC RX  1.675.825 frame  (82.009 pps)   TX 0
eth1 MMC RX  1.676.403 frame                  ← lệch 0,03%
```

**Frame đó đi đâu: 1,25 triệu frame mất mà không counter nào đếm.** Trong cùng cấu hình, đọc song
song counter phần cứng và counter netdev của eth0:

```
eth0 MMC RX   1.689.405 frame     ← phần cứng MAC nhận
eth0 netdev     444.197 packet    ← stack chỉ lấy lên được ~1/4
rx_dropped 0   rx_errors 0   mmc_rx_fifo_overflow 0   mmc_rx_crc_error 0
```

Đúng chữ *"millions of dropped frames"* trong commit message của Cathgao, và đúng cả bậc độ lớn
*"up to 50% CPU softirq"* — ở đây là 98,3% của một core trên hai core.

**Đối chứng quyết định: routed so với kết thúc trên router.** Cùng máy, cùng cấu hình dòng 2, chỉ
đổi **loại** traffic:

| traffic | eth1 MMC RX | eth0 MMC RX |
|---|---|---|
| routed (laptop ở jack WAN → host sau router chính), 20 s | 1.676.403 fr | **1.675.825 fr** |
| kết thúc **trên** router (dropbear sink, ingress lan2, ~600 Mbit/s), 30 s | +414.542 fr | **+0 fr** |

Biến quyết định **không** phải "eth0 có mang cổng hay không", và cũng không hẳn là "routed so với
terminated" như tôi viết lúc đầu: đó là **frame đi qua conduit trong VLAN nào**. Luồng routed trong
rig này đi qua cổng `wan`, một cổng standalone, nên frame của nó qua conduit trong VID 3076 của
tag_8021q; luồng terminated đi qua `br-lan`, một bridge VLAN-aware, nên frame của nó mang VID
6/7/68 của chính bridge. DSA cấp hai loại VLAN đó cho **hai tập CPU port khác nhau** — và đó là
toàn bộ cơ chế.

### Cơ chế, đọc thẳng từ thanh ghi (2026-11-08)

Đọc được **không cần patch, không cần build, không cần reboot**. `qca8k` không có debugfs riêng,
nhưng nó dùng regmap, và kernel này có `CONFIG_DEBUG_FS=y` + `CONFIG_REGMAP=y`, nên regmap tự tạo
`/sys/kernel/debug/regmap/90000.mdio-1:11/registers`: toàn bộ không gian thanh ghi của QCA8337,
`cat` ra được. (`90000.mdio-1:11` = bus MDIO, địa chỉ 0x11 = 17 = con switch.) Chỉ đọc phần dưới
0x1000 — từ 0x1000 lên là MIB, và đó là chính mấy counter đang dùng để đo. `head -c 4096` là đủ
tới 0x718.

| thanh ghi | giá trị | nghĩa |
|---|---|---|
| `GLOBAL_FW_CTRL1` 0x624 | `3f3f3f3f` | đích flood UC/MC/BC/IGMP đều `0x3f` = cổng 0..5, **có port 5** |
| `PORT_LOOKUP_CTRL(0)` 0x660 | `0004031e` | member `0x1e` = {1,2,3,4}; STATE=FORWARD; LEARN=0 |
| `PORT_LOOKUP_CTRL(2)` 0x678 | `0014030b` | member {0,1,3}; STATE=FORWARD; **LEARN=1** (`lan2`, cổng bridge) |
| `PORT_LOOKUP_CTRL(4)` 0x690 | `00040301` | member {0}; STATE=FORWARD; **LEARN=0** (`wan`, standalone) |
| `PORT_LOOKUP_CTRL(5)` 0x69c | `00040300` | member **rỗng**; STATE=FORWARD; LEARN=0 (port 5) |

Bố cục bit: `MEMBER` = GENMASK(6,0), `VLAN_MODE` = (9,8) (ở đây `3` = SECURE), `STATE` = (18,16),
`LEARN` = BIT(20) — `qca8k.h:266`.

Hai điều đọc ra ngay: port 5 **có** nằm trong đích flood, đúng như `a67d696c5d` nói; nhưng port 5
**không** nằm trong member mask của bất kỳ cổng nào, kể cả của CPU port 0. Nên member mask một
mình **không** giải thích được 1,68 triệu frame mà eth0 đã nhận.

`0x3f` ở cả bốn trường là do `qca8k_setup()` ghi `dsa_cpu_ports(ds)` (`qca8k-8xxx.c:2476`), rồi
`qca8k_write_flood_masks()` (`qca8k-common.c:724`) OR thêm user port vào khi tagger là 8021q. Chỗ
ghi `dsa_cpu_ports(ds)` đến từ patch `711-02-net-dsa-qca8k-enable-flooding-to-both-CPU-port.patch`
(Christian Marangi, *"To permit a multi-CPU setup"*), và **đã kiểm xong nguồn gốc**: đó là patch
**generic pending của chính OpenWrt**, nằm trong `target/linux/generic/pending-*` từ 6.1, do các
commit bump kernel của OpenWrt mang theo (`8a9273d51e` Weijie Gao, `480537ed36`, `b70d9a15af`
Mieczyslaw Nalewaj). **Không** phải thứ riêng của cây NSS — lần trước tôi kết luận ngược vì
`9716066e80` (Rosen Penev, cây NSS) có chạm file này, nhưng đó là `M`, không phải `A`. Nên mọi
target OpenWrt có hai CPU port bật trong DT đều ở trong tình trạng này.

Patch ấy ghi kèm một điều kiện: *"Each CPU port should have correct LOOKUP MEMBER configuration to
prevent receiving duplicate packets from user ports"*. Điều kiện đó **đang được thoả** — member
mask không chỗ nào có port 5 — mà frame vẫn bị nhân. Tức điều kiện ấy chưa đủ, vì đường vào là
VLAN chứ không phải member mask.

Hai phép đối chứng tại chỗ, không cần rig, trên đúng cấu hình đã đo 723 Mbit/s:

- 20 s LAN nhà bình thường: eth1 MMC RX **+137** frame (broadcast/multicast của nhà), eth0 **+0**.
- 50 frame unknown unicast do chính router phát vào `br-lan.68` (`ip neigh` trỏ tới một MAC không
  ai sở hữu, rồi ping): eth1 MMC TX tăng, eth0 **+0**.

### Phép thử ba chân, chứng minh trực tiếp (2026-11-08, cáp WAN đã cắm)

Không cần iperf3, không cần build mới. Cách bơm: `ip neigh` trỏ một IP tới **một MAC không ai sở
hữu**, rồi `ping -c 20 -s 60000` — mỗi echo request phân mảnh thành ~41 frame nên 20 ping cho ~820
frame unknown unicast, phát trong ~20 s. Frame đi từ CPU port 0 ra, đúng chiều mà luồng routed
đi ra `wan`. Ba chân chạy cách nhau vài giây trên cùng một máy, cùng một đích MAC, chỉ khác **một**
biến: VLAN mà frame mang khi qua conduit.

| chân | cổng egress | VLAN qua conduit | frame ra eth1 (TX) | **eth0 nhận (RX)** |
|---|---|---|---|---|
| **A** | `wan`, standalone | **VID 3076** (tag_8021q) | +917 | **+825** |
| **B** | cổng trong bridge VLAN-aware | VID của bridge | +920 | +4 (nhiễu nền) |
| **C** | `wan`, **đã cho vào bridge VLAN-aware** | **VID 1** (VID của bridge) | +924 | **+0** |

Chân C là phép thử quyết định: cho `wan` vào một bridge có `vlan_filtering 1` lúc đang chạy
(`ip link add brwt type bridge vlan_filtering 1`, `ip link set wan master brwt`). Node của
`qca-dsa-nss` đổi từ `vid=3076` sang **`vid=1`** ngay, `GLOBAL_FW_CTRL1` vẫn `3f3f3f3f`, member
mask của port 0 vẫn `0x1e` (vẫn không có port 5) — **không một mask nào đổi**, chỉ VLAN đổi, và
eth0 từ +825 xuống **+0**. Đích vẫn là một MAC không ai sở hữu nên frame ở chân C **vẫn là unknown
unicast**: biến duy nhất bị đổi là VLAN.

Một hiệu ứng phụ đọc được ở chân C: `PORT_LOOKUP_CTRL(4)` đổi `00040301` → `00140301`, tức
**LEARN bật** khi cổng vào bridge. Với traffic thật (MAC đầu xa có tồn tại) thì đó là **lý do thứ
hai** để flood tắt — MAC đầu xa vào được ATU nên frame thành known unicast. Hai cơ chế, cùng một
thay đổi chữa cả hai.

### Xác nhận lại bằng traffic routed thật (2026-11-08, 3 lượt iperf3)

Rig: laptop ở jack WAN (cổng `wan`, standalone) là iperf3 client, `iperf3 -s` trên một host ở LAN,
`-t 20 -P 4`, hướng wan → lan. Sampler 1 giây/mẫu; window 20 s bận nhất trong 180 mẫu:

| | |
|---|---|
| eth1 MMC RX | +1.677.515 frame |
| eth1 MMC TX | +2.219.016 frame |
| **eth0 MMC RX** | **+1.687.067 frame** (eth0 TX = 0) |
| lệch eth0 / eth1 RX | **+0,569%** |
| softirq cpu0 | **91,0%** (cpu1 3,6%) |
| ECM accelerated trong lúc chạy | **5** (lấy mẫu 4 lần trong window, đều 5) |
| iperf3 báo | 610–690 Mbit/s tổng, phân bố 4 luồng rất lệch (320/172/59/139) |

Khớp theo từng giây, không chỉ theo tổng: eth1 RX 88.264 / eth0 RX 88.035; 91.036 / 92.117;
94.536 / 93.409; 81.612 / 82.387. Và lúc rỗi thì eth0 **đứng yên hoàn toàn** trong khi eth1 vẫn
nhúc nhích — đối chứng nằm ngay trong cùng một file mẫu.

Thanh ghi đọc ở giây 20 và giây 40 **giữa lúc tải chạy**, không đổi một bit so với lúc rỗi:

```
0624: 3f3f3f3f   0660: 0004031e   0678: 0014030b   0690: 00040301   069c: 00040300
```

Đó là câu trả lời cho việc "so mask giữa cảnh terminated và cảnh routed": **mask không đổi**. Tải
không lập trình lại gì cả — nên khác biệt phải nằm ở lookup của từng frame, và nó nằm ở VLAN.

Hai điều đáng ghi thêm từ lượt này:

- **ECM vẫn accelerate bình thường** (5 connection) với `fw_mask=0x2` và port 5 bật. Tức flood
  **không** làm sập offload; cái làm sập offload là `fw_mask=0x3` (mục trên). Hai bệnh khác nhau.
- **eth1 TX nhiều hơn eth1 RX 541.501 frame.** Với một luồng routed qua cùng một conduit thì RX và
  TX lẽ ra bằng nhau (mỗi frame vào một lần, ra một lần). Phần dư xấp xỉ bằng số frame ACK, và
  cũng xấp xỉ phần bản sao mà stack lấy lên được từ eth0 (lượt trước: MMC 1,69 triệu so với netdev
  444 nghìn, ~26%). **Chưa giải thích được** — giả thuyết chưa kiểm là stack nhận bản sao trên
  eth0 rồi **forward nó lần thứ hai**. Cách chốt rẻ: lấy mẫu `/sys/class/net/eth0/statistics/rx_packets`
  song song và xem nó có khớp phần dư TX hay không.

**Nên đây vừa là chứng minh vừa là workaround**: board nào không tắt được CPU port thứ hai thì cho
cổng standalone vào một bridge VLAN-aware là hết bị nhân. Con số còn thiếu lúc này — throughput
routed có quay về ~932 hay không — đo được ngay sau đó: **có**. Qua workaround bridge thì một chiều
890 Mbit/s (cổng WAN 1G là cổ chai), và với patch DSA thì 933 so với 932 của `main`. Lưu ý phải làm
bằng uci chứ không phải `ip link` thủ công, vì firewall/NAT của netifd gắn theo device của
interface.

Vậy ở trạng thái rỗi không có gì rỉ sang port 5. Khác biệt duy nhất của cảnh routed là **VLAN**:

| frame của cổng | VLAN khi qua conduit | member là ai |
|---|---|---|
| trong bridge VLAN-aware (`lan1..3`) | VID của bridge (6, 7, 68) | cổng đó + **đúng một** CPU port |
| standalone, hoặc bridge VLAN-unaware (`wan`) | VID tag_8021q (3076) | cổng đó + **mọi** CPU port |

Dòng thứ hai là chỗ hỏng, và nó nằm trong **DSA**, không nằm trong `qca8k`:

```c
/* net/dsa/tag_8021q.c:211 */
static bool dsa_port_tag_8021q_vlan_match(struct dsa_port *dp,
			      struct dsa_notifier_tag_8021q_vlan_info *info)
{
	return dsa_port_is_dsa(dp) || dsa_port_is_cpu(dp) || dp == info->dp;
}
```

`dsa_port_is_cpu(dp)`: **mọi** CPU port là member của **mọi** VLAN tag_8021q. VLAN của bridge đi
đường khác — `dsa_port_host_vlan_match()`, `net/dsa/switch.c:662`, có comment ngay trên đầu:
*"Host VLANs match on the targeted port's CPU port"* — đúng một CPU port, là `dp->cpu_dp`.

`/sys/kernel/debug/qca-dsa-nss/status` trên máy đang chạy xác nhận hai tập VID đó tồn tại thật:

```
lan1   if_num=32 vid=68   phys_if=1
wan    if_num=37 vid=3076 phys_if=1
```

Ghép thành chuỗi nhân quả:

1. `wan` là cổng standalone ⇒ frame của nó qua conduit trong VID 3076.
2. VID 3076 có **cả hai** CPU port là member (`dsa_port_tag_8021q_vlan_match`).
3. `wan` standalone ⇒ DSA không bật learning trên port 4 (**đo được**: LEARN=0) ⇒ MAC của máy đầu
   xa không bao giờ vào ATU ⇒ mọi frame router đẩy ra `wan` là **unknown unicast**.
4. ⇒ frame bị flood theo `GLOBAL_FW_CTRL1` = `0x3f`, trong một VLAN mà port 5 là member ⇒ **eth0
   nhận một bản sao của từng frame**. Đó là flood mà `a67d696c5d` mô tả, chỉ là lý do port 5 lọt
   vào tập đích là VLAN tag_8021q chứ không phải member mask.
5. Traffic terminated của phép đối chứng cũ đi qua `br-lan`, VID 68, mà VID 68 chỉ có CPU port 0
   là member ⇒ eth0 nhận 0. **Phép đối chứng cũ ra 0 vì sai VLAN, không phải vì LOOKUP_MEMBER
   lọc.** Nó khác cảnh routed ở hai biến cùng lúc, nên không chứng minh được gì.

Con số khớp cả về lượng: eth0 RX 1.675.825 ≈ eth1 RX 1.676.403 ≈ eth1 TX, tức eth0 nhận bản sao
của **cả hai chiều** qua `wan`, không chỉ chiều đi. Chiều về (máy đầu xa → MAC của `wan`) lẽ ra là
known unicast vì host FDB của `wan` được cài trên đúng một CPU port
(`dsa_port_host_address_match`, `net/dsa/switch.c:132`) — **suy đoán** là entry đó mang `vid` 0
nên lookup của frame mang VID 3076 không khớp (ATU chạy IVL) và cũng miss, cũng flood. Chưa đọc
ATU/VTU để chốt.

**Hệ quả rộng hơn board này:** đây là hành vi của DSA + tag_8021q, không riêng QCA8337. Switch nào
có hai CPU port và dùng tagger 8021q thì traffic của cổng standalone đều bị nhân sang CPU port thứ
hai khi CPU port ấy đang bật. Board nào **không tắt được** CPU port thứ hai thì đang trả giá này
mà không ai nhìn (pz-l8, redmi-ax5400 — xem mục PR 26511).

**Còn lại ở mức thanh ghi** (hành vi thì đã chứng minh bằng phép thử ba chân ở trên):

- **Đọc VTU entry của VID 3076** để thấy port 5 trong egress set. VTU phải **ghi** thanh ghi mới
  đọc được (ghi `VTU_FUNC1` ra lệnh đọc rồi đọc `VTU_FUNC0`), mà `registers` của regmap mở chế độ
  0400. Mở bằng một patch hai dòng: `#define REGMAP_ALLOW_WRITE_DEBUGFS` trong
  `drivers/base/regmap/regmap-debugfs.c` (`regmap-debugfs.c:605` kiểm đúng macro đó) → `registers`
  thành 0600, đọc/ghi mọi thanh ghi switch từ userspace. Mạnh hơn patch `pr_info` nhiều: sau đó
  thử được cả cách chặn — xoá port 5 khỏi `UC_DP_MASK` lúc đang chạy rồi đo lại.
- **Bắt gói trên eth0** trong lúc có luồng routed (`tcpdump -i eth0 -e -n -c 20`) để đọc VLAN tag
  trên chính frame bị nhân. Máy test chưa có `tcpdump`.

Phép thử hành vi tương đương — cho `wan` vào bridge VLAN-aware — **đã làm, xem chân C ở trên**.
Còn thiếu đúng một con số: throughput routed trong trạng thái đó.

**Ép hai conduit cần reboot: ghi `fw_mask` lúc đang chạy không arm được GMAC mới.** Đã kiểm trong
`qca_dwmac_nss.c` và xác nhận bằng đo. Thang trạng thái của glue là
`IDLE → ARMED → OVERRIDDEN → STARTED`:

- `dwmac_nss_fw_arm()` (≈`:890`, chỗ `fw_mask` ghi vào) chỉ đặt `port->state = DWMAC_NSS_PORT_ARMED`;
- `OVERRIDDEN` do **qca-nss-drv** đặt khi nó gọi `nss_dp_override_data_plane()` (`:670`) trong vòng
  khởi tạo của **chính nó** — không có cửa nào gọi lại sau đó;
- `dwmac_nss_port_start_on_link()` (`:557`) là đường duy nhất tới `STARTED`, và **cả ba** chỗ gọi
  (`nss_dp_start_data_plane()`, `NETDEV_UP`, `NETDEV_CHANGE`) đều gate `state == OVERRIDDEN`.

Nên arm sau khi hệ đã chạy thì cổng đứng ở `armed / fw_link=down / link_changes=0` vĩnh viễn.
`stop_service()` trong `nss-dwmac.init` nói thẳng điều đối xứng: *"The NSS plane cannot be detached
at runtime; reboot to return to the host stack."* Hệ quả cho bản ghi cũ: **hai dòng `fw_mask=0x3`
của đợt 1 (85-87 và 106 Mbit/s) đo một eth0 nửa vời, không phải hai conduit** — và đó là lời giải
thích cho cả cụm "số liệu mồ côi" mà bản ghi trước để ngỏ. Muốn hai conduit thật thì
`uci set nss.general.fw_mask='0x3'` + `uci commit` + **reboot**.

**Đổi conduit thì ngược lại: có hiệu lực ngay lúc chạy.** `uci set network.@device[N].conduit` +
`uci commit` + `/etc/init.d/network reload` dời `upper_wan` giữa eth0 và eth1 được, cả hai chiều,
và `qca-dsa-nss` bỏ node VLAN cũ rồi cấp node mới trên `phys_if` đúng (nó `pr_info` từng node:
`wan: vlan node if_num 33 vid 3076 on phys_if 0`). Không cần reboot, không cần dựng lại interface.
Giả thuyết cũ "lệnh đổi conduit chưa thật sự áp" là **sai**; thủ phạm thật của cụm số liệu mồ côi
là `fw_mask` ghi lúc chạy, như trên.

**Hai conduit thật, và nó không chạy (dòng 4 và 5).** Sau reboot với `fw_mask=0x3` trong uci, cả
hai GMAC lên `started` từ đầu (`phys_if 0: started dev=eth0 fw_link=up`) và `qca-dsa-nss` cấp node
VLAN đầy đủ cho cổng ở cả hai conduit. Vậy mà thông lượng là **~100 Mbit/s**, và — quan trọng —
**bằng nhau dù cổng có tách qua hai conduit (dòng 4) hay dồn cả bốn về eth1 (dòng 5)**. Tức cái
làm hỏng là `fw_mask=0x3` / port 5 bật, **không** phải việc tách conduit.

ECM cho thấy nó có thử mà không cài được rule nào:

```
accel_cmd_avg_millis   samples=37    ← đã thử 37 lần
tcp_accelerated_count  0
udp_accelerated_count  0
src_mismatch_fail_count   18
src_mismatch_flush_count  61
```

`tx_busy` trên `phys_if 0` lên tới 403.449 — hệ quả của 96% softirq host-path, không phải nguyên
nhân. Vì sao ECM không accelerate được khi hai GMAC cùng `started`: **chưa biết**.

**Kết luận cho `a67d696c5d`: đúng, cả thay đổi lẫn cơ chế.** Giá đo được của việc bật port 5, với
mọi thứ khác y nguyên, là **209 Mbit/s (932 → 723) cộng trọn một core**. Cơ chế là đúng cái commit
message nói: switch nhân frame routed sang GMAC0 và dìm eth0 trong softirq. Không có cấu hình nào
trong đợt 2 lấy lại được 932 trong khi port 5 còn bật.

**Kết luận cho mục tiêu "hai conduit để có ~1860":** không đạt trên board này, vì **hai** lý do
độc lập — (a) `fw_mask=0x3` không accelerate được, (b) điều kiện tiên quyết là bật port 5, mà việc
đó tự nó đã mất 23% và một core. Ngay cả khi (a) được sửa thì điểm khởi đầu đã là 723 chứ không
phải 932.

**Trần của một conduit: ~930 Mbit/s routed, bất kể hướng.** Đo trên `main` (port 5 tắt, bốn cổng
trên eth1) — đây là dòng 1 của bảng, mở rộng:

| lượt | iperf3 (app) | conduit eth1 RX | conduit eth1 TX | pps mỗi chiều |
|---|---|---|---|---|
| uplink | **932** Mbit/s | **958** | **958** | 85.707 / 85.692 |
| downlink | **920** | **953** | **952** | 94.363 / 94.362 |
| hai chiều (`--bidir`) | 859 + 71 = **930** | **957** | **957** | 87.289 / 87.251 |

Cả ba lượt, eth1 bị ghim ở **~955 Mbit/s ở cả hai chiều cùng lúc** — line rate của link 1G full
duplex, hết chỗ. Và frame RX ≡ frame TX: 1.780.311 so với 1.779.535 ở lượt hai chiều, lệch
**0,04%**. Mỗi frame routed qua conduit **đúng hai lần** (một RX, một TX), đo được, không suy luận.
Nên một chiều được 932, mà hai chiều cũng chỉ 930 **tổng**.

Hai điều phải ghi kèm:

- Lượt hai chiều chia **859 / 71**, lệch khủng khiếp: `--bidir` với 4 luồng mỗi chiều bỏ đói chiều
  ngược. Cái bị chặn là **tổng**, không phải 470/470. Muốn chia đều hơn thì chạy hai instance
  iperf3 độc lập.
- Nhiều host cùng upload vẫn cộng vào **cả** RX và TX, nên tổng vẫn ≤930 dù một hay mười máy.
  Lợi ích duy nhất mà hai conduit *có thể* mua là routing full-rate đồng thời cả hai chiều — và
  theo đợt 2 thì board này không mua được.

**Công cụ đo: MMC counter của stmmac.** `ethtool -S eth1` đọc counter **phần cứng MAC**, độc lập
với DMA ring mà firmware chiếm, nên **vẫn chạy** khi `/sys/class/net/eth1/statistics/*` đóng băng.
Đây là thứ duy nhất tìm được đo được tải conduit trong lúc NSS nắm GMAC — và như phần "1,25 triệu
frame" ở trên, nó còn thấy được cả frame mà netdev không bao giờ thấy. Hai cái bẫy:
`mmc_*_octetcount_gb` là **32-bit**, wrap ở 4,29 GB và cho delta **âm** (phải cộng lại 2³², hoặc
dùng `framecount`); và thứ tự field trong `ethtool -S` là thứ tự **file**, không phải thứ tự regex
đưa vào, nên phải parse theo tên.

Ba đồng hồ khác, và chúng đo cái gì:

| đồng hồ | đo gì | dùng được không |
|---|---|---|
| `ethtool -S ethN` (MMC) | frame/byte ở **phần cứng MAC**, sống dưới NSS | **có** — thước đo tải conduit duy nhất |
| `/sys/class/net/ethN/statistics/*` | netdev, **đóng băng** khi firmware giữ ring | không, cho conduit; DSA user port (`wan`, `lan2`) thì vẫn chạy |
| `qca-dwmac-nss/status` `rx_fw`/`tx_redirect` | **chỉ** gói đi lên Linux | không đo tải; nhưng là máy báo "offload vỡ" rất tốt (nhảy +256k khi vỡ, +114 khi lành) |
| `ecm_nss_ipv4/accelerated_count` | **gauge** số connection đang accelerate (=5 với iperf3 4 luồng) | có, nhưng phải lấy mẫu **trong** lúc chạy |

**Phụ: patch 714 đã tự đứng một mình.** Bản hai-conduit là lần đầu patch 714 phải làm việc mà
**không** còn hook `05_cr8806_eth0_up` trong tree (thượng nguồn đã xoá). eth0 vẫn lên **1000Mb/s
Full**, timing trong dmesg khớp mục 16: GE PHY attach `2.125s` → PHY4 `2.223s` → `eth0: Link is Up
- 1Gbps/Full` ở `4.636s`. Nhưng xem "Việc đã làm" ở dưới: patch đó đã bị gỡ khỏi `main`.

### Vì sao mấy tuần không thấy

Cấu hình `wan` → `eth0` đã chạy trên máy này nhiều tuần, qua nhiều lần build và soak, mà không
lần nào lộ ra. Bốn lý do xếp lên nhau:

1. **Chưa bao giờ đo routed.** Mọi phép đo trước đó là một trong hai loại: (a) traffic bridged
   Wi-Fi ↔ LAN, switch tự chuyển trong hardware, không lên CPU port nào; (b) iperf3 **kết thúc
   trên router**. Loại (b) có cả lần cắm laptop vào jack WAN ở mục 16 — 378 Mbit/s 1 luồng,
   466 Mbit/s 4 luồng, 233 chiều ngược. Số đó **đã là** triệu chứng, nhưng không phân biệt được
   với bình thường: traffic kết thúc trên router vốn **không** được offload, nên bị CPU giới hạn
   là điều phải xảy ra, và lúc đó đã giải thích đúng theo nghĩa đó. Thiếu là đường **đi xuyên** —
   mà đường đó trước 2026-11-07 **không tồn tại**: mạng của cổng WAN chưa có masquerade cũng chưa
   có forwarding sang lan. Không có đường routed thì không có đường cơ sở 932 để thấy 723 là bệnh.
2. **Counter của conduit dưới NSS vô dụng.** Với `fw_mask=0x3`, NSS giữ DMA ring nên
   `/sys/class/net/eth0/statistics/rx_bytes` **đóng băng ở 0** (`eth1 rx` cũng đứng ở 46.751 B
   suốt mọi phép đo). Mọi lần kiểm "eth0 có chở gì không" đều đọc ra 0 — không phải vì nó rỗi mà
   vì cái đồng hồ không chạy. Chỉ khi eth0 rời NSS về host counter mới nói thật.
3. **Vai AP thì cấu hình xấu cũng không đau.** Máy là leaf AP bridge, jack WAN để trống, nên
   **không có luồng routed nào** để `wan` → eth0 làm hỏng. Cái bẫy nằm đó im lìm cho tới lúc có
   người dựng một đường routed qua nó — đúng hôm 2026-11-07.

4. **Cái hộp *có* config lỗi cũng chưa bao giờ bị kích hoạt.** Home2 chạy build cũ (`r38369+5`) với
   `network.@device[4].conduit='eth0'` và `nss.general.fw_mask='0x3'` — đúng cấu hình sinh ra mọi
   con số xấu ở bảng trên, chạy nhiều tuần trong nhà. Đọc `status` của nó 2026-11-08:
   `phys_if 0: started dev=eth0  tx_redirect=0  rx_fw=0`, và `wan@eth0` **NO-CARRIER** — jack WAN
   của nó **trống suốt**. Nên eth0 ở đó chưa từng chuyển một frame nào. Đây là lý do mạnh nhất:
   không phải "chưa đo đúng", mà là **chưa từng có cáp trong jack WAN của bất kỳ máy nào** có cấu
   hình đó, cho tới 2026-11-07.

Điều **không** phải nguyên nhân: "tại chỉ test qua Wi-Fi". Biến thiếu là **routed so với kết thúc
trên router**, không phải dây so với Wi-Fi.

### Chín suy luận đã sai, ghi lại để khỏi lặp

Cụm này dài vì nó đáng dài: **năm** trong chín cái sai cùng một kiểu — lấy một mệnh đề đọc được
(trong code, hoặc trong một phép đo hẹp) rồi phát biểu nó như một mệnh đề về hành vi chung.

1. **"Tính dung lượng SGMII full-duplex là đủ để kết luận"** — đúng về con số, sai về lúc dùng:
   tính đường truyền như thể data plane là phần mềm thuần, trong khi thứ quyết định ở cấu hình xấu
   là offload. Phần tính chỉ đứng vững **sau khi** đã biết đâu là thủ phạm.
2. **"`dropped frame` = 0 nên không có vấn đề gì ở eth0"** — sai vì chọn sai chỗ nhìn, và vì
   `fw_mask=0x3` làm mọi counter netdev của eth0 đóng băng (lý do 2 ở phần "Vì sao mấy tuần không
   thấy"). Phiên bản mạnh hơn của cùng cái bẫy: ở phép đo flood, `rx_dropped=0`, `rx_errors=0`,
   `mmc_rx_fifo_overflow=0` **trong khi 1,25 triệu frame đang mất**. Counter bằng 0 không chứng
   minh được gì cả.
3. **"RX và TX của SGMII độc lập nên conduit thứ hai không mua được gì"** — sai: một frame routed
   tiêu **một đơn vị RX và một đơn vị TX**, nên hai chiều chia nhau cùng một ngân sách. Đo ra: một
   chiều 932, hai chiều 930 **tổng**, frame RX ≡ frame TX lệch 0,04%.
4. **"`GLOBAL_FW_CTRL1` lấy mọi CPU port nên bản sao rơi vào CPU port rỗi"** — **đây là câu đúng**,
   và tôi đã gạch nó đi để thay bằng "LOOKUP_MEMBER lọc hết" (xem số 7). Phép đo 2026-11-08 trả
   nó về chỗ.
5. **"`fw_mask=0x3` làm sập thông lượng ngang nhau dù cổng có tách conduit hay không, nên phải
   còn một nguyên nhân thứ hai độc lập"** — sai, và sai vì cùng một chỗ: lúc đó **flood vẫn
   đang chạy**, nên cả hai cấu hình đều đo cái flood chứ không đo hai conduit. Chặn flood rồi thì
   `fw_mask=0x3` + tách conduit chạy sạch (933 một chiều, 1104–1458 hai chiều, ECM 9 flow,
   `src_mismatch_fail_count` 0). Không có nguyên nhân thứ hai. Hai dòng 4 và 5 của bảng A/B
   (~100 Mbit/s, ECM không cài được rule nào) là flood cộng một eth0 nửa-arm, không phải một bug
   riêng.
6. **"`rx_fw`/`tx_redirect` đo được tải conduit"** — sai. Tôi đọc hai chỗ tăng counter
   (`qca_dwmac_nss.c:177` trong `dwmac_nss_fw_xmit()` và `:779` trong `nss_dp_receive()`) rồi kết
   luận chúng đếm traffic của conduit. Chúng chỉ đếm **traffic đi lên Linux**: flow được NSS
   accelerate không bao giờ tới hai dòng đó. Đo ra 1.538.421 frame qua conduit trong 20 s trong
   khi `tx_redirect` nhúc nhích **+114**. Biết một counter tăng ở dòng nào **không** cho biết
   traffic nào chạy tới dòng đó — phải kiểm thước đo bằng một tải đã biết trước khi tin nó.
7. **"Một CPU port thứ hai đang up mà không mang user port nào thì không nhận gì cả"** — **sai về
   phạm vi**, và đây là cái sai nặng nhất của cả mục vì nó làm tôi viết lại cả mục này một lần
   theo hướng ngược, kèm một comment DTS và ba bản nháp gửi ra ngoài. Phép đo nền là thật (0 frame
   trên eth0) nhưng nó dùng **traffic kết thúc trên router** và LAN rỗi — **chưa bao giờ là luồng
   routed**. Dưới luồng routed, eth0 nhận bản sao lệch 0,03%. Cathgao đúng ở chỗ nói "routed",
   và tôi đã gạch nó đi; biến thật — đọc ra từ thanh ghi ngày 2026-11-08 — là **frame đi qua
   conduit trong VLAN nào**: VLAN tag_8021q của cổng standalone có mọi CPU port là member, VLAN
   của bridge chỉ có một. "Routed" trong rig này trùng với "qua cổng `wan` standalone", nên nó là
   dấu hiệu đúng dù không phải nguyên nhân. Bài học cụ thể: khi một commit message nói "routed",
   **đừng** đối chứng bằng traffic terminated — phép đối chứng đó lệch hai biến cùng lúc.
8. **"`accel=0` nghĩa là flow không được offload"** — sai, lỗi lấy mẫu:
   `/sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count` là **gauge** số connection *đang* được
   accelerate (bằng 5 khi chạy iperf3 4 luồng), không phải tổng tích luỹ. Tôi lấy mẫu trước và sau
   lượt chạy nên cả hai đều ra 0. Phải lấy mẫu **trong** lúc chạy.

9. **"Hai conduit không mua được gì trên board này"** — kết luận của tối 2026-11-07, viết thẳng
   vào commit message của nhánh test (`TEST: ... two DSA conduits`), và sai trong vòng mười hai
   giờ. Nó dựa trên hai phép đo mà **cả hai** đều bị flood: port 5 bật = 723 Mbit/s, và
   `fw_mask=0x3` = ~100 Mbit/s. Đo cái gì đang hỏng rồi kết luận về cái lẽ ra nó phải làm là cùng
   một kiểu sai với số 7 — phạm vi. Bài học: khi một cấu hình mới đo ra **tệ hơn** cấu hình cũ
   nhiều lần, giả thuyết đầu tiên là "nó đang hỏng", không phải "nó không giúp được gì".

**Sáu cái bẫy khi đo, ghi để khỏi mắc lại.**

1. Đọc `/sys/class/net/wan/speed` **trong** mỗi phép đo. Một lần cáp marginal bắt tay 100M làm cả
   một phép đo thành vô nghĩa, và 94,x Mbit/s trùng đúng line-rate 100BASE-TX nên rất dễ tin lầm.
2. **Ghi lại conduit của từng cổng trong từng phép đo** (`ls /sys/class/net/eth*/upper_*`), và
   **trạng thái `phys_if` của từng GMAC** (`/sys/kernel/debug/qca-dwmac-nss/status`: `idle` /
   `armed` / `started`). Cả đợt đo 1 thành vô giá trị vì thiếu đúng hai dòng log này: không có bản
   ghi conduit, và không ai thấy rằng `fw_mask=0x3` ghi lúc chạy chỉ đưa eth0 tới `armed`.
3. Counter byte của conduit (`/sys/class/net/ethN/statistics/*`) **đóng băng khi NSS giữ ring**.
   Counter MIB của user port (`lan2`) cũng đứng khi NSS giữ eth1 — dùng `br-lan` thay. Nhưng cách
   đúng để đo **tải conduit** là `ethtool -S ethN`, counter MMC trong phần cứng MAC: nó vẫn chạy
   dưới NSS. Xem "Công cụ đo" ở trên, kèm hai cái bẫy wrap 32-bit và thứ tự field.
4. **Không** tính softirq bằng vòng lặp `sleep 2` có `dmesg | grep -c` bên trong: dưới tải 90%
   softirq mỗi vòng mất ~6,7 s thay vì 2 s, cửa sổ sai, phần trăm vô nghĩa. Cách đúng: chụp
   `/proc/stat` trước/sau, lấy `softirq delta / tổng delta` (USER_HZ = 100).
5. `pgrep -c` **đếm cả tiến trình đang STOP**, nên nó không nói được "build đã dừng chưa"; phải
   xem cột STAT của `ps`. Và `start-stop-daemon -S -b` đẩy stdout vào `/dev/null`, redirect bên
   ngoài vô dụng — phải `exec > file 2>&1` ngay trong script được gọi.
6. **`iperf3 --bidir` không cho một mức, nó cho một cái tán.** Cùng một cấu hình, chiều về ra từ
   164 tới 542 Mbit/s giữa các lượt. Nên đo **từng chiều riêng** (ở đây cả hai đều 945/946 Mbit/s =
   tốc độ dây) và chỉ dùng tổng bidir để so A/B cùng rig, đừng trích nó như một con số tuyệt đối.
   Muốn một số tổng thật thì cần nguồn traffic thứ hai: một cổng 2,5G, hoặc hai máy mỗi phía.

**Hai cái bẫy khi đo trên máy đang phục vụ nhà (học đêm 2026-11-07).**

- `fw_mask=0x0` (nhả **cả hai** GMAC cho host) **cắt đường forward của máy**: `br-lan` vẫn nhận
  traffic mà `eth1`/`lan2` đứng im. Mất mạng toàn bộ, phải rút điện. Đừng ghi `0x0`; muốn thấy
  counter của eth0 thì `0x2` là đủ và đã chạy ổn nhiều lần.
- Đổi flag boot sang slot test rồi để đó = đem bản test đặt vào đường đi của cả nhà. Nếu phải
  làm thì **đổi flag về slot tốt ngay sau khi boot**, để mọi lần reboot sau tự về bản tốt; và
  đổi SSID của máy test cho khác nhà (config là **riêng từng slot**, nên đổi ở slot nào chỉ có
  tác dụng ở slot đó).

**Việc đã làm sau phép đo này.**

- Gỡ patch 714 khỏi `main` (`kernel: drop the DSA PHY-to-PHY conduit patch`). Lý do: với port 5
  tắt, trong cây này **không còn CPU port nào** patch áp vào — nó không sửa gì. Grep cả hai cây
  cho thấy có board khác cùng topology (mainline: `imx6q-b450v3/b650v3/b850v3`; OpenWrt
  qualcommax: `ipq8074-rt-ax89x` port@0, `ipq5018-spnmx56`/`cudy-p5`/`redmi-ax5400`/`pz-l8`
  port@5, `ipq5018-ax6000` port@4), **nhưng** các board đó đều có user port cấu hình trên conduit
  ấy nên netifd tự mở — chúng chưa bao giờ cần patch. Nhánh `patch714-netdev-draft-20261106` và
  `dsa-conduit-open` giữ nguyên trong fork, cần thì lấy lại.
- Bỏ hai override thừa trong config Home1: `network.@device[3].conduit='eth0'` và
  `nss.general.fw_mask='0x3'`. Với port 5 đã tắt thì cả hai đều vô nghĩa — kernel không có eth0
  làm conduit nữa, và giá trị dẫn xuất đúng là `0x2`. Xác nhận 2026-11-08: sau reboot vào `main`,
  `fw_mask` tự ra **`0x2`**, đúng như `nss_dsa_fw_mask()` dự kiến.
- Nhánh `no714-hook` (= `port5-ab` + Revert 714 + khôi phục hook) đã build EXIT=0, image ở chỗ
  lưu riêng. **Chưa flash**, và câu hỏi nó sinh ra để trả lời (cách mở eth0 có quan trọng không)
  vẫn chưa có câu trả lời bằng đo.
- Nhánh `port5-2conduit` (`main` + bật port 5 + patch 714 + `ip-bridge`) đã build và **đã nạp
  slot 1**, chạy đợt đo 2. Sau khi đo xong đã dọn uci của slot 1 (xoá `fw_mask`, xoá `conduit`)
  và trả `flag_last_success` / `flag_boot_rootfs` về **0**, nên mọi lần reboot sau tự về slot 0 =
  `main`. Slot 1 sau đó được nạp bản **có patch DSA** và thành **slot chính**: `flag_last_success`
  = `flag_boot_rootfs` = `flag_boot_success` = **1**, `flag_ota_reboot` và cả hai
  `flag_try_sysN_failed` = 0, nên mất điện hay reboot đều về đúng nó. Đường về `main` (slot 0, còn
  nguyên): `fw_setenv flag_last_success 0; fw_setenv flag_boot_rootfs 0; reboot`.
- `ip-bridge` (cho `bridge vlan show`) không có trong `ip-full`; nó là package riêng,
  `package/network/utils/iproute2/Makefile:89`. Đã thêm vào bản test. Lưu ý nó **không** thấy VID
  của firmware (3076) vì tagger của `qca-dsa-nss` ghi thẳng vào VTU, không qua `bridge`.

### Hai câu từng để mở, và câu trả lời

Mục tiêu "hai conduit cho ~1860" đóng ở mức **không đạt như hình dung ban đầu** — không phải vì
conduit, mà vì cổng WAN 1 Gbit là cổ chai (xem "Hai conduit, không bridge" ở dưới). Hai câu cơ chế
còn lại đều trả lời được trong ngày 2026-11-08, và hoá ra là **một** câu:

| # | câu hỏi | câu trả lời |
|---|---|---|
| 1 | Vì sao frame routed bị nhân sang CPU port thứ hai? | DSA cho **mọi** CPU port làm member của **mọi** VLAN tag_8021q (`dsa_port_tag_8021q_vlan_match`), trong khi VLAN của bridge chỉ cấp cho CPU port của chính cổng đó (`dsa_port_host_vlan_match`). Cổng standalone đi trong VID 3076 mà cả hai CPU port đều thuộc, learning tắt nên MAC đầu xa không bao giờ vào ATU → mọi frame routed là unknown-unicast flood. Chứng minh bằng phép thử ba chân, rồi bằng patch. |
| 2 | Vì sao ECM không cài được rule nào khi **cả hai** GMAC `started` (`samples=37`, `tcp_accelerated_count=0`, `src_mismatch_fail_count=18`)? | **Hệ quả của câu 1**: ECM thấy cùng một gói vào hai `phys_if` thì flush. Chặn flood là hết — 9 flow accelerate, `src_mismatch_fail_count` = 0. Hai bệnh hoá ra là một. |

Câu hỏi cũ số 3 — hook `05_cr8806_eth0_up` so với patch 714 có khác gì đo được không — **bỏ**:
thượng nguồn đã xoá hook, và patch 714 tự đứng một mình được (xem "Phụ: patch 714 đã tự đứng một
mình" ở trên). Nhánh `no714-hook` (`ebdb8df625`) chỉ còn giá trị cho PR 26511.

Còn đúng một việc chưa làm, và nó chỉ là xác nhận cuối ở mức thanh ghi: đọc VTU entry của VID 3076
để thấy port 5 trong egress set — xem "Việc còn lại".

### Phá trần lần đầu: hai conduit chạy thật, qua workaround bridge (2026-11-08, sáng)

**Mục tiêu "hai conduit" ĐẠT** — lần đầu, và bằng một workaround mà patch ở phần sau làm cho
không còn cần. Cấu hình: port 5 bật trong DTS, `fw_mask=0x3`, cổng `wan` dùng
conduit `eth0`, ba cổng LAN dùng `eth1`, **và cổng `wan` nằm trong một bridge VLAN-aware** để frame
của nó rời khỏi VLAN tag_8021q. Reboot để `fw_mask` có hiệu lực.

| | 1 conduit (`main`, port 5 tắt) | 1 conduit, port 5 bật (flood) | **2 conduit, flood tắt** |
|---|---|---|---|
| một chiều | 932 | 723 | 890 *(cổng WAN 1G là cổ chai)* |
| **hai chiều, tổng** | **930** | — | **>1100** *(lượt này ra 1552 = 890 + 662, nhưng `iperf3 --bidir` tán rất rộng; số vững là 1104–1458 ở "Hai conduit, không bridge")* |
| softirq cpu0 / cpu1 | 0,3% / 1,8% | **91,0%** / 3,6% | **1,7% / 1,6%** |
| ECM accelerated | ok | 5 | **9** |

Đếm frame trong window 20 s của lượt hai chiều cho thấy đúng hình dạng phải có:

| conduit | RX | TX | tổng |
|---|---|---|---|
| `eth0` (của `wan`) | +1.861.194 | +1.318.910 | 3.180.104 |
| `eth1` (của LAN) | +1.318.980 | +1.860.978 | 3.179.958 |

`eth0 RX ≡ eth1 TX` và `eth1 RX ≡ eth0 TX`, khớp tới **0,01%**. Tức mỗi frame routed qua **đúng
một** conduit cho mỗi chiều, thay vì qua cùng một conduit hai lần — đó chính xác là điều mà mục
tiêu "hai conduit" cần, và là lý do trần đôi lên. Và **không còn bản sao nào**: ở cấu hình cũ
`eth0 RX ≈ eth1 RX` (nhân đôi), giờ `eth0 RX` là data còn `eth1 RX` chỉ là ACK.

Thanh ghi đọc giữa lúc tải chạy, cả ba lần:

```
0624: 3f3f3f3f   0660: 0004030e   0690: 00140320   069c: 00040310
```

`GLOBAL_FW_CTRL1` **không cần đổi** — vẫn `3f3f3f3f`, port 5 vẫn là đích flood. Cái đổi là member
mask theo conduit (`0660`: port 0 ↔ {1,2,3}; `0690`: wan ↔ {5}; `069c`: port 5 ↔ {4}) và **VLAN**:
`qca-dsa-nss` báo `wan if_num=33 vid=1 phys_if=0`, tức VID của bridge trên conduit `eth0`, không
còn VID 3076 nữa.

**Câu 2 ở trên cũng rơi theo:** ECM accelerate 9 flow bình thường với `fw_mask=0x3`. Lần
trước nó ra `tcp_accelerated_count=0` và `src_mismatch_fail_count=18` **vì flood** — cùng một gói
vào NSS qua hai phys_if. Tắt flood là hết `src_mismatch`. Hai bệnh hoá ra là một.

**Cách làm, bằng uci** (netifd và firewall đi theo device của interface, nên không làm bằng
`ip link` thủ công được):

```
# 1. bridge VLAN-aware chứa cổng standalone
uci add network device; uci set network.@device[-1].name='brwan'
uci set network.@device[-1].type='bridge'; uci add_list network.@device[-1].ports='wan'
uci add network bridge-vlan; uci set network.@bridge-vlan[-1].device='brwan'
uci set network.@bridge-vlan[-1].vlan='1'; uci add_list network.@bridge-vlan[-1].ports='wan:u*'
# 2. địa chỉ phải nằm trên device 8021q ở trên bridge, KHÔNG phải trên bridge
uci add network device; uci set network.@device[-1].name='brwan.1'
uci set network.@device[-1].type='8021q'; uci set network.@device[-1].ifname='brwan'
uci set network.@device[-1].vid='1'
uci set network.<Interface>.device='brwan.1'
# 3. chia tải + arm GMAC thứ hai
uci set network.@device[<n>].conduit='eth0'     # section device của cổng wan
uci set nss.general.fw_mask='0x3'               # override, nss-dwmac-up:68
uci commit network; uci commit nss              # rồi reboot
```

Cái bẫy mất nửa giờ: đặt IP thẳng trên `brwan` thì **không ra gói nào** —
`bridge vlan show dev brwan` cho `1` mà **không** `PVID Egress Untagged`, nên traffic do router phát
ra không có PVID và bị rớt ngay trong bridge (`wan` netdev `tx_packets` = 0). Phải đặt IP trên một
device `8021q` ở trên bridge, đúng như `br-lan.68` của máy này vẫn làm.

**Nhưng workaround không phải chỗ nên dừng.** Gốc nằm trong DSA:
`dsa_port_tag_8021q_vlan_match()` (`net/dsa/tag_8021q.c:211`) cho mọi CPU port làm member của mọi
VLAN tag_8021q, trong khi `dsa_port_host_vlan_match()` (`net/dsa/switch.c:662`) chỉ cấp VLAN của
bridge cho `dp->cpu_dp`. Sửa đúng là cho tag_8021q theo cùng quy tắc — xem "Việc còn lại".

### Patch DSA: viết, build, nạp, đo (2026-11-08, chiều)

Workaround không còn cần. Patch `net: dsa: tag_8021q: give a port's VLAN only to its own CPU
port` làm hai việc, và phải làm cả hai:

1. `dsa_port_tag_8021q_vlan_match()` — CPU port chỉ match khi nó **là** `info->dp->cpu_dp`, đúng
   quy tắc `dsa_port_host_vlan_match()` đã dùng cho VLAN của bridge.
2. Hai helper `dsa_tag_8021q_port_{pre,post}_change_conduit()` gọi quanh
   `dsa_port_assign_conduit()` trong `dsa_port_change_conduit()`, cộng nhánh rewind. Thiếu phần
   này thì đổi `conduit` lúc đang chạy sẽ để VLAN lại ở CPU port cũ và cổng mất đường lên — gần
   như chắc chắn đây là lý do DSA cấp VLAN cho **mọi** CPU port ngay từ đầu.

**Chỗ đặt patch.** Lúc đo nó nằm ở `qualcommax/patches-6.18/0959g-...` (nhánh
`dsa-tag8021q-own-cpu-port`), cho chắc là apply sau `0959a-...-unwind-failed-programming.patch`
vốn sửa cùng vùng. Bản gửi đi và bản trên `main` nằm ở
`generic/pending-6.18/784-net-dsa-tag_8021q-give-a-port-s-VLAN-only-to-its-own-CPU-port.patch`, vì
hành vi nằm trong `net/dsa` và mọi target có hai CPU port + tagger 802.1Q đều bị — **mã y hệt bản
đã đo** (diff phần mã: rỗng). Số 784 vì 780 đã có chủ (`780-ARM-kirkwood-...`); đã kiểm `0959a-`
và `779-` vẫn apply `--fuzz=0` ở cả hai thứ tự và không chung file nào với nó.

**Chân A lặp lại, cùng một biến duy nhất là patch.** `wan` standalone, `vid=3076`, port 5 bật, một
conduit — tức đúng cảnh trước đây cho +825:

| | trước patch | **sau patch** |
|---|---|---|
| eth1 TX | +917 | +1046 / +1032 / +1076 |
| **eth0 RX** | **+825** | **+0 / +0 / +0** |

`GLOBAL_FW_CTRL1` vẫn `3f3f3f3f`, `PORT_LOOKUP_CTRL(4)` vẫn `00040301` (LEARN vẫn tắt), VLAN vẫn
3076. **Không một mask nào đổi** — chỉ VTU đổi, và bản sao mất hẳn. Đây là lý do thanh ghi
`PORT_LOOKUP_*` không bao giờ cho thấy được cơ chế: port 4 chạy `VLAN_MODE=3` (secure), nên bảng
quyết định là VTU chứ không phải member mask port-based.

**Cái giá của CPU port thứ hai: hết.** Cùng cấu hình một conduit, port 5 bật, routed+NAT,
`iperf3 -t 20 -P 4`:

| | trước patch | **sau patch** | `main` (port 5 tắt) |
|---|---|---|---|
| throughput | 723 | **933** | 932 |
| eth0 RX (bản sao) | +1.687.067 ≡ ingress | **0 suốt cả lượt** | 0 |
| softirq cpu0 | 91,0% | **~2,0%** | 0,3% |

Tức `a67d696c5d` tắt port 5 là đúng **với kernel chưa patch**. Có patch rồi thì bật port 5 không
còn mất gì — và đó mới là chỗ nên sửa.

### Hai conduit, không bridge: trần 929 bị phá, lặp được

Chỉ cần `conduit='eth0'` cho device `wan` + `nss.general.fw_mask='0x3'`. **Không `brwan`, không
`brwan.1`, không cái bẫy PVID** — `wan@eth0` đứng một mình với IP tĩnh, ARP tới ngay.

A/B so le, ba lượt mỗi bên, cùng một kernel, chỉ đổi `conduit` của `wan` (`network reload`, không
reboot — và chính việc này chạy được là phần 2 của patch tự chứng minh):

| lượt | 1 conduit | 2 conduit |
|---|---|---|
| 1 | 927 | **1202** |
| 2 | 928 | **1458** |
| 3 | 929 | **1104** |

Một conduit là một cái trần **cứng**: 927–929, ba lượt lệch 2 Mbit/s. Hai conduit luôn vượt, nhưng
tán rộng 1104–1458 — và chỗ tán đó là **máy đo**, không phải router. Đọc thêm bằng MMC octet
counter trong một lượt bidir (lưu ý `ethtool -S` in **tx trước rx**, xếp sai cột một lần rồi):

| | eth0 (conduit của `wan`) | eth1 (conduit của LAN) |
|---|---|---|
| RX | **1050** Mbit/s (từ laptop) | 430 |
| TX | 430 (ra laptop) | **1056** (ra máy phía LAN) |
| tổng trên conduit | **1480** | 1486 |

`eth0 RX ≡ eth1 TX` và `eth1 RX ≡ eth0 TX`: mỗi frame qua **đúng một** conduit mỗi chiều. Và
`eth0 RX = 1050 Mbit/s` mức dây tức **cổng WAN 1 Gbit đã bão hoà** — conduit đang gánh 1,48 Gbit/s
và còn xa giới hạn. Nút cổ chai đã dời từ conduit sang cổng vật lý.

**Vì sao con số tổng không đáng tin, và 1552 lúc trước nên đọc thế nào.** Rig chỉ có **một** card
1 GbE ở cổng WAN và **một** máy 1 GbE ở phía LAN, nên mỗi chiều tối đa ~1 Gbit; đo tổng thì buộc
phải dùng `iperf3 --bidir`, mà bộ xếp lịch bidir của iperf3 trên con Realtek này cho RX-C từ 164
tới 542 Mbit/s giữa các lượt **cùng cấu hình**. Đo riêng từng chiều thì cả hai đều **945/946
Mbit/s** = tốc độ dây. Nên: con số **929 so với >1100** là kết luận vững (trần bị phá, lặp được
sáu lượt); con số **1552** đo được một lượt ở phần trên là đỉnh của cái tán đó, không phải một
mức ổn định — đừng
trích nó như một con số đo được. Muốn số tổng thật thì cần nguồn traffic thứ hai (cổng 2,5G hoặc
thêm một máy ở phía LAN).

ECM cũng sạch theo: 9 flow được accelerate, `src_mismatch_fail_count` = **0** (trước patch là 18),
softirq ~2,5% mỗi core.

### Rebase

`main` lên `f3588d3871`: **sạch, không xung đột**, 11 commit → **10** (commit bỏ hook bị drop).

| | trước | sau |
|---|---|---|
| `main` | `7735441d3c` | `12493d4754` |
| nền thượng nguồn | `d1b5d4f8ec` | `f3588d3871` |
| backup | | tag `backup/main-pre-rebase-20261107b` = `7735441d3c` |

Lưu ý `scripts/getver.sh`: nó lấy `main@{u}` (= `fork/main`) để tìm `UPSTREAM_BASE`, nên trước khi
push fork/main, chuỗi revision ra `r38500+13-d1b5d4f8ec` (13 = 3 commit thượng nguồn + 10 của
mình). Sau khi push nó mới gọn lại. Với bản test thì không quan trọng; nếu làm release thì push
`fork/main` **trước** khi build.

### Việc kuncy7 nhờ

Trong comment merge, kuncy7 nhờ đúng một việc: máy ở đây là board CR880x duy nhất còn chạy
**layout dual-boot gốc**, nên xin một lần kiểm LAN/WAN và NSS offload trên ảnh từ `f3588d3871`
trở lên, "no need to hold anything for it".

### Gửi đi, vào `main`, và release (2026-11-08)

- **PR 68 cho kuncy7**: https://github.com/kuncy7/openwrt-nss-edma/pull/68 — 4 commit, 8 file,
  +443/-38, nền `origin/c3po-tag-8021q` (`767c03c5ad`), nhánh `pr/two-conduits` của fork. Thứ tự cố
  ý tách được: 714 (conduit-open) → 784 (tag_8021q) → nss-tools `fw_mask` → chính sách board CR880x;
  bỏ commit cuối thì ba cái trước vẫn đứng một mình. Mọi commit có `Signed-off-by` (thêm **trước**
  khi push, để lần gửi `openwrt/openwrt` không phải viết lại lịch sử). Kèm một comment xin người
  test đúng ba việc: lặp lại flood, bỏ 714 ra xem conduit còn lên không, và một số tổng đo bằng hai
  nguồn traffic. **Không tự ping ai** — để kuncy7 điều phối.
- **`main` của fork**: cherry-pick đúng bốn commit đó lên `e42fc44bb8` → **`6156676c89`**. Kiểm
  trước khi build: patch 784 trên `main` **giống từng dòng mã** bản `0959g` đã đo trên máy (diff
  phần mã: rỗng), dtsi chỉ khác phần comment. Khác bản đang chạy đúng hai chỗ, và cả hai là tốt
  hơn: `board.d` cho `wan` dùng `eth0`, và `nss-tools` tự dẫn ra `fw_mask=0x3` — tức ảnh release
  không cần hai override tay mà slot 1 đang đặt.
- **Release `cr8806-nss-2026.11.08`** (tag = `6156676c89`, `DISTRIB_REVISION` `r38515-6156676c89`):
  build lại từ `make target/linux/clean`, EXIT=0; kiểm trong cây đã build rằng cả hai patch kernel
  thật sự vào (`dsa_tag_8021q_port_pre_change_conduit` và `of_phy_is_fixed_link` trong
  `net/dsa/port.c`) và rootfs mang `board.d` + `lib/nss/functions.sh` bản mới. Ảnh ở
  `~/nss-build/images-release-20261108/`, `sha256sum -c` khớp cả 8 file. Config chỉ khác 2026.11.07
  **đúng một dòng**: `CONFIG_PACKAGE_ip-bridge=y`.
  **Chưa nạp ảnh này lên máy nào** — mọi số đo là của nhánh test cùng mã, và release notes nói rõ
  chỗ đó.
  Nhớ: `scripts/getver.sh` lấy `main@{u}`, nên **push `fork/main` trước khi build** — làm đúng thứ
  tự nên revision ra gọn, không còn `+N` như lần 2026-11-07.
- Front page `.github/README.md` sửa lại dòng "plus two commits" cho đúng những gì `main` mang bây
  giờ (`1469a4a835`).
- Ba comment còn lại — kuncy7 issue 53, `openwrt/openwrt` issue 26157, `openwrt/openwrt` PR 26511 —
  đã viết gọn lại, **chưa gửi**.

## 27. Kho package riêng cho release: vì sao `apk update` lỗi, và vì sao dòng feed của thượng nguồn là nguy hiểm

Ngày 2026-11-11, thử `apk update` trên router (bản `cr8806-nss-2026.11.10`, `r38517-14875f61c8`):

```
1 unavailable, 0 stale; 10169 distinct packages available
ERROR: wget: exited with error 8
WARNING: updating and opening .../aarch64_cortex-a53/nss/packages.adb: unexpected end of file
The apk update command failed with code 1.
```

### Vì sao lỗi (đo được)

`feeds.conf.default` của cây này pin feed `nss` vào `github.com/kuncy7/nss-packages.git`, còn
`CONFIG_PER_FEED_REPO=y` làm `FeedSourcesAppendAPK` (`include/feeds.mk:47-62`) ghi vào image **một
dòng cho mỗi feed đang bật**, theo khuôn `%U/packages/%A/<feed>/packages.adb`. Thượng nguồn không
có feed nào tên `nss`, nên dòng đó 404:

```
.../aarch64_cortex-a53/nss/packages.adb   -> HTTP 404   (= wget error 8)
.../aarch64_cortex-a53/base/packages.adb  -> HTTP 200
```

Nghĩa là **phần mềm userspace vẫn cài được ngay, không cần build gì** — con số 10169 là thật. Chỉ
`apk update` trả exit 1 vì một feed chết.

### Kernel module thì không bao giờ lấy được từ feed thượng nguồn (đo được)

| | package kernel |
|---|---|
| snapshot thượng nguồn, ipq50xx | `kernel-6.18.60~445b517b0ed6daaa474b53dda7466054-r1` |
| bản build ở đây | `kernel-6.18.60~e182ccbedc76165223033d451eba4327-r1` |

Cùng 6.18.60, khác **hash của config + patch** (đương nhiên: cây này có NSS và các patch DSA). Mỗi
`kmod-*` depend đúng tên-version package kernel đó, nên apk sẽ báo unsatisfiable dependency. Thêm
nữa, kmod ipq50xx thượng nguồn build trên kernel stock không NSS.

### Dòng feed thật sự nguy hiểm (suy ra, **chưa thử** — và không nên thử trên máy đang chạy)

Dòng đầu tiên trong `distfeeds.list` (`include/feeds.mk:53`) là

```
https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq50xx/packages/packages.adb
```

Repo đó chứa `kernel`, `base-files` và toàn bộ `kmod-*` của bản stock — **cùng tên package, khác
version** với những gì đang cài. Một lần `apk upgrade`, hoặc `apk add` một kmod, là apk có thể thay
package `kernel` rồi kéo cả 64 kmod sang bản thượng nguồn; `.ko` sai vermagic thì ath11k và các
module NSS không load được sau reboot → phải nạp lại firmware. Đây là lý do chính để đổi cách làm,
không chỉ là chuyện 404.

### Chuỗi tin cậy đã sẵn sàng (đo được)

Index trong `bin/` **đã được ký** (`package/Makefile:195-201`, `--sign $(BUILD_KEY_APK_SEC)` khi
`CONFIG_SIGNED_PACKAGES=y`), và verify được khi trong keys-dir **chỉ có** `public-key.pem`:

```
apk adbdump --keys-dir <dir chỉ có public-key.pem> bin/packages/aarch64_cortex-a53/base/packages.adb
-> exit 0, "packages: # 86 items"
```

Mà đúng file khoá công khai đó, sha256 `2f33423181f3366d432ec1fd0a85650af4be74ab6e9c752137ff1858028864f3`,
đã nằm trong image tại `/etc/apk/keys/public-key.pem`. Vậy **ai flash release của mình thì router đã
tin kho package của mình**, không cần `--allow-untrusted`, không phải làm gì thêm.

Hệ quả phải nhớ:

- `private-key.pem` + `public-key.pem` (tạo 2026-10-24) chỉ có ở local; `.gitignore:23-25` chặn cả
  `key-build*`. **Phải backup offline** — mất khoá riêng là mọi router đã flash không verify được
  package mới nữa, chỉ còn đường reflash. Và nó là secret: không bao giờ push.
- Ai tự build sẽ sinh khoá của chính họ, nên kho package phải công bố kèm **public key** để họ thêm
  tay vào `/etc/apk/keys/` nếu muốn dùng.

### Cách sửa đã chọn: `%U` trỏ về kho của mình, userspace thượng nguồn xuống `customfeeds.list`

**1. `.config`** (menuconfig: Advanced configuration options → Version configuration options →
Release repository; khai báo ở `package/base-files/image-config.in:198`):

```
CONFIG_VERSIONOPT=y
CONFIG_VERSION_REPO="https://fanha99.github.io/cr8806-nss-packages/%R"
CONFIG_ALL_KMODS=y            # để người dùng apk add được mọi kmod
CONFIG_FEED_routing=m         # ba feed này không build package nào (0 apk)
CONFIG_FEED_telephony=m       # -> m = dòng feed ghi ra dạng comment (include/feeds.mk:60)
CONFIG_FEED_video=m
```

`%R` được thay bằng `REVISION` (`include/version.mk:103`), và `%U` được thay **trước** trong cùng
chuỗi sed nên `%R` nằm trong URL vẫn nở ra (đọc từ `include/version.mk:96-106`, **chưa chạy thử**).
Tức mỗi bản build tự trỏ vào thư mục package của chính nó — không phải sửa URL mỗi lần release, và
image cũ vẫn dùng được kho cũ. **Đừng xoá các thư mục revision cũ trên site.** Feed `nss` giữ `y`
vì giờ chính mình host nó → hết 404.

**2. `package/system/apk/files/customfeeds.list`** — file 3 dòng, là **conffile** của package apk
(`package/system/apk/Makefile:74-76`, cài vào `/etc/apk/repositories.d/customfeeds.list`), nên sống
qua sysupgrade và người dùng sửa được. Thêm userspace thượng nguồn:

```
# Upstream OpenWrt snapshots: userspace only. Do NOT add
# targets/.../packages here: its kernel/kmod packages are built
# against a different kernel config and will break NSS.
# Use `apk add`, not `apk upgrade`.
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/base/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/packages/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/luci/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/routing/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/telephony/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/video/packages.adb
```

Mấy feed arch này **không** chứa `kernel`, `base-files` hay `kmod-*` — những thứ đó nằm ở
`targets/%S/packages` (kiểm trong `bin/` của mình: `base-files-1727~14875f61c8.apk` và
`kernel-...apk` đều ở `bin/targets/qualcommax/ipq50xx/packages/`, còn
`bin/packages/aarch64_cortex-a53/base/` là 86 package userspace). Nên an toàn, và đủ 10169 package
để `apk add htop`, `luci-app-*`...

Đánh đổi còn lại: base của mình (pinned) và base thượng nguồn (rebuild hàng ngày) cùng tên package
khác version → `apk upgrade` sẽ kéo thư viện nền mới hơn về. Khuyến nghị trong release notes:
**chỉ `apk add`, đừng `apk upgrade`**.

**3. Kho host.** GitHub Pages, repo riêng `fanha99/cr8806-nss-packages`, layout y như OpenWrt
(`<rev>/targets/qualcommax/ipq50xx/packages/` + `<rev>/packages/aarch64_cortex-a53/{base,luci,packages,nss}/`).
Script dàn file: `tools/publish-packages.sh` của branch này — chỉ copy `*.apk` + `packages.adb` +
`index.json`, **không bao giờ copy image hay khoá riêng** (có check chặn file lạ), và chép
`public-key.pem` ra `cr8806-nss-public-key.pem`. Không chạy git. Chạy thử 2026-11-11 trên
`r38517-14875f61c8`:

```
targets/qualcommax/ipq50xx/packages: 91
packages/aarch64_cortex-a53/{base,luci,packages,nss}: 86 / 19 / 5 / 3
total: 204 packages, 15M
```

Dung lượng hiện tại 15 MB (đo); bật `ALL_KMODS` thì **ước** 60-100 MB — vẫn thoải mái so với hạn
mức ~1 GB của Pages (số hạn mức là nhớ từ tài liệu GitHub, chưa kiểm lại).

**Đừng dùng release asset thay Pages**: GitHub đổi ký tự lạ trong tên asset, mà tên package có `~`
(`kernel-6.18.60~e182…`), apk sẽ dựng URL sai và 404. (Suy ra từ cách GitHub đặt tên asset, chưa
kiểm bằng một lần upload thật.)

### Còn "cập nhật firmware" thì sao

`owut` / attended-sysupgrade cần một ASU server riêng (nó hỏi server build ảnh theo danh sách
package đang cài) — không đáng dựng cho một fork một board. Với dual-boot CR8806 thì cách gọn nhất
vẫn là release notes + `sysupgrade` giữ config vào slot **không** chạy, đúng quy trình đang dùng.

### Trạng thái và quyết định (2026-11-11)

- **Chưa sửa gì.** `.config` hiện tại: `CONFIG_VERSIONOPT` chưa bật, `VERSION_REPO` mặc định
  (`https://downloads.openwrt.org/snapshots`), `ALL_KMODS` chưa bật, cả 6 feed đều `y`.
- `~/nss-build/openwrt-nss` (branch `main`, `14875f61c8`) vẫn còn **hai file patch 714/784 sửa
  warning chưa commit** (xem mục 26) — cố ý để nguyên.
- **Quyết định**: đợi kuncy7 merge PR 68 rồi làm **cùng một lượt** — commit bản sửa warning lên
  `main`, bật 3 thay đổi ở trên, build lại một bản release (có `ALL_KMODS`), dàn kho package và
  push Pages. Làm sớm hơn thì phải build lại lần nữa sau khi merge.

## 28. Thượng nguồn nhận series, dựng lại `main`, và dựng kho package thật

Ngày 2026-11-11, sau khi sửa hai warning của kuncy7 (mục 26) và force push PR 68.

### kuncy7 nhận series, nhưng không bằng nút merge

Anh ấy **rebase cả 5 commit** của PR 68 lên `c3po-tag-8021q` thành `011b87e0ae`..`4d73bf55e2` rồi
đóng PR bằng tay, lý do: GitHub từ chối nút merge vì series có chạm `.github/workflows/`. Kiểm
bằng diff chứ không tin lời: `git diff c13dd991dc origin/c3po-tag-8021q` chỉ còn **4 commit riêng
của anh ấy** (CI cache, stmmac drop-TX, ath11k tx-rate, TP-Link U-Boot), tức 5 commit của mình vào
**nguyên vẹn, kèm cả hai bản sửa warning**, author giữ `Fanha Giang`, committer là Stanislaw Pal.

Anh ấy cũng trả lời chuyện RT-AX89X: tree này chỉ build ipq50xx nên không đổi ảnh nào được phát
hành, nhưng với `openwrt/openwrt#26511` — nơi RT-AX89X **được** build — thì nên thêm guard.

### Dựng lại `main`: 14 commit còn 7

Nền mới `4d73bf55e2`, bỏ 5 commit đã lên thượng nguồn. Hai việc phát sinh:

- **Đổi số patch stmmac của mình: `0958b` → `0958c`.** Thượng nguồn vừa thêm
  `0958b-net-stmmac-drop-host-TX-in-flight…`, trùng số với
  `0958b-net-stmmac-give-the-host-RX-buffers-back…` của mình, và cả hai sửa `stmmac_main.c` quanh
  dòng 2410-2440. Sau khi đổi tên thì thứ tự áp đúng (drop-TX trước), nhưng build vẫn báo
  **`Hunk #4 succeeded at 2473 with fuzz 1`** — patch mới chèn 17 dòng vào đúng vùng context của
  hunk #4. Fuzz thì áp được nhưng không được phép có trong một bản release, nên chạy
  `make target/linux/refresh`, giữ **đúng một file** của mình và `git checkout` lại 26 file còn
  lại — hoá ra cây kuncy7 có **27 patch chưa ở dạng refresh**, refresh sẽ viết lại hết. Context
  cuối hunk #4 đổi từ *"The firmware enables the DMA interrupts for itself…"* sang *"Frames the
  host queued just before the stop never complete now…"*, các hunk sau dịch 2453→2470, 2486→2551.
  Build lại: **fuzz 0**.
- **Pin feed nss nhảy `4fa071ab14` → `c94a78031d`**: "qca-nss-drv: reset truesize when reusing a
  tx skb as a receive buffer", bản sửa issue #54 — `nss_skb_reuse()` giữ truesize của kiếp trước
  của skb, với fraglist GRO thì nó dồn tới 2^31 làm UDP socket chết (`udp_prod_queue` kẹt ở
  0x80000000) và IPv4 reassembly tắc ở 2^32. Ảnh này tắt fraglist GRO nên chưa bao giờ gặp.
  Kiểm patch có vào thật bằng log build (`CONFIG_AUTOREMOVE=y` xoá source sau khi build nên
  không soi được build_dir): `Applying …/0150-nss_core-reset-truesize….patch` → `patching file
  nss_core.c`, không lỗi.

`.config` thêm đúng 4 nhóm: `IMAGEOPT`+`VERSIONOPT`, `VERSION_REPO`, ba feed rỗng thành `m`, và
**tắt** `VERSION_FILENAMES`/`VERSION_CODE_FILENAMES` — hai cái này default `y` khi bật VERSIONOPT,
để nguyên thì tên ảnh thành `openwrt-SNAPSHOT-r38522-…`, khác mọi release trước.

### Kho package: làm thật theo kế hoạch mục 27

Repo `fanha99/cr8806-nss-packages` + GitHub Pages, một thư mục cho mỗi revision.
`tools/publish-packages.sh` dàn file, `index.html` để root không 404.

**Đính chính một phép thử sai của chính mình**: mục 27 nói "index verify được khi chỉ có
`public-key.pem`" dựa trên `apk adbdump --keys-dir …` → **sai**, `adbdump` không verify gì cả
(keys-dir rỗng vẫn exit 0). Phép thử đúng là nạp repo bằng `apk list`:

```
apk list --root <root rỗng> --keys-dir <chỉ public-key.pem> --repositories-file <URL Pages>
  -> liệt kê đủ 91 package
cùng lệnh, keys-dir rỗng
  -> WARNING: fetching …/packages.adb: UNTRUSTED signature
```

Và tên package có `~` (`kernel-6.18.60~e182ccbe…-r1.apk`) Pages phục vụ bình thường, HTTP 200 —
đây là lý do mục 27 nói đừng dùng release asset (GitHub đổi ký tự trong tên asset).

`distfeeds.list` trong rootfs đã build: 5 URL của revision này, 3 feed rỗng bị comment, **không
còn dòng `targets/.../packages` của thượng nguồn** — tức cái bẫy kernel/kmod lệch vermagic ở mục
27 đã bị cắt từ gốc. `customfeeds.list`: 6 feed userspace.

### `openwrt/openwrt#26511`: vì sao CI đỏ hết, và guard đúng là gì

CI đỏ **toàn bộ** job, nhưng chỉ một nguyên nhân: step `Validate Refreshed Kernel Patches` —
patch chưa ở dạng refresh, mà patch nằm trong `generic/pending-6.18` nên mọi target build kernel
6.18 đều báo cây bẩn. Tái hiện bằng cách rebase nhánh lên main hiện tại rồi
`make target/linux/refresh`: nó viết lại đúng hai dòng hunk header

```
-@@ -1870,6 +1870,41 @@
+@@ -1881,6 +1881,46 @@ static void dsa_shared_port_link_down(st
```

(lệch 11 dòng vì `net/dsa/port.c` của main đã dịch, cộng tên hàm mà `QUILT_DIFF_OPTS="-p"` thêm
vào). Refresh cả series thì **không file nào khác đổi** — khác hẳn cây kuncy7.

**Guard mà mình đề xuất là sai, và kuncy7 đã đồng ý với nó.** `netdev_uses_dsa(dev)` là
`dev->dsa_ptr && dev->dsa_ptr->rcv` — **đúng với mọi conduit**, không phải "conduit là user port
của switch khác"; và ở thời điểm `dsa_shared_port_link_register_of()` thì chưa conduit nào có
`dsa_ptr`. Predicate đúng là `dsa_user_dev_check()`, chính cái DSA tự dùng để nhận switch xếp
tầng (`net/dsa/dsa.c:1145`, trong `dsa_get_tag_protocol()`). Đã sửa thành:

```c
if (!dp->conduit || dsa_user_dev_check(dp->conduit) ||
    of_phy_is_fixed_link(dp->dn))
	return;
```

Quét lại DTS của **openwrt main** (đi từng node, không grep bừa): sau khi có guard, patch còn tác
dụng với **4 board** — CMCC PZ-L8, Redmi AX5400, JDCloud AX6000, SPNMX56 — và RT-AX89X bị loại.
Hai board của PR 25153 (Archer AX55 v1, Mercusys MR80X v2) dùng `fixed-link` nên vốn đã return
sớm. Force push `ebf3830c11` → `692d005b51`; CI sau đó ở trạng thái `action_required` (PR từ fork
cần maintainer approve lại sau mỗi push).

Hệ quả: 714 ở hai cây **không còn giống nhau** — bản kuncy7 không có guard, bản openwrt có. Đó là
chủ ý của anh ấy, nhưng nên gửi anh ấy một PR nhỏ thêm guard để hai cây mang cùng một đoạn code,
kèm đính chính chuyện `netdev_uses_dsa`.

### Ba bài học về patch, cùng một gốc

1. **Đừng sửa tay hunk.** Lần này thử thêm 6 dòng vào thân hunk mà không sửa số đếm ở header →
   `patch: **** malformed patch at line 72`. Cách đúng: sửa trong source rồi `quilt refresh` với
   đúng tham số OpenWrt dùng (`QUILT_DIFF_OPTS="-p" quilt refresh -p ab --no-index --no-timestamps`,
   xem `include/quilt.mk:168`).
2. **`quilt edit` treo** vì nó gọi `$EDITOR`, không có thì gọi `vi` — job nền đứng 15 phút không ai
   biết. Sửa file bằng script rồi `quilt refresh`, không dùng `quilt edit`.
3. **Patch gửi openwrt phải ở dạng refresh**, nếu không CI đỏ hết mọi target — và đó là một
   nguyên nhân duy nhất, đừng đọc thành "nhiều lỗi".

### Thread netdev: "sửa ở đâu" — và nó nói gì về 714

Đọc được nhờ bạn lưu trang về `f:\html\` (lore.kernel.org trả 403 cho fetch tự động). Thread là
`[PATCH net-next v9 08/11] net: dsa: realtek: rtl8365mb: re-latch the family D SerDes` của
namiltd; ba message đáng kể:

**Johan Alvarado (= c127dev, tác giả PR openwrt 26597), 2026-11-10 00:49 EST.** Đo trên Mercusys
MR80X v2 (IPQ5018 + RTL8367S family C, CPU port 2500base-x, NAND, reboot loop), **cùng một bản
rtl8365mb cho cả bốn**:

| stack | boot lỗi |
|---|---|
| OpenWrt 6.18 (stmmac dwmac-ipq5018 + qca-uniphy PCS) | **18 / 51** |
| stack cũ qca-nss-dp + qca-ssdk (6.12) | 0 / 16 |
| 6.18 + patch thứ tự **phía switch** (bản của kuncy7, openwrt PR 25153) | 0 / 16 |
| 6.18 + UNIPHY mode sequence dời vào **GMAC probe**, không sửa switch | 0 / 32 |

Cơ chế: bootloader trao UNIPHY ở SGMII 1.25G; `qca-uniphy` chỉ program từ `pcs_config()`, mà cái
đó chạy ở **lần `ndo_open` đầu tiên của conduit**; switch dựng SerDes ở HSGMII lúc DSA setup, sớm
hơn ~2 s, nên receiver của nó train vào line rate sai. Bằng chứng chỗ kẹt là **receiver của
switch**: boot lỗi thì re-sequence UNIPHY không cứu được, unbind/bind driver switch thì cứu 100%;
dựng SerDes switch khi UNIPHY đã program sẵn thì 21/21 tốt. Kết luận của anh ấy: *"far end not up
yet"* thực ra là *"far end up at the wrong line rate"*.

Câu quan trọng nhất cho mình:

> *"Neither dwmac-ipq5018 nor pcs-qca-uniphy is in mainline, so none of this can be reproduced on
> a mainline kernel. That's why I'd rather not have the workqueue, the extra locks and the reboot
> notifier in rtl8365mb for it."*

**Alvin Šipraga (maintainer rtl8365mb), 2026-11-10 10:33 CET**: *"I guess if this can be fixed on
the SoC side …, then we can drop this patch from the series altogether. Correct?"*
**namiltd**: *"Yes… I will drop this patch from the upcoming v10 version of the series."*

Tức nguyên tắc hiện ra ở đây là: **sửa ở tầng sở hữu cái đầu đang sai, và đừng nhét workaround vào
code mainline cho lỗi chỉ tái hiện được với driver ngoài mainline.** 714 là thay đổi trong **lõi
DSA mainline**, và conduit của mọi board nó phục vụ là `dwmac-ipq5018` — ngoài mainline. Câu hỏi
sẽ gặp ở netdev gần như chắc chắn là *"sao không sửa trong driver conduit?"*. (Lưu ý: **không ai
trong thread bàn về việc DSA tự `dev_open()` conduit** — suy luận trước đó của tôi rằng netdev đã
bác cách đó là **sai**, thread không nói gì về nó.)

**Phản chứng, đo được** — quét toàn bộ DT in-tree của mainline 6.18.60, đi từng node port:

```
arm64: 32 port có 'ethernet = <>'  → 0 có phy-handle và không fixed-link
arm  : 79                          → 3
mips :  3                          → 0
```

Ba board là **Barco/GE imx6q-b450v3 / b650v3 / b850v3**, và cả hai đầu đều là driver **mainline**:

```
switch   : compatible = "marvell,mv88e6085"  (88E6240)
cpu port : port@4 { label="cpu"; ethernet=<&switch_nic>; phy-handle=<&switchphy4>; }  ← không fixed-link
conduit  : switch_nic = ethernet@4,0  compatible="pci8086,1533"  (Intel I210, driver igb)
```

Nên hình dạng DT mà 714 nhắm tới **có thật trong mainline**, không phải thứ chỉ tồn tại ở OpenWrt —
đó là lập luận phải đưa vào cover letter khi gửi netdev. Giới hạn phải nói thẳng: chưa chứng minh
ba board đó thật sự hỏng (không có máy, và 13 s xoá quảng bá 1000BASE-T là đặc tính QCA8337 PHY4);
chỉ chứng minh được hình dạng DT tồn tại, và pattern "PHY của conduit chỉ attach/power-up khi
`ndo_open`" cũng là hành vi mainline (`stmmac_init_phy()` gọi từ `stmmac_open()`; igb
`igb_power_up_link()` ở open, power-down ở close).

Hệ quả cho các việc đang treo:

- **PR 26511 (openwrt) không bị ảnh hưởng** — OpenWrt chính là nơi 4 board kia được build.
- **Gửi netdev thì phải chuẩn bị trả lời "sao không sửa trong driver conduit"**: ba board mainline
  ở trên, cộng lập luận một fix per-driver là N lần sửa cho N driver trong khi DSA là chỗ duy nhất
  biết topology, và patch đã tự giới hạn bằng hình dạng DT (`phy-handle`, không `fixed-link`).
- **PR 25153 của kuncy7 có thể thành không cần thiết** nếu 26597 land: số đo của Johan cho thấy cả
  hai cách đều 0 lỗi, và netdev đã bỏ patch phía switch. kuncy7 có trong Cc của thread nên chắc đã
  biết.
- Đề nghị "gộp ba patch thành một PR" của namiltd: sau khi patch 8 bị bỏ khỏi v10, hai thứ còn
  chồng nhau là **25153 (phía switch) và 26597 (phía SoC)** — đó mới là cặp nên thống nhất, 714
  không thuộc nhóm đó (bảng gmac0/gmac1 ở trên là bằng chứng).

### 784 thì gửi đâu

Quyết định: **gửi netdev, không mở PR openwrt.** 784 chỉ đổi hành vi khi một switch dùng tagger
tag_8021q có **từ 2 CPU port**. Quét cây openwrt main:

| driver dùng tag_8021q | board | số CPU port |
|---|---|---|
| an8855 | 5 board mediatek | 1 (hai node switch của hai biến thể, mỗi node 1 CPU port) |
| rtl8365mb | 6 board | 1 |
| mxl862xx | 1 board | 1 |
| sja1105 / felix / vsc73xx | không có board | — |

Và tagger `qca-8021q` làm CR880x gặp bug là của kuncy7, **không có trong openwrt**. Nên ở openwrt
patch này là code chết, reviewer sẽ hỏi ngay "board nào cần". netdev là chỗ đúng: bug lõi DSA,
đọc code là review được, và nếu nhận thì openwrt tự có khi bump kernel. 714 thì khác — nó có 4
board thật trong cây.

### Nạp lên Home1 và test sơ (2026-11-11 18:14)

Nạp `sysupgrade.bin` của `r38522-83b63e1b91` vào **slot 1** (máy đang chạy slot 0 với
2026.11.10 — ghi chú cũ nói slot 0 là 2026.11.08 nên đã sai, phải đọc máy mới biết). Config mang
sang bằng `sysupgrade -b` → `sysupgrade.tgz`. Backup trước khi nạp:
`~/nss-build/private-backups/home1-20261111-1813-pre-slot1.tar.gz`. Lên lại sau **30 s**.

| kiểm | kết quả |
|---|---|
| boot | đủ VLAN 68/6/7, 3 SSID, địa chỉ và khoá còn nguyên |
| chia conduit | `wan` trên `eth0` (`vid=3076 phys_if=0`), `lan1-3` trên `eth1` (`vid=6/7/68 phys_if=1`) |
| GMAC | cả hai `started`, `fw_link=up`, `fw_mask 0x3` |
| link | CPU port của switch lên 1Gbps/Full ở **2,039 s** (2026.11.10 đo được 4,634 s cho eth0); eth0 và eth1 đều 1000Mb/s Full |
| NSS | `NSS 256 MiB: active` cả hai radio, `nss_offload=1`, ECM accelerate 43 → 78 flow |
| station | 480 Mbit/s HE-MCS 9 và 433 Mbit/s VHT-MCS 9, cái thứ hai **idle 1,7 s mà vẫn 433** — đúng cái bản sửa ath11k nhắm tới, nhưng đây không phải A/B với bản cũ |
| RAM | MemAvailable 40-44 MB (có LuCI) |
| lỗi | `dropped frame` 0, không TX timeout, không reset adapter (5 dòng "watchdog" trong dmesg đều là RX mitigation timer và procd, vô hại) |

**Kho package, test từ chính router** — đây là thứ chưa từng chạy trên máy thật:

```
apk update  -> exit 0, "OK: 9988 distinct packages available", không còn 404
apk add htop            (feed userspace thượng nguồn)  -> cài được, htop 3.5.3 chạy, rồi apk del
apk add sqm-scripts-nss (feed nss, chỉ tồn tại ở kho của mình) -> cài được, chữ ký verify, không cần --allow-untrusted
```

Tức chuỗi tin cậy chạy thật trên thiết bị: `/etc/apk/keys/public-key.pem` trong ảnh tin kho
Pages, không phải chỉ đúng trên PC.

**Hai sai sót của mình trong lúc test, ghi lại để không lặp:**

1. `apk add sqm-scripts-nss` rồi `apk del sqm-scripts-nss sqm-scripts` — nhưng gói đó **đã có
   trong ảnh**, nên `add` là no-op và `del` đã **xoá hai gói của ảnh** (190 → 188). Đã cài lại
   ngay, về 190, nhưng giờ hai gói đó nằm ở overlay (240 KB) chứ không còn trong squashfs
   read-only. Bài học: trước khi `apk del` trong một phép thử, kiểm `[installed]` xem gói có sẵn
   trong ảnh hay không.
2. Một phép thử trước đó dùng `apk adbdump` để "verify chữ ký" — nó không verify gì cả (xem phần
   đính chính ở trên).

Đường về: `fw_setenv flag_last_success 0; fw_setenv flag_boot_rootfs 0; reboot` → slot 0 với
2026.11.10 còn nguyên config.

### Chưa test

- Thông lượng: cổng WAN của máy này **không cắm dây**, nên đường routed hai conduit không được
  chạy qua. Số của 2026.11.08 vẫn là số tham chiếu (927-929 Mbit/s một conduit, 1104-1458 hai
  conduit).
- Soak dài, và chính hai thứ mà bản sửa truesize của NSS và bản drop-TX của stmmac nhắm tới —
  không có gì trong phép thử này tái hiện chúng.

## Việc còn lại

- ~~**Kho package riêng cho release**~~ (mục 27) — **xong 2026-11-11**, xem mục 28: kuncy7 đã lấy
  cả series, `main` dựng lại còn 7 commit (`83b63e1b91`), kho
  `fanha99/cr8806-nss-packages` chạy trên GitHub Pages và `apk add` đã test **từ chính router**.
  **Còn lại**: (a) push tag + tạo release `cr8806-nss-2026.11.11` và đăng comment
  `openwrt/openwrt#26511` — cả hai đã soạn, chờ chốt; (b) gửi kuncy7 một PR nhỏ thêm guard
  `dsa_user_dev_check()` để 714 ở hai cây giống nhau, kèm đính chính `netdev_uses_dsa()`;
  (c) gửi 784 lên netdev; (d) báo kuncy7 lỗi `printf: %l` ở `nss-status.test.sh:388` (suite PASS
  hết case nhưng exit 2 dưới dash); (e) khi nào tin bản mới thì nạp luôn slot 0.

- ~~**Kiểm ảnh từ `f3588d3871` trở lên cho kuncy7**~~ — **xong 2026-11-07/08**, xem mục 26.
  LAN/WAN thông, routed đạt line rate một chiều (932 Mbit/s), NSS offload còn nguyên, softirq
  0,3%/1,8%, 0 `dropped frame`: không có regression nào. Và bật lại port 5 là **đủ** để routed sập
  932 → 723 Mbit/s với một core cháy 98% — `a67d696c5d` đúng cả thay đổi lẫn cơ chế.
  **Còn lại**: comment kết quả cho kuncy7 (issue 53) đã viết, **chưa gửi**; và quyết định giữ hay
  xoá các nhánh test `port5-ab` (`e7bd354a12`), `no714-hook` (`ebdb8df625`),
  `port5-2conduit` (`205d5d7cc2`), `dsa-tag8021q-own-cpu-port` (`59638795e2`), `pr/dsa-tag8021q`.
- ~~**Viết patch DSA cho `dsa_port_tag_8021q_vlan_match()`**~~ — **xong 2026-11-08**, nhánh
  `dsa-tag8021q-own-cpu-port`, đã build, nạp slot 1 và đo: bản sao trên eth0 về **0**, một conduit
  với port 5 bật đi từ 723 lên **933**, hai conduit phá trần 929 mà **không** cần `brwan`. Chi tiết
  ở mục 26, "Patch DSA: viết, build, nạp, đo". **Đã gửi kuncy7**: PR 68 (4 commit, nền
  `c3po-tag-8021q`), kèm một comment xin người test. **Còn lại**: gửi hai patch kernel lên
  `openwrt/openwrt` `generic/pending-6.18`, rồi bản `[PATCH net-next]` lên netdev; và ba comment đã
  viết gọn nhưng chưa gửi (kuncy7 issue 53, openwrt issue 26157, openwrt PR 26511).
- **Xác nhận ở mức thanh ghi: đọc VTU entry của VID 3076** để thấy port 5 trong egress set. Cần
  một patch hai dòng `#define REGMAP_ALLOW_WRITE_DEBUGFS` trong
  `drivers/base/regmap/regmap-debugfs.c` để `/sys/kernel/debug/regmap/.../registers` thành 0600.
  Hành vi thì đã chứng minh xong (phép thử ba chân, workaround bridge, rồi patch), đây chỉ là xác
  nhận cuối.
- ~~**Quyết định cho cây này: hai conduit có thành mặc định của CR880x không?**~~ — **có**, từ
  2026-11-08: `main` = `6156676c89` mang đủ bốn commit (714, 784, nss-tools `fw_mask`, chính sách
  board), nên `ethernet-port@5` bật lại, `board.d` cho `wan` dùng `eth0` và `fw_mask` tự dẫn ra
  `0x3` — **không cần bridge, không cần override tay nào**. Rủi ro còn lại là lệch thượng nguồn:
  nếu ai lấy `main` này mà bỏ hai patch kernel đi thì rơi về 723 Mbit/s với một core cháy, nên hai
  patch đó phải đi cùng commit board policy (PR 68 xếp đúng thứ tự đó).
- ~~**Nạp lại một bản tốt vào slot 1 của Home1**~~ — xong: slot 1 giữ bản có patch DSA và nay là
  slot chính. **Còn lại**: slot 0 vẫn là `main` của 2026-11-07 (một conduit) làm đường về; khi nào
  tin bản mới thì nạp release 2026.11.08 vào slot 0.

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
  Phần test còn ý nghĩa — **roaming trên backhaul dây** — đã làm xong ở **mục 19**: đã đi vòng
  thật, đã siết usteer, đã dựng cách đẩy client bằng lệnh để không phải đi nữa, và đã kết luận
  FT không hoàn tất (SAE đầy đủ mỗi lần, không phải `auth_alg=ft`). Bản build vẫn mang `wpad-mesh-mbedtls` + `CONFIG_ATH11K_NSS_MESH_SUPPORT`
  (tốn ~262 KB ảnh, 28 KB module); không gỡ, để dành đường thử lại sau.
- ~~Thêm `usteer`~~ — xem **mục 19**: nó đã tự chạy sẵn trên cả hai AP (mặc định của gói bật
  service), chỉ là không steer gì vì mọi ngưỡng mặc định bằng 0; đã bật mức nhẹ nhất ngày
  2026-11-06, rồi siết một bậc nữa sau khi thấy client đu tới −88 dBm (`roam_trigger_snr -68`,
  `signal_diff_threshold 8`, `aggressiveness 2`). Phép thử đi vòng **đã làm**, chuỗi steer chạy
  đủ từ đầu đến cuối — xem bảng và phần "FT vẫn không chạy" ở mục 19. `luci-app-usteer` vẫn
  chưa thêm. 802.11r sẵn trong `wpad-mesh-mbedtls` như cũ, và usteer
  **không** liên quan gì đến mesh — nó điều hướng client giữa các AP qua LAN, backhaul dây hay
  vô tuyến đều dùng được.
- ~~Script chuyển cấu hình từ bản hzyitc (swconfig, OpenWrt 23.05.3) sang bản DSA này~~ —
  `Convert-HzyitcConfig.ps1` đã kiểm bằng một backup thật, kết quả đã chạy trên máy thứ hai
  (xem mục 17), và nay đã commit vào `tools/hzyitc2nss/` của branch này. Còn lại: nếu muốn ai
  khác dùng thì nên đưa ra repo riêng, và README đang là tiếng Anh + một mục "dùng nhanh" tiếng Việt.
- ~~Mục 8: vì sao hạ pool xuống 2048 làm cạn~~ — xong, xem cuối mục 8: 2048 = `n2h_low_water_core0`.
- ~~Mục 16: gửi patch 714 lên openwrt/openwrt~~ — xong: PR #26511, CI 3/3 pass, mô tả đã sửa
  theo số đo ở mục 26. Còn lại: theo phản hồi reviewer, nhờ người có Redmi AX5400 /
  PZ-L8 kiểm chứng, và gửi bản `[PATCH net-next]` lên netdev. PR bỏ hook vào
  kuncy7/openwrt-nss-edma **không còn cần**: thượng nguồn tự xoá file hook ngày 2026-11-07
  khi tắt port 5 (xem mục 26), và commit bỏ hook của mình bị drop khi rebase. Nhưng patch 714
  cũng thành no-op trên CR880x từ đó — cần chuẩn bị câu trả lời "sao không tắt port đi" cho
  reviewer, và chỗ còn minh hoạ được vấn đề giờ chỉ còn AX5400 / PZ-L8 (wan ở eth0, không tắt
  port 5 được).
- 999-998: **đã bỏ 2026-11-07** (mục 23; cặp thêm-rồi-revert bị xoá khi dọn lịch sử cho release,
  xem mục 25 — `main` giờ đơn giản là không có nó). Phần đo
  RAM ở **mục 20** vẫn đúng (4,01 MiB cho cả hai radio) — chỉ là cái giá 4 MiB đó không mua được
  gì nếu nó chặn TX.
  **Nó nằm ở đâu (2026-11-06)**: có trong nhánh `ram-round1` đang chạy ở **slot 1 của máy thứ
  nhất**; **không** có ở máy thứ hai (và không có ở slot 0 làm đường về). Số liệu lẻ "4 client
  trong 4,7 h, mọi `*_desc_alloc_fail` = 0" ghi trước đó là **đường cơ sở của bản không có
  patch**, không nói gì về việc 16384 có đủ hay không.
- BPF JIT: được gì — vùng `bpf_prog_pack` **2 MiB** cấp lúc boot cho đúng một chương trình BPF
  (`ptp_classifier_init`, dùng để nhận gói PTP; board này không dùng PTP). Tắt `bpf_jit_enable`
  bằng sysctl **không** có tác dụng vì nó JIT trong `sock_init` trước mọi sysctl (mục 10, phần
  3), nên chỉ còn cách tắt `CONFIG_BPF_JIT` trong kernel config. **Đã thử thật ở mục 20**: tắt
  trong `config-default` của subtarget ipq50xx thì mọi stack có chữ `bpf` tụt từ 2 MiB xuống
  20 KiB, không hỏng gì (không có `BPF_JIT_ALWAYS_ON`, và board này không chạy BPF nào khác).
  Còn lại: config đó dùng chung cho mọi board ipq50xx nên **phải hỏi upstream** trước khi đề
  nghị tắt mặc định; chuyện riêng của mình thì cứ giữ trong fork.
- ~~Mục 18: mở PR nhánh `nss-tools-fw-mask` vào `main` của fork, và build một ảnh mang bản sửa~~ —
  xong 2026-11-08: cherry-pick thẳng vào `main` (`c20f4b39d1`, kèm `tests/dsa-fw-mask.test.py` 5/5
  và một job CI), có trong release 2026.11.08, và là commit 3 của PR 68 gửi kuncy7 (nó cũng sửa
  cho PZ-L8, Cudy P5, Redmi AX5400 — ba board có `wan` ở `eth0`).
- **Vòng 2 (việc lớn còn lại)**: giải phóng page pool RX của stmmac khi NSS claim GMAC, cấp lại
  khi release (mục 9, trên nền patch 0956). Không còn là phỏng đoán nữa — mục 20 đo được đúng
  **4,00 MiB**, hai stack mỗi stack 2,00 MiB (512 trang), một qua `stmmac_open`, một qua
  `stmmac_change_mtu`. Cách làm đã chọn: thả **lúc claim**, cấp lại **lúc release** (release vốn
  đã phải bounce interface nên không thêm rủi ro ở đường đó) — **không** chọn "ring nhỏ ngay từ
  probe", vì cách đó làm hỏng đường host của bản không NSS. Phần `-EBUSY` chặn `ethtool -G/-L`
  lúc đang claim **đã có sẵn từ 2026-10-26** (kuncy7, `0958a-*`), **đừng viết lại** — xem mục 9.
- `coherent_pool`: xem PR 45. Pool bộ đệm trống NSS: mục 8, không hạ được.

### Trạng thái hai máy, chốt ngày 2026-11-06

| | máy thứ nhất | máy thứ hai |
|---|---|---|
| slot đang chạy | **slot 1** = release `cr8806-nss-2026.11.07` (từ 2026-11-07 10:20) | **slot 1** = `ram-round2-nopageowner` |
| slot còn lại | slot 0 = `ram-round2` + page_owner, là đường về | slot 0 = bản mesh mục 17, là đường về |
| 999-998 | **không** (slot 1 = release 2026.11.07) | **có** (chưa nạp lại) |
| BPF JIT | tắt | tắt |
| page_owner | tắt | tắt |
| vai trò trong mạng | lá — được phép reboot/flash | nối máy chính xuống máy thứ nhất — **không** reboot khi đang test |

Nghĩa là **hai máy hiện khác build**: mọi so sánh RAM giữa hai máy phải trừ page_owner ra, còn
roaming/usteer thì không bị ảnh hưởng (chúng không dính gì tới ba thay đổi trên). Backhaul là
**dây**, một sợi trunk; mesh vô tuyến chỉ còn nằm trong image, không dùng, không test.

Wi-Fi: cùng SSID / cùng khoá hai máy, 802.11k + 802.11v chạy thật, usteer siết một bậc
(`-68` / diff 8 / aggressiveness 2), FT-SAE khai tường minh nhưng **chưa hoàn tất lần nào**.

### Cần test thêm — xếp theo thứ tự nên làm

1. ~~**Vòng 2**: viết patch, build, nạp, đo lại~~ — **xong 2026-11-06**, xem cuối mục 21: hai
   stack 2,00 MiB mất hẳn, MemAvailable +4,03 MiB, đường release/unpark đã thử thật trên `eth0`.
2. **Bỏ page_owner rồi đo con số thật** (việc kế tiếp): hiện 41,2 MiB vẫn còn ~4,5 MiB
   `page_ext` của page_owner. Chỉ sau khi tắt mới biết cả hai vòng để lại bao nhiêu RAM dùng
   thật — dự kiến quanh 45,7 MiB, so với 35,8 MiB của bản mesh.
3. **Soak vòng 1 (+2)**: để chạy liền nhiều ngày, theo `n2h_payload_alloc_fails`,
   `*_desc_alloc_fail`, MemAvailable, `PDEV resets` — y như mục 15/16 đã làm với bản DSA.
4. ~~**999-998 với nhiều client**~~ — **người test trả lời giúp 2026-11-07, xem mục 23**: 35
   client trên 2.4 GHz, và 5 GHz dừng ở ~200 Mbit/s với `tx_failed` không retry. Đã revert
   999-998 (mục 25). Việc còn lại đổi thành: **đo lại** throughput 5 GHz trên bản không
   999-998, và nếu vẫn ~200 Mbit/s thì tới 999-992 (một biến một lần).
5. **`PDEV resets` 5 GHz**: `memlong.sh` đang ghi 10 phút một lần trên **cả hai** máy từ
   2026-11-06 20:21; cần vài ngày để so hai chuỗi. Nhớ nó **không** tự chạy lại sau boot — mỗi
   lần flash/reboot phải bật lại tay.
6. **Roaming với ngưỡng mới**: ngưỡng `-68` + aggressiveness 2 mới đặt sau lần đi vòng, chưa
   sống qua một ngày dùng thật. Cần xem có steer **sớm quá** hay ping-pong giữa hai AP không;
   dấu hiệu là `roam_events` trên **remote node** (`ubus call usteer remote_info`, **không**
   phải `local_info`) tăng liên tục khi đứng yên.
7. **FT, nếu còn muốn truy**: chạy hostapd `-d` (sửa `/etc/init.d/wpad`, restart — Wi-Fi hai máy
   nhấp một nhịp), tìm `FT: Derived PMK-R0` và `XXKey` để biết `sm->pmksa` có gắn hay không.
   Đây là việc tuỳ chọn: roaming đã chạy được mà không cần FT.
8. ~~**Nạp cho máy thứ hai**~~ — xong 2026-11-07, xem mục 22. Cả hai máy giờ cùng một build.
9. ~~SSID khách và IoT chưa có `ieee80211k`/`bss_transition`~~ và ~~2.4 GHz cùng kênh 1~~ — đã
   vá 2026-11-07, xem cuối mục 22. Còn lại: **soát từng thiết bị IoT** khi chúng bật lên (lúc
   đổi không có client IoT nào để kiểm), và hai SSID đó vẫn chưa có `ieee80211r` (để dành).
   `luci-app-usteer` chưa thêm.

### Dọn dẹp còn nợ

- Mở PR nhánh `nss-tools-fw-mask` vào `main` của fork (mục 18).
- Gửi patch 714 thành `[PATCH net-next]` lên netdev, và theo phản hồi ở PR #26511.
- `private-backups/mesh-key-20261106.txt` và các bản `/root/*.bak*` trên router: xoá khi không
  cần nữa. Khoá FT 256-bit đang nằm ở `private-backups/ft-key-20261106.txt` (mode 600).
- Branch `backup/notes-pre-rewrite-20261106` **vẫn còn SSID tạm** trong lịch sử: giữ vài ngày
  cho chắc rồi `git branch -D`.
- ~~Worktree `openwrt-upstream-wt`, hai ref cũ, tarball backup máy thứ hai~~ — xong
  2026-11-06: đã xoá hai worktree `openwrt-upstream-wt` / `openwrt-v2-wt` (branch vẫn còn trong
  repo gốc), xoá hai ref `dsa-conduit-open-test-old` và `main-pre-rebase-20261106` sau khi
  `git cherry` xác nhận **mọi** commit của chúng đã có chỗ khác theo patch-id, chuyển tarball
  máy thứ hai vào `private-backups/` rồi xoá bản trùng (md5 giống hệt bản
  `home2-...-pre-slot0-hzyitc`), xoá `__pycache__`, và `shred` khoá mesh.
  **Giữ lại** toàn bộ `images-*` (~850 MB): ổ còn 921 GB nên xoá chẳng được gì, mà mỗi thư mục
  là một đường về không cần build lại.
- Bản patch 714 dạng gửi netdev (tên thật, có `Date:`, bỏ trailer `Link:` GitHub) trước nằm
  **chưa commit** trong worktree `pr-wt` — chỉ một lệnh `git checkout` là mất. Đã cất vào branch
  riêng `patch714-netdev-draft-20261106`, còn branch của PR giữ nguyên dạng openwrt.
- `tcpdump-mini` + `iotflow.sh` để dựng allowlist cho đám IoT — chưa làm.
