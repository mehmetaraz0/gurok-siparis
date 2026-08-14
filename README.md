# GUROK Sipariş Sistemi

ALI BEY CLUB MANAVGAT — 22 bar + 3 mutfak, LN Infor Excel çıktısı.

Barlar ve mutfaklar talep gönderir, depo düzeltip onaylar, Excel onaylanmış miktarlarla iner.

| Sayfa | Kim kullanır | Ne yapar |
|---|---|---|
| `bar.html` | Bar ve mutfak personeli | **Kodunu girer** (bar `315`, mutfak `M201`), miktar girer, **Siparişi Gönder** |
| `depo.html` | Depo sorumlusu | Şifreyle girer, talepleri düzeltir, onaylar, Excel indirir |

## Akış

```
BAR                          DEPO
───                          ────
kod gir (315)
miktar gir
Siparişi Gönder  ─────────►  talep listesinde belirir
   ↓                              ↓  (tıkla)
ekran sıfırlanır             sipariş detayı
makbuz: SIP-...-007          miktarları düzelt (0 = verilmedi)
                                  ↓
                             ✅ ONAYLA → kilitlenir
                                  ↓
                             ⬇ Excel (onaylanmış miktarlarla)
```

**Sipariş numarası:** `SIP-20260814-007` — gün içinde sıralı, benzersiz.
Bir bar günde istediği kadar sipariş gönderebilir; her biri ayrı numara alır.

**Bar gönderince ekranı sıfırlanır.** Sipariş depoda kalır. Bar sadece o günkü
gönderimlerinin makbuzunu görür (numara + saat + kalem sayısı).

**Kilit yalnızca depoyu bağlar.** Onaylanan siparişte depo düzeltme yapamaz;
**🔓 Kilidi Aç** ile geri alınır. Bar tarafı hiç etkilenmez, yeni sipariş gönderebilir.

Barda Excel butonu yoktur — çıktıyı depo alır. Böylece düzeltilmemiş miktarların
yanlışlıkla LN Infor'a yüklenmesi mümkün olmaz.

## Mutfaklar

Mutfak personeli koduna **M** ekler: `M201`, `M204`, `M202`. Bar `201` ile mutfak `201`
çakışmasın diyedir; bar personelinin alışkanlığı değişmez.

| Kod | Mutfak | Bölümler |
|---|---|---|
| **M201** | ANAMUTFAK (CMM201) | KAHVALTI 136 · SICAK 116 · SOĞUK 79 · PASTANE 120 kalem |
| **M204** | PARK MUTFAK (CMM204) | ANAMUTFAK ile aynı 4 bölüm |
| **M202** | AQUA MUTFAK (CMM202) | tek liste, 117 kalem |

Çok bölümlü mutfakta kod girildikten sonra **bölüm seçimi** çıkar. Her bölüm **ayrı sipariş**
gönderir ve depoda ayrı numarayla, mor bir bölüm etiketiyle görünür — kahvaltının siparişi
pastanenin siparişine karışmaz. Tek bölümlü mutfak (M202) seçim ekranını atlar.

Mutfak listelerinde ürün grubu yoktur; sıra Excel dosyasındaki sırayla aynıdır. Aynı listeyi
kullanan M201 ve M204'ün taslakları ve siparişleri birbirinden bağımsızdır.

**Henüz eklenmedi** — ürün listesi geldiğinde eklenecek:
`CMM201 → SAHİL KAHVALTI`, `CMM201 → SAHİL PIZZA`, `CMM203 Personel Mutfağı`,
`CMM205 Club Lojman Personel Yemekhanesi`

## Bar kodları

| Kod | Bar | | Kod | Bar |
|---|---|---|---|---|
| **201** | ALIBEY RESTAURANT | | **308** | KARAGOZ |
| **202** | PARK RESTAURANT | | **310** | ILICA BAR |
| **204** | SAHIL RESTAURANT | | **311** | HARLEK |
| **205** | AQUA RESTAURANT | | **312** | HISAR |
| **206** | KIYI RESTAURANT | | **313** | YONCALI |
| **301** | TURK KAHVESI | | **314** | FRIG BEACH BAR |
| **302** | CARDAK | | **315** | PAVILLION BAR |
| **303** | TALVAR | | **316** | LOBBY BAR |
| **304** | POOL | | **317** | PARK TURK KAHVESI |
| **305** | ALI'S PUB | | **318** | SARAP VE BIRA EVI |
| **306** | TENIS BAR | | | |
| **307** | KONAK | | | |

`315`, `csm315`, `CSM315` yazımlarının hepsi kabul edilir. Kod sekme oturumunda tutulur;
sayfa yenilenince sorulmaz, sekme kapanınca sorulur. **↔ Birim Değiştir** ile koda dönülür.

## Depo ekranı

**📋 TALEPLER** — gelen siparişler alt alta, her satır bir sipariş:

| SİPARİŞ NO | BAR | SAAT | KALEM | DURUM |
|---|---|---|---|---|
| SIP-20260814-007 | 315 PAVILLION BAR | 14:32 | 12 kalem · *2 düzeltildi* | 🟡 Talep |
| SIP-20260814-006 | 201 ALIBEY | 09:15 | 8 kalem | ✅ Onaylandı |

Satıra tıklanınca **sipariş detayı** açılır: her kalem bir satır, **ONAY** sütunu
düzenlenebilir. Değişiklik anında kaydedilir. `0` yazılan ürün verilmedi sayılır —
üstü çizilir, Excel'e ve envantere girmez.

**📦 KALEM ENVANTERİ** — ürün bazında çıkış kaydı. Kendi **tarih aralığı** seçicisi vardır
(varsayılan bugün, en fazla 92 gün).

Düz liste, **ürün koduna göre sıralı** — gruplama yok, çünkü envanter yüzlerce satıra
çıkabilir ve kod sırası LN Infor'la karşılaştırmayı kolaylaştırır.

| KOD | ÜRÜN ADI | BR | ÇIKAN | BEKLEYEN | HAREKET |
|---|---|---|---|---|---|
| ICA01000006 | SODA SADE SISE 24 LU | kol | — | 3 | 1 |
| ICA02000001 | KOLA SISE | kol | **10** | 5 | 3 |

- **ÇIKAN** = onaylanmış siparişlerdeki onay miktarı — depodan gerçekten çıkan mal
- **BEKLEYEN** = henüz onaylanmamış talepler
- Verilmedi (`0`) işaretli kalemler envantere hiç girmez

Satıra basınca **ayrı bir sayfada** o ürünün bütün hareketleri açılır:

| OUTLET | SİPARİŞ NO | İSTENDİ | ÇIKTI | TALEP | MİKTAR | DURUM |
|---|---|---|---|---|---|---|
| **315** PAVILLION BAR | SIP-20260814-007 | 14/08 14:32 | 14/08 15:10 | 10 | **6** | ✅ çıktı |
| **316** LOBBY BAR | SIP-20260814-008 | 14/08 14:32 | — | 5 | **5** | 🟡 bekliyor |
| **201** ALIBEY REST. | SIP-20260813-001 | 13/08 09:15 | 13/08 10:40 | 4 | **4** | ✅ çıktı |

Üstte ÇIKAN / BEKLEYEN / HAREKET özet kutuları, altında hareketler yeniden eskiye sıralı.
Talep ile miktar farklıysa talep sütunu turuncu görünür. Liste ekranındaki arama kutusu
ürün adı ve koduna göre filtreler.

Talepler listesi 15 saniyede bir kendini yeniler. Tarih seçiciyle geçmiş günlere bakılır.

## Dosyalar

| Dosya | İçerik |
|---|---|
| `index.html` | İki sayfaya yönlendiren kapak |
| `bar.html` | Sipariş girişi |
| `depo.html` | Talep listesi + sipariş detayı + kalem envanteri + ürün hareketleri |
| `ortak.js` | **Excel üretimi** + onaylanan miktar mantığı + Supabase istemcisi |
| `mutfak.js` | Mutfak katalogu (`MUTFAK_LISTE` bölümler, `M` mutfaklar) — *otomatik üretildi* |
| `veri.js` | Bar ürün kataloğu (`D`), Excel şablonu (`TPL_B64`), satır şablonu (`ROW2`), grup renkleri (`GC`) — *otomatik üretildi* |
| `stil.css` | Ortak stiller |
| `config.js` | Supabase adresi ve anon key |
| `kurulum.sql` | İlk kurulum — bir kez |
| `guncelleme-01.sql` | Sipariş no + depo düzeltme/onay — bir kez |
| `guncelleme-02.sql` | Kalem envanteri (tarih aralığı sorgusu) — bir kez |
| `guncelleme-03.sql` | Mutfaklar: CMM kodları + bölüm — bir kez |

Excel üretimi `ortak.js` içinde tek `buildExcelBlob()` fonksiyonundadır. Eski tek dosyalık
sürümde aynı kurgu iki ayrı kopya halindeydi; artık bar da depo da aynı kodu çağırır.

## Kurulum

### 1. Supabase

Supabase panelinde **SQL Editor → New query**, sırayla:

1. `kurulum.sql` — içindeki `BURAYA_SIFRE_YAZ` yerine depo şifreni yaz → **Run**
2. `guncelleme-01.sql` → **Run**  *(şifreni değiştirmez, mevcut veriyi korur)*
3. `guncelleme-02.sql` → **Run**  *(kalem envanteri için `depo_envanter` fonksiyonu)*
4. `guncelleme-03.sql` → **Run**  *(mutfak kodları ve bölüm desteği)*

Şifreyi sonra değiştirmek için `kurulum.sql` içindeki `insert into public.ayarlar ...`
satırını yeni şifreyle tekrar çalıştırman yeterli.

### 2. GitHub Pages

Repo **public** olmalı (ücretsiz hesapta Pages private repo'da yayınlanmaz).
**Settings → Pages → Deploy from a branch → main / (root)**.

## Güvenlik

`config.js` içindeki anon key tarayıcıda açıktadır — Supabase'de bu **tasarım gereğidir**.
Korumayı veritabanı sağlar:

- `siparisler` ve `ayarlar` tablolarında RLS açık ve **hiçbir policy yok** → anon key ile
  bu tablolara doğrudan erişilemez. (Canlı doğrulandı: `permission denied for table siparisler`)
- Tüm erişim `SECURITY DEFINER` fonksiyonlarından geçer:
  - `siparis_gonder` — bar/mutfak sipariş yazar, numara üretilir (CSM veya CMM kodu ve kalem listesi doğrulanır)
  - `depo_liste` — şifre doğruysa o günün siparişlerini döner
  - `depo_envanter` — şifre doğruysa tarih aralığındaki siparişleri döner (en fazla 92 gün)
  - `depo_kalem_guncelle` — şifre ister, kilitli siparişte çalışmaz
  - `depo_durum_degistir` — onaylar / kilidi açar
- Depo şifresi bcrypt ile saklanır, doğrulama sunucuda yapılır.

Bilinen ve kabul edilmiş sınır: **bar kodu bir şifre değildir.** `201`, `315` gibi kodlar
tahmin edilebilir ve doğrulama tarayıcıda yapılır — amacı personeli doğru outlet'e
yönlendirmektir. Gerçek koruma isteniyorsa `siparis_gonder` fonksiyonuna sunucu tarafında
doğrulanan bir bar şifresi eklenmelidir.

## Bar tarafı ayrıntılar

- Her miktar girişi tarayıcıya taslak olarak yazılır; telefon kilitlenir ya da sayfa
  yenilenirse girilenler kaybolmaz. Taslak sadece o güne aittir, gönderilince silinir.
- Gönderilmemiş değişiklikle sayfadan çıkılmak istenirse tarayıcı uyarır.
- İnternet yoksa ekran çalışmaya devam eder, miktarlar taslakta durur.

## Katalog güncellemesi

Ürün listesi değişirse `veri.js` içindeki `const D = [...]` satırı yenisiyle değiştirilir.
Dosyanın geri kalanına (`TPL_B64`, `ROW2`, `GC`) dokunulmaz.

## Bakım notu

Düzeltilen hata: ürün adındaki `&` karakteri XML'e kaçışlanmadan yazılıyordu. Katalogda
`&` içeren 5 ürün var (`ICE TEA MANGO&ANANAS`, `KOKTEYL MIX PETBUER&ALMON`,
`CHIWAS SMOOTH&SMOKY 70CL`, `CHIWAS SMOOTH&SMOKY 100 CL`, `TEQUILA SIP&SIP`). Bunlardan
biri siparişe girildiğinde eski sürüm bozuk `.xlsx` üretiyor, Excel dosyayı açmıyordu.
