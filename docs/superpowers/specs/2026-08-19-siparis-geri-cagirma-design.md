# Sipariş Geri Çağırma — Tasarım

**Tarih:** 2026-08-19
**Sorun:** Sipariş gönderildikten sonra kaptan hiçbir düzeltme yapamıyor. Yanlış miktar
veya yanlış ürün gönderildiğinde tek çare depoyu aramak. Depo yalnızca `talep`
aşamasında kalem miktarını düzeltebiliyor; kaptanın hiçbir yetkisi yok.

## Amaç

Kaptan, **depo henüz onaylamamışsa** kendi biriminin siparişini geri çağırabilsin:
ya düzeltip yeniden göndersin ya da tamamen iptal etsin.

## Kararlar (kullanıcı onayı)

- Geri çağırma **hem düzeltme hem iptal** sağlar (iki buton, tek sunucu işlemi).
- **O birimdeki herkes** geri çağırabilir — vardiya değişiminde takılma olmasın.
- Yalnızca **`durum='talep'`** ve **aynı gün** sipariş geri çağrılabilir.
- Onaylanmış sipariş geri çağrılamaz (stok düşmüş, Excel alınmış olabilir) → depo kilidi açar.

## Veri modeli

```
siparisler.durum:  'talep' | 'onaylandi' | 'iptal'      (check constraint güncellenir)
siparisler.iptal_saati  timestamptz
siparisler.iptal_eden   text        -- iptal eden kaptanın adı (sunucu belirler)
```

Kayıt **silinmez**; iz kalır. Sipariş numarası boşa gider (SIP-…-003 iptalse sıradaki 004) —
numara üretimi `max(split_part)+1` olduğu için çakışma olmaz, yalnız numara atlanır.

## Sunucu (kurulum.sql)

### `siparis_geri_cagir(p_siparis_no, p_kaptan_kod, p_kaptan_pin)` → `{ok, kalemler}`
1. Kaptan doğrulanır (aktif + PIN; kilitliyse kilit mesajı) — mevcut desen.
2. Sipariş bulunur; **bugüne ait** değilse ret.
3. Kaptanın departmanı ile siparişin outlet türü uyumlu olmalı (mevcut departman kuralı).
4. **Atomik iptal:**
   ```sql
   update siparisler set durum='iptal', iptal_saati=now(), iptal_eden=v_ad
    where siparis_no = p_siparis_no and durum = 'talep'
   returning kalemler into v_kalemler;
   if not found then raise exception 'Bu siparis artik geri cagirilamaz'; end if;
   ```
   `where durum='talep'` koşulu yarış durumunu çözer: depo aynı anda onaylıyorsa
   hangisi önce davranırsa o kazanır, diğeri net hata alır.
5. `kalemler` döner — client düzeltme akışında ekrana geri yükler.

### `bekleyen_siparisler(p_outlet_kod, p_bolum, p_kaptan_kod, p_kaptan_pin)` → `[…]`
O birimin **bugünkü** siparişleri: `siparis_no, saat, kalem_sayisi, durum, gonderen`.
Kaptan doğrulaması ister. `iptal` olanlar dönmez.

### Mevcut fonksiyonlarda kapatılan açık
`depo_durum_degistir` ve `depo_kalem_guncelle` şu an yalnız `onaylandi` durumunu
kontrol ediyor. İptal edilmiş bir sipariş bu haliyle onaylanabilir ve
**stok düşmeden `durum='onaylandi'` olur** (tutarsızlık). Her ikisine
`durum='iptal'` reddi eklenir. `depo_liste` iptalleri dışlar.

## İstemci (bar.html)

**"BUGÜN GÖNDERDİKLERİNİZ" listesi sunucudan beslenir.** Bugüne kadar yalnızca
`localStorage`'daydı; bu yüzden başka kaptanın gönderdiği sipariş görünmüyordu ve
durumu bilinmiyordu. Her satır:

```
SIP-20260819-003 · 14:22 · 25 kalem · 👤 KADER VARAŞLI
  ⏳ Bekliyor   [↩ Düzelt] [🗑 İptal]
  ✓ Onaylandı   (buton yok)
```

- **↩ Düzelt** → `siparis_geri_cagir` → dönen kalemler `Q`'ya yüklenir, ekran çizilir,
  taslak yazılır; kullanıcı düzeltip normal akışla yeniden gönderir (yeni numara).
- **🗑 İptal** → `siparis_geri_cagir` → ekran boş kalır.
- Her ikisi de onay kutusu (`confirm`) ister.
- Ağ hatası / RPC yoksa yerel makbuz listesi gösterilmeye devam eder (geri-uyum).

Geri çağırma butonları **data-\*** + delegasyon ile bağlanır (inline `onclick` yok —
mevcut güvenlik kararı).

## Etkilenmeyenler

Tüketim raporu, kalem envanteri ve tüm Excel çıktıları zaten `durum='onaylandi'`
filtreliyor → iptaller hiçbirine karışmaz. Stok hareketleri yalnız onayda oluşuyor →
iptal edilen sipariş stoğa dokunmaz.

## Kapsam dışı (YAGNI)

- Onaylanmış siparişi kaptanın geri alması (depo kilidi açar — mevcut akış yeterli).
- Dünkü siparişleri geri çağırma.
- İptal gerekçesi girme.
- Depo tarafında iptal listesi/raporu.

## Riskler

- **Geri-uyum:** yeni RPC'ler; SQL uygulanmadan yeni client'ta geri çağırma butonu
  hata verir → liste yerel makbuza düşer, sipariş gönderimi etkilenmez.
- **Numara atlaması** normaldir (iptal edilen numara tekrar kullanılmaz).
- Depo o an ekranda açıksa iptal edilen sipariş yenileyene kadar listede kalır;
  onaylamaya kalkarsa sunucu reddeder.
