# Günlük LN Mutabakatı + Outlet Haftalık Çıkış Excel'i — Tasarım

**Tarih:** 2026-08-17
**Bağlam:** Depo siparişi LN'den bu sisteme taşınıyor. Envanter/tüketim/maliyet raporları LN'de kalıyor. Amaç: bu sistemden **anlık (canlı) stok takibi** yapmak ve LN ile mutabakat kurmak.

## Problem

- LN'in stok sayısı **günlük tüketimi işlemiyor**; tüketim LN'e **haftada bir, Cumartesi** toplu işleniyor.
- Dolayısıyla hafta ortasında LN'in stok sayısı gerçeğin ÜSTÜNDE (tüketimi henüz düşmemiş).
- Anlık takibi LN veremez (geç kalıyor). Anlık takibi **bu sistemin kendi sipariş takibi** verir (her onaylanan sipariş stoğu canlı düşürüyor — `depo_durum_degistir`, kurulum.sql:413).
- LN'i her gün yükleyip stoğu ona **eşitlemek** canlı takibi bozar: LN'in geç kalan tüketimi, sistemin canlı düşürdüğü tüketimi ezer.

## Çözüm 1 — Günlük LN Mutabakatı

### Formül (ürün bazında)

| Sembol | Anlam |
|---|---|
| **S** | Sistemdeki mevcut stok (siparişlerle zaten canlı düşmüş) |
| **G** | Son kesimden (Cumartesi) beri onaylanan siparişler = LN'in henüz işlemediği tüketim |
| **L** | Bugün yüklenen LN sayısı |

- **Gelen mal (fark) = L − (S + G)**
- **Yeni stok = S + fark = L − G**

**Mantık:** LN günlük tüketimi işlemediği için, LN'in bir dönemde arttığı miktar = o dönemde GELEN mal. `S = B − G` olduğundan (B = son kesim taban değeri), `L − (S+G) = L − B` = net gelen mal. Sistem tüketimi zaten canlı düşmüş; üstüne geleni ekleyince gerçek stok bulunur.

**Örnek:** S=100, G=30 → gün başı 130. L=150 → gelen = 150−130 = **20**, yeni stok = **120**. Doğrulandı (kullanıcı).

### Cumartesi kuralı (kesim)

- **Cumartesi yüklemesi:** LN tüketimi işlemiştir → `yeni stok = L` (direkt eşitle/baseline), `son_kesim = bugün`, G sıfırlanır.
- **Pazar–Cuma:** normal formül (`yeni stok = L − G`). G, `son_kesim`'den beri birikir.
- **Atlanan Cumartesi:** `son_kesim`'den sonraki ilk yükleme, tarihi Cumartesi'yi geçmişse kesim sayılır (sistem kendini toparlar). Kullanıcı önizlemede modu elle de değiştirebilir.

### G nasıl hesaplanır

`G[kod] = Σ coalesce((el->>'o')::numeric, (el->>'m')::numeric)` — `siparisler` içindeki **durum='onaylandi'** ve **onay_saati > son_kesim** olan tüm siparişlerin kalemleri. (Tüketim = onaylı siparişler; miktar = düzeltilmiş/onay miktarı, yoksa asıl miktar.)

### Değişecekler

1. **DB (kurulum.sql):**
   - `ayarlar`'a `son_kesim timestamptz` (varsayılan: en yakın geçmiş Cumartesi 00:00 Europe/Istanbul).
   - Yeni RPC **`stok_mutabakat(p_sifre, p_kalemler jsonb, p_kesim boolean, p_zorla boolean)`**:
     - Şifre + `depo_dogru` kontrolü.
     - Her kalem için S (stok tablosundan), G (yukarıdaki sorgu) hesaplanır.
     - `p_kesim = true` → `yeni = L`, `son_kesim = now()`. `false` → `yeni = L − G` (negatifse 0'a çekilmez, olduğu gibi bırakılır ama önizlemede kırmızı uyarı verilir).
     - `stok` upsert (miktar = yeni). `stok_yukleme`'ye `mod='mutabakat'` kaydı (mevcut sha256 imza + mükerrer koruması + geri alma altyapısı aynen kullanılır).
     - Dönüş: her kalem için `{kod, ad, birim, s, g, l, fark, yeni}` + toplam.
   - Geri alma (`stok_yukleme_geri_al`): mutabakat modunu da desteklemeli — kalemler snapshot'ından eski `e` değerine döner (baseline geri alma ile aynı mantık, kurulum.sql:644).
2. **depo.html STOK sekmesi:**
   - Mevcut Baseline / Mal kabul yanına **"📅 Günlük LN Mutabakat"** modu (radio/buton).
   - Dosya yüklenince **önizleme tablosu**: her ürün `KOD · AD · S · G · L · GELEN(fark) · YENİ STOK`. Negatif/anormal satır kırmızı.
   - Yükleme tarihi Cumartesi ise "kesim (eşitle)" kutusu **işaretli** gelir; kullanıcı değiştirebilir.
   - "Uygula" → `stok_mutabakat`. Mükerrer dosyada "yine de uygula" akışı (mevcut `p_zorla` deseni).
3. Otomatik stok düşümü (`depo_durum_degistir`) **aynen kalır** — canlı takibi o sağlıyor; mutabakat sadece geleni ekler.

## Çözüm 2 — Outlet Haftalık Çıkış Excel'i

Her outlet için, o haftanın **toplam çıkışını** mevcut LN Infor Excel formatında (birebir, `buildExcelBlob`) üretir. **Excel formatı hiç değişmez**; tek fark: miktar = ürün bazında haftalık toplam.

### Davranış

- Depo ekranında outlet seç + tarih aralığı (varsayılan: **son kesim → bugün**, otomatik dolu; elle değiştirilebilir).
- Seçilen outlet'in aralıktaki **onaylı** siparişleri ürün bazında toplanır: `miktar = Σ coalesce(o, m)` (kod bazında).
- `buildExcelBlob` mevcut haliyle çağrılır (şablon, sütunlar, ROW2, XML kaçış — hepsi aynı). Dosya adı: `haftalik_cikis_<outletKod>_<bas>_<bit>.xlsx`.
- **Her outlet ayrı dosya** (bir outlet seç → tek dosya). Toplu "hepsi" kapsam dışı (istenmedi).

### Değişecekler

- **depo.html:** TÜKETİM (veya STOK) sekmesine outlet seçici + tarih aralığı + "Haftalık Çıkış Excel indir" butonu.
- İstemci tarafı: `depo_envanter(bas, bit)` (mevcut RPC) ile siparişler çekilir, seçili outlet + onaylı filtrelenir, kod bazında toplanır, `buildExcelBlob`'a verilir. **Yeni RPC gerekmez.**

## Kapsam dışı (YAGNI)

- Toplu "tüm outletler tek dosya" Excel.
- Mal kabul modunun kaldırılması (kalıyor; elle giriş için hâlâ faydalı).
- Otomatik "büyük düşüş tespiti" ile kesim (yerine sabit Cumartesi çıpası + elle override).

## Riskler / dikkat

- **Çift sayım:** Otomatik düşüm + mutabakat birlikte çalışır; formül `S`'i (düşülmüş) kullandığı için çift saymaz. Test şart.
- **son_kesim doğruluğu:** Yanlış kesim = yanlış G. Cumartesi çıpası + elle override bunu güvenceye alır.
- **Geri-uyum:** `stok_mutabakat` yeni RPC; canlıda `kurulum.sql` çalıştırılmadan buton hata verir → kullanıcıya "önce SQL" denir. `buildExcelBlob` çıktısı non-`&` ürünlerde birebir aynı kalmalı (regresyon testi).
