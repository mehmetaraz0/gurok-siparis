# Teslim Onayı / İtiraz — Tasarım

**Tarih:** 2026-08-22
**Sorun:** Depo "ONAYLA ve KİLİTLE" ile siparişi tek taraflı kapatıyor. Depo miktarı
düşürdüyse (bar 12 istedi, 8 verildi) ya da yanlış yazdıysa kaptanın bunu görmesinin
veya itiraz etmesinin yolu yok. Bar yalnızca "✓ Onaylandı" rozetini görüyor —
hangi miktarların onaylandığını değil.

## Amaç

Depo onayından sonra kaptan **ne verildiğini kalem kalem görsün**, teslim aldığını
onaylasın ya da itiraz etsin. İtiraz depoda görünür olsun.

## Karar (kullanıcı onayı)

**Teslim aldım / itiraz modeli.** Depo onayı iş akışını durdurmaz (mal çıkar, stok düşer);
kaptanın onayı bunun *üstüne* bir mutabakat katmanıdır.

## Akış

1. Bar sipariş gönderir → `talep`
2. Depo miktarları düzeltir, onaylar → `onaylandi`, stok düşer *(mevcut, değişmiyor)*
3. **YENİ:** Kaptan "👁 Ne verildi?" ile istenen/verilen karşılaştırmasını görür
4. **✓ Teslim aldım** ya da **⚠ Eksik/Yanlış** (kısa not)
5. İtiraz depoda kırmızı görünür → depo kilidi açıp düzeltir *(mevcut akış)*

## Veri modeli

```
siparisler.teslim_durum   text          -- null | 'alindi' | 'itiraz'
siparisler.teslim_saati   timestamptz
siparisler.teslim_eden    text          -- kaptan adı (sunucu belirler)
siparisler.teslim_not     text          -- itiraz notu (en fazla 200 karakter)
```

## Sunucu (kurulum.sql)

### `siparis_teslim(p_siparis_no, p_durum, p_not, p_kaptan_kod, p_kaptan_pin)`
1. Kaptan doğrulanır (aktif + PIN; kilit kontrolü) — mevcut desen.
2. `p_durum` yalnız `'alindi'` veya `'itiraz'` olabilir.
3. Sipariş **bugüne ait** ve **`durum='onaylandi'`** olmalı; değilse ret
   ("Once depo onaylamali").
4. Kaptanın departmanı ile outlet türü uyumlu olmalı (mevcut departman kuralı).
5. `teslim_durum/saati/eden/not` yazılır. Tekrar çağrılırsa üzerine yazar
   (kaptan fikrini değiştirebilir: itiraz → teslim aldım).

### Değişen mevcut davranış
- `depo_durum_degistir`: **kilit açıldığında** (`onaylandi → talep`) teslim alanları
  **sıfırlanır**. Depo düzeltme yapacaksa kaptanın önceki onayı geçersizdir.
- `bekleyen_siparisler`: artık `kalemler` ve `teslim_durum/eden/not` de döner
  (kaptan detayı görebilsin).
- `depo_liste`: `teslim_durum/eden/not` döner.

## İstemci

**bar.html** — "BUGÜN GÖNDERDİKLERİNİZ" listesinde onaylanmış siparişte:
- **👁 Ne verildi?** → satır altında kalem tablosu: `istenen → verilen`,
  farklı/verilmeyen kalemler kırmızı işaretli
- **✓ Teslim aldım** / **⚠ Eksik/Yanlış** (not `prompt` ile, boş geçilebilir)
- Sonuç rozeti: `✓ Teslim alındı 14:30 · KADER VARAŞLI` veya `⚠ İtiraz · <not>`
- Butonlar `data-*` + delegasyon (mevcut güvenlik kararı)

**depo.html** — talep listesinde ve detayda teslim rozeti; **itiraz kırmızı**.

## Etkilenmeyenler

Stok hareketleri, Excel çıktıları, tüketim raporu ve envanter **değişmez** —
teslim onayı yalnızca mutabakat kaydıdır, hiçbir hesaba girmez.

## Kapsam dışı (YAGNI)

- İtiraz sonrası otomatik düzeltme ya da bildirim
- İtiraz geçmişi/çoklu itiraz kaydı (tek alan, üzerine yazılır)
- Dünkü siparişlere teslim onayı
- Depo tarafında itiraz yanıtlama alanı

## Riskler

- **Geri-uyum:** yeni RPC; SQL uygulanmadan buton hata verir, liste ve sipariş
  gönderimi etkilenmez.
- `bekleyen_siparisler` artık kalemleri de döndürüyor → yanıt büyür. Bir birimde
  günde ~5 sipariş × ~30 kalem olduğu için kabul edilebilir.
