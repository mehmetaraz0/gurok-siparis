# GUROK Sipariş Sistemi

ALI BEY CLUB MANAVGAT — 22 bar + 3 mutfak, LN Infor Excel çıktısı.

Barlar ve mutfaklar talep gönderir, depo düzeltip onaylar, Excel onaylanmış miktarlarla iner.

| Sayfa | Kim kullanır | Ne yapar |
|---|---|---|
| `bar.html` | Bar ve mutfak personeli | **Kodunu girer** (bar `B315`, mutfak `M201`), miktar girer, **Siparişi Gönder** |
| `depo.html` | Depo sorumlusu | Şifreyle girer, talepleri düzeltir, onaylar, Excel indirir |

## Akış

```
BAR                          DEPO
───                          ────
kod gir (B315)
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

Mutfak listeleri **kategorilere** ayrılır — PEYNİRLER, SÜT & YOĞURT, ŞARKÜTERİ & ET,
DENİZ ÜRÜNLERİ, ŞOKLU & DONUK, UN & HAMUR İŞİ, KURU GIDA & BAKLİYAT, YAĞLAR, ZEYTİNLER,
KONSERVE & SALÇA, BAHARAT & SOS, REÇEL & TAHİN, PASTANE MALZEMESİ, DONDURMA, İÇECEK,
ELDİVEN & SAĞLIK, AMBALAJ & FOLYO, PEÇETE & SERVİS, KIRTASİYE.

Kategori, ürün kodunun ilk beş hanesinden türetilir (`YIY03` → PEYNİRLER). Tek istisna
`YIY11`: 149 kalemle çok büyük ve içi karışık olduğu için ürün adına bakılarak dörde
ayrılır. LN Infor adlandırması "ANA ÜRÜN + detay" olduğundan ilk kelime belirleyicidir —
`YAG ZEYTIN SIZMA` yağlara, `ZEYTIN YESIL KIRMA` zeytinlere gider.

Aynı listeyi kullanan M201 ve M204'ün taslakları ve siparişleri birbirinden bağımsızdır.

**Henüz eklenmedi** — ürün listesi geldiğinde eklenecek:
`CMM201 → SAHİL KAHVALTI`, `CMM201 → SAHİL PIZZA`, `CMM203 Personel Mutfağı`,
`CMM205 Club Lojman Personel Yemekhanesi`

## Bar kodları

Barlar **B**, mutfaklar **M** ile başlar. Örnek kodlar giriş ekranında **gösterilmez** —
personel kendi kodunu bilerek girer.

| Kod | Bar | | Kod | Bar |
|---|---|---|---|---|
| **B201** | ALIBEY RESTAURANT | | **B308** | KARAGOZ |
| **B202** | PARK RESTAURANT | | **B310** | ILICA BAR |
| **B204** | SAHIL RESTAURANT | | **B311** | HARLEK |
| **B205** | AQUA RESTAURANT | | **B312** | HISAR |
| **B206** | KIYI RESTAURANT | | **B313** | YONCALI |
| **B301** | TURK KAHVESI | | **B314** | FRIG BEACH BAR |
| **B302** | CARDAK | | **B315** | PAVILLION BAR |
| **B303** | TALVAR | | **B316** | LOBBY BAR |
| **B304** | POOL | | **B317** | PARK TURK KAHVESI |
| **B305** | ALI'S PUB | | **B318** | SARAP VE BIRA EVI |
| **B306** | TENIS BAR | | | |
| **B307** | KONAK | | | |

`B315`, `csm315`, `CSM315` yazımlarının hepsi kabul edilir (bare `315` artık kabul edilmez).
Kod sekme oturumunda tutulur; sayfa yenilenince sorulmaz, sekme kapanınca sorulur.
**↔ Birim Değiştir** ile koda dönülür.

## Depo ekranı

**📋 TALEPLER** — gelen siparişler alt alta, her satır bir sipariş:

| SİPARİŞ NO | BAR | SAAT | KALEM | DURUM |
|---|---|---|---|---|
| SIP-20260814-007 | B315 PAVILLION BAR | 14:32 | 12 kalem · *2 düzeltildi* | 🟡 Talep |
| SIP-20260814-006 | B201 ALIBEY | 09:15 | 8 kalem | ✅ Onaylandı |

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
| **B315** PAVILLION BAR | SIP-20260814-007 | 14/08 14:32 | 14/08 15:10 | 10 | **6** | ✅ çıktı |
| **B316** LOBBY BAR | SIP-20260814-008 | 14/08 14:32 | — | 5 | **5** | 🟡 bekliyor |
| **B201** ALIBEY REST. | SIP-20260813-001 | 13/08 09:15 | 13/08 10:40 | 4 | **4** | ✅ çıktı |

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
| `guncelleme-04.sql` | Güvenlik: kalem/miktar doğrulaması + çöp kayıt temizliği — bir kez |
| `guncelleme-05.sql` | Kod incelemesi: kod deseni zorlaması + idempotent gönderim + numara boşluğu — bir kez |

Excel üretimi `ortak.js` içinde tek `buildExcelBlob()` fonksiyonundadır. Eski tek dosyalık
sürümde aynı kurgu iki ayrı kopya halindeydi; artık bar da depo da aynı kodu çağırır.

## Kurulum

### 1. Supabase

Supabase panelinde **SQL Editor → New query**, sırayla:

1. `kurulum.sql` — içindeki `BURAYA_SIFRE_YAZ` yerine depo şifreni yaz → **Run**
2. `guncelleme-01.sql` → **Run**  *(şifreni değiştirmez, mevcut veriyi korur)*
3. `guncelleme-02.sql` → **Run**  *(kalem envanteri için `depo_envanter` fonksiyonu)*
4. `guncelleme-03.sql` → **Run**  *(mutfak kodları ve bölüm desteği)*
5. `guncelleme-04.sql` → **Run**  *(girdi doğrulaması; test çöp kayıtlarını da temizler)*
6. `guncelleme-05.sql` → **Run**  *(bar.html bu olmadan sipariş gönderemez — `p_istemci_id` parametresi bunda tanımlı)*

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

Bilinen ve kabul edilmiş sınır: **bar/mutfak kodu bir şifre değildir.** `201`, `M201` gibi
kodlar tahmin edilebilir ve doğrulama tarayıcıda yapılır — amacı personeli doğru birime
yönlendirmektir. Gerçek koruma isteniyorsa `siparis_gonder` fonksiyonuna sunucu tarafında
doğrulanan bir kod/şifre eklenmelidir.

**Sızma testi (canlı sistemde yapıldı):** Doğrudan tablo erişimi (SELECT/INSERT/UPDATE/DELETE),
şifre hash'i okuma, şifresiz onaylama, SQL injection ve API şeması listeleme denemelerinin
**hepsi engellendi**. `guncelleme-04.sql` ile ayrıca girdi doğrulaması sıkılaştırıldı: artık
negatif, sıfır, kesirli veya eksik miktarlı kalem kabul edilmiyor.

**Supabase panelinde kapatılması önerilen:** Authentication → Providers → Email → *"Allow new
users to sign up"* kapatılmalı. Sisteme kullanıcı hesabı gerekmiyor; açık kalması bir veri
riski yaratmıyor (authenticated role'ün de tablo izni yok) ama gereksiz açık uçtur.
*(Yapıldı ve doğrulandı: signup_disabled.)*

**Kod incelemesi düzeltmeleri (guncelleme-05 + istemci):**
- **XSS (Critical):** Depo envanter satırı ürün kodunu inline `onclick`'e gömüyordu; kod
  anon RPC ile yazılabildiği için depo şifresini çalabilecek bir XSS vektörüydü. Satır artık
  `data-kod` + event delegation kullanıyor; ayrıca sunucu kalem kodunu `^[A-Z]{3}[0-9]{8}$`
  desenine zorluyor (tüm 878 katalog kodu bu desene uyuyor).
- **Mükerrer sipariş (Important):** Ağ koptuğunda tekrar gönderim ikinci sipariş üretiyordu.
  Artık her gönderim bir istemci kimliği taşıyor; sunucu aynı kimliği tekrar görürse var olan
  siparişi döndürür, yeni açmaz.
- **Onay düzenlemesi silinmesi (Important):** 15 sn'lik otomatik yenileme, depo bir siparişi
  düzenlerken input'u yeniden çizip girilen miktarı eskisine döndürebiliyordu. Otomatik
  yenileme artık sipariş detayı açıkken redraw yapmıyor.
- **Numara boşluğu (Minor):** Sıra numarası `count+1` yerine `max+1`; kayıt silinse bile
  çakışıp gün boyu sipariş açılamaması durumu ortadan kalktı.
- **Not (kabul edilen):** Depo şifresine kaba-kuvvet denemesi için hız sınırı yoktur; koruma
  yalnızca bcrypt maliyetidir. **Uzun ve rastgele bir depo şifresi kullanılması önerilir.**

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
