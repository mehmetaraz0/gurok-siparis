# Kaptan Bazlı Bar Girişi — Tasarım

**Tarih:** 2026-08-18
**Sorun:** Bar girişi şu an "bar (outlet) kodu + o bara ait PIN" ile yapılıyor; her PIN bir kişi = gönderen. Ama **kaptanlar sabit bir barda durmuyor**, barlar arası geziyor. Bara bağlı PIN modeli kaptanlar için işlemiyor.

## Amaç

Bar girişini **kişi (kaptan) bazlı** yap: kaptan kendi kimliğiyle girer, sipariş vereceği barı seçer. Kimlik (kaptan) ile yer (bar) ayrılır. Depoda "hangi kaptan hangi bara" görünür. **Mutfak tarafı hiç değişmez.**

## Kararlar (kullanıcı onayı)

- Kaptan kendi şifresiyle girer → barı **her siparişte** listeden seçer.
- Gönderen kimliği **zorunlu** (depoda kaptan adı görünür).
- Her barın **kendi ürün listesi** var → bar seçilince o barın kataloğu yüklenir.
- Kaptan **tüm barlara** sipariş verebilir (kısıt yok).
- Giriş: **kaptan adını listeden seç + PIN** (öneri). Alternatif: kaptan kodu + PIN.

## Mimari

### 1. Yeni `kaptan` tablosu
```
kaptan (kod text pk, ad text not null, pin text not null /*bcrypt*/, aktif boolean default true)
```
- RLS açık, policy yok, anon/authenticated'dan revoke (diğer tablolar gibi).
- `kod` = kısa giriş kimliği (ör. K01); `ad` = depoda görünen gönderen; `pin` = `extensions.crypt(...,gen_salt('bf'))`.

### 2. RPC'ler (hepsi security definer, search_path=public,extensions)
- **`kaptan_liste_ac()`** (public, şifresiz) → `[{kod, ad}]` yalnız `aktif` olanlar, **PIN dönmez**. Giriş ekranındaki isim listesi için. *(Not: kaptan adları görünür olur; iç sistem için kabul, PIN yine şart.)*
- **`kaptan_giris(p_kod text, p_pin text)`** → PIN doğruysa `{ok, kod, ad}`, değilse `raise`. Girişte kimlik + bar seçim ekranını açmak için.
- **Admin (admin_dogru şifresi):** `kaptan_liste(p_sifre)` → `[{kod, ad, aktif}]` (PIN yok); `kaptan_ekle(p_sifre, p_kod, p_ad, p_pin)`; `kaptan_sil(p_sifre, p_kod)`.
- Grant execute → anon (kaptan_liste_ac, kaptan_giris, kaptan_ekle, kaptan_sil, kaptan_liste).

### 3. `siparis_gonder` sunucuda ayrışır (köprü sağlam kalır)
Yeni parametreler: `p_kaptan_kod text default null`, `p_kaptan_pin text default null`.
- Outlet `tur` okunur (`select tur from outletler where kod=p_outlet_kod`).
- **tur='bar'** → **kaptan doğrulaması ZORUNLU**: `p_kaptan_kod`+`p_kaptan_pin` `kaptan` tablosunda `aktif` ve PIN doğru olmalı; değilse `raise`. `gonderen = kaptan.ad` (sunucu belirler, client'a güvenilmez). outlet_pin bar için kullanılmaz.
- **tur='mutfak'** → **eskisi gibi** outlet_pin akışı (mutfak hiç değişmez). Eski client (kaptan paramsız) mutfakta çalışmaya devam eder.
- Diğer tüm kontroller (allowlist, kalem deseni, katalog üyeliği, hız sınırı, idempotency) **aynen** kalır.

### 4. bar.html akışı
**Giriş ekranı — tek ekranda iki net yol:**
- **① Kaptan girişi (barlar):** kaptan adı `<select>` (kaptan_liste_ac ile dolu) + PIN → `kaptan_giris`. Başarılıysa kaptan `sessionStorage`'a yazılır (`gurok_kaptan_kod`, `gurok_kaptan_pin`, `gurok_kaptan_ad`) → **bar seçim ekranı** açılır.
- **② Mutfak girişi (değişmez):** mevcut kod kutusu (CMM…/M…) + PIN → bölüm seç → sipariş. Kaptan kavramı mutfağa uygulanmaz.

**Bar seçim ekranı (yeni):** kaptan girişi sonrası tüm barlar (client'taki `D` listesi) düğme olarak listelenir → seçilen bar `birimAc` ile açılır, o barın kataloğu (`katalog_getir(barKod)`, gömülü fallback) yüklenir.

**Sipariş gönderimi:** bar için her `siparis_gonder` çağrısına `p_kaptan_kod`+`p_kaptan_pin` eklenir; `gonderen`'i sunucu kaptan adından belirler. Mutfak akışı eski PIN'i gönderir (değişmez).

**Bar değiştir:** "↔ Birim Değiştir" bar seçim ekranına döner (kaptan girişi korunur, yeniden giriş yok).

### 5. admin.html — "Kaptanlar" paneli
Mevcut outlet-PIN paneli gibi: kaptan listesi (kod, ad, aktif) + ekle (kod, ad, PIN) + sil. `kaptan_*` RPC'lerini kullanır.

### 6. Depo tarafı
**Değişmez.** `gonderen` zaten siparişe yazılıyor (artık kaptan adı), outlet zaten barı gösteriyor. 👤 tag ve TÜKETİM/çıkış Excel'i aynen çalışır.

## Geçiş / geri-uyum
- Mutfak PIN'leri (`outlet_pin`, tur='mutfak') aynen kalır.
- Barların eski `outlet_pin` kayıtları artık kullanılmaz (silmeye gerek yok; siparis_gonder bar için onlara bakmaz).
- **Kırıcı:** yeni `siparis_gonder` + `kaptan` tablosu canlıya çıkmadan yeni bar.html hata verir → `kurulum.sql` bir kez daha çalıştırılmalı; SQL ile bar.html **birlikte** yayınlanır.
- İlk kaptanlar admin panelinden (veya seed SQL ile) eklenir.

## Kapsam dışı (YAGNI)
- Kaptana bar atama (hepsi tüm barlara erişir).
- Kaptan rolleri/yetki seviyeleri.
- Mutfak tarafını kaptan modeline taşıma.

## Riskler
- **Roster görünürlüğü:** `kaptan_liste_ac` isimleri açık verir. İç sistem için kabul; istenirse kaptan-kodu+PIN'e dönülür (küçük değişiklik).
- **Deneme sınırı:** kaptan PIN'inde brute-force sınırı yok (mevcut outlet PIN'inde de yoktu). Gerekirse ayrı iş.
- **tur doğruluğu:** bir bar yanlışlıkla tur='mutfak' ise kaptan zorunluluğu atlanır → outletler.tur doğru olmalı (kurulumda garanti).
