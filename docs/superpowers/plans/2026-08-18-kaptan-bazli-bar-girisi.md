# Kaptan Bazlı Bar Girişi — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bar girişini "bar+PIN" yerine "kaptan+PIN → bar seç" yaparak, sabit bir barda durmayan kaptanların tüm barlara kendi kimlikleriyle sipariş vermesini sağlamak; mutfak tarafını hiç değiştirmemek.

**Architecture:** Yeni `kaptan` tablosu + RPC'ler kimliği outlet'ten ayırır. `siparis_gonder` outlet `tur`'una göre ayrışır (bar→kaptan zorunlu, mutfak→eski PIN). bar.html'e kaptan giriş + bar seçim ekranı, admin.html'e Kaptanlar paneli eklenir.

**Tech Stack:** Supabase Postgres (SECURITY DEFINER RPC + bcrypt), vanilla JS, Node (libpg-query SQL doğrulama), tarayıcı duman testi.

## Global Constraints

- Türkçe arayüz/mesajlar. Tüm yeni RPC'ler `security definer set search_path = public, extensions`.
- Admin RPC'leri başında `if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;`.
- PIN saklama: `extensions.crypt(pin, extensions.gen_salt('bf'))`; doğrulama: `pin = extensions.crypt(girilen, pin)`. PIN deseni `^[0-9]{3,12}$`.
- Kaptan `kod` deseni `^[A-Za-z0-9]{1,10}$`; `ad` ≤ 60 char.
- Yeni tablo: RLS açık, policy yok, `revoke all ... from anon, authenticated`. Erişim yalnız RPC ile.
- `siparis_gonder` geri-uyum: yeni parametreler **default null**; PostgREST adlı-parametreyle çağırdığı için eski 6-arg (mutfak) çağrıları 8-arg fonksiyona düşer.
- SQL değişiklikleri `libpg-query` ile parse-doğrulanır. Canlıda `kurulum.sql` + bar.html/admin.html **birlikte** yayınlanır (yoksa bar girişi hata verir).
- Outlet `tur`: 'bar' | 'mutfak' (`outletler.tur`). Client bar listesi = `veri.js`'teki `D` (`[{c,n,i}]`).

---

## Task 1: SQL — `kaptan` tablosu + kaptan RPC'leri

**Files:**
- Modify: `kurulum.sql` — tablo bloğuna (`outlet_pin`'den sonra ~78) `kaptan` tablosu; RLS bloğuna (~116-123) revoke; admin RPC bölümüne (~833) kaptan RPC'leri; grant bloğu (~859 sonrası).
- Test: `scratchpad/validate-sql.js` (libpg-query)

**Interfaces:**
- Produces:
  - `kaptan_liste_ac()` → `[{kod, ad}]` (aktif olanlar, PIN yok — public)
  - `kaptan_giris(p_kod text, p_pin text)` → `{ok, kod, ad}` veya raise
  - `kaptan_liste(p_sifre text)` → `[{kod, ad, aktif}]` (admin, PIN yok)
  - `kaptan_ekle(p_sifre text, p_kod text, p_ad text, p_pin text)` → `{ok}`
  - `kaptan_sil(p_sifre text, p_kod text)` → `{ok}`

- [ ] **Step 1: `kaptan` tablosunu ekle** (kurulum.sql, `outlet_pin` bloğundan sonra, ~78. satır)

```sql
-- Kaptanlar: bara bağlı DEĞİL, kişi bazlı kimlik. Kaptan kendi PIN'iyle girer,
-- sipariş vereceği barı seçer. 'ad' depoda 'gönderen' olarak görünür.
create table if not exists public.kaptan (
  kod   text primary key,
  ad    text not null,
  pin   text not null,               -- bcrypt hash
  aktif boolean not null default true
);
```

- [ ] **Step 2: RLS + revoke** (kurulum.sql RLS bloğu, diğer `enable row level security` satırlarının yanına ~116 ve revoke ~123)

```sql
alter table public.kaptan enable row level security;
revoke all on public.kaptan from anon, authenticated;
```

- [ ] **Step 3: Kaptan RPC'lerini ekle** (admin RPC bölümü, `outlet_pin_sil`'den sonra ~833)

```sql
-- ===== KAPTAN =====
-- Giriş ekranı için aktif kaptan adları (şifresiz; PIN dönmez)
create or replace function public.kaptan_liste_ac()
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('kod', kod, 'ad', ad) order by ad), '[]'::jsonb)
    from kaptan where aktif;
$$;

-- Kaptan girişi: kod + PIN doğrula
create or replace function public.kaptan_giris(p_kod text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_ad text;
begin
  select ad into v_ad from kaptan
   where kod = p_kod and aktif and pin = extensions.crypt(coalesce(p_pin,''), pin);
  if v_ad is null then raise exception 'Kaptan kodu veya PIN hatali'; end if;
  return jsonb_build_object('ok', true, 'kod', p_kod, 'ad', v_ad);
end $$;

-- Admin: kaptan listesi (PIN yok)
create or replace function public.kaptan_liste(p_sifre text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('kod', kod, 'ad', ad, 'aktif', aktif) order by ad)
    from kaptan), '[]'::jsonb);
end $$;

-- Admin: kaptan ekle/güncelle
create or replace function public.kaptan_ekle(p_sifre text, p_kod text, p_ad text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_kod,'') !~ '^[A-Za-z0-9]{1,10}$' then raise exception 'Kod 1-10 harf/rakam olmali'; end if;
  if coalesce(p_ad,'') = '' then raise exception 'Ad bos olamaz'; end if;
  if coalesce(p_pin,'') !~ '^[0-9]{3,12}$' then raise exception 'PIN 3-12 haneli sayi olmali'; end if;
  insert into kaptan (kod, ad, pin, aktif)
  values (p_kod, left(p_ad,60), extensions.crypt(p_pin, extensions.gen_salt('bf')), true)
  on conflict (kod) do update set ad = excluded.ad, pin = excluded.pin, aktif = true;
  return jsonb_build_object('ok', true);
end $$;

-- Admin: kaptan sil
create or replace function public.kaptan_sil(p_sifre text, p_kod text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  delete from kaptan where kod = p_kod;
  return jsonb_build_object('ok', true);
end $$;
```

- [ ] **Step 4: Grant'ları ekle** (grant bloğu sonuna)

```sql
grant execute on function public.kaptan_liste_ac()                                    to anon;
grant execute on function public.kaptan_giris(text, text)                             to anon;
grant execute on function public.kaptan_liste(text)                                   to anon;
grant execute on function public.kaptan_ekle(text, text, text, text)                  to anon;
grant execute on function public.kaptan_sil(text, text)                               to anon;
```

- [ ] **Step 5: libpg-query ile doğrula** — `scratchpad/validate-sql.js`

```js
const fs = require("fs");
const { parse } = require("libpg-query");
(async () => {
  try { const r = await parse(fs.readFileSync("kurulum.sql","utf8")); console.log("OK", r.stmts.length); }
  catch (e) { console.error("PARSE HATASI:", e.message); process.exit(1); }
})();
```

Run: `cd "D:/sipariş/gurok-siparis" && node scratchpad/validate-sql.js`
Beklenen: "OK N" (hata yok).

- [ ] **Step 6: Commit**

```bash
git add kurulum.sql && git commit -F <mesaj>
# mesaj: "feat: kaptan tablosu + kaptan RPC'leri (giris + admin CRUD)"
```

---

## Task 2: SQL — `siparis_gonder` tur bazlı kimlik ayrımı

**Files:**
- Modify: `kurulum.sql` — `siparis_gonder` drop satırları (226-229), imza (231-238), kimlik bloğu (250-259), grant satırı (842)
- Test: `scratchpad/validate-sql.js`

**Interfaces:**
- Consumes: `kaptan` tablosu (Task 1).
- Produces: `siparis_gonder(p_outlet_kod, p_outlet_ad, p_kalemler, p_bolum, p_istemci_id, p_pin, p_kaptan_kod, p_kaptan_pin)` — son iki param `default null`.

- [ ] **Step 1: Eski 6-arg imzayı düşür** (satır 229'a ekle — yeni 8-arg ayrı imza olduğu için eski kalırsa overload ikilemi olur)

```sql
drop function if exists public.siparis_gonder(text, text, jsonb, text, text, text);
```
(Zaten var; 226-229 blokları korunur.)

- [ ] **Step 2: İmzaya iki parametre ekle** (231-238 arası imzayı değiştir)

```sql
create or replace function public.siparis_gonder(
  p_outlet_kod  text,
  p_outlet_ad   text,               -- YOK SAYILIR (sunucu outletler'den alır)
  p_kalemler    jsonb,
  p_bolum       text default null,
  p_istemci_id  text default null,
  p_pin         text default null,
  p_kaptan_kod  text default null,
  p_kaptan_pin  text default null
)
```

- [ ] **Step 3: `declare` bloğuna `v_tur` ekle** (245-246 civarı, `v_pinvar int; v_gonderen text;` yanına)

```sql
  v_tur text;
```

- [ ] **Step 4: Kimlik bloğunu (250-259) tur bazlı yeniden yaz**

```sql
  -- 1) Outlet gerçek mi + kimlik. Bar => kaptan zorunlu; mutfak => outlet_pin (eski).
  select ad, tur into v_ad, v_tur from outletler where kod = p_outlet_kod;
  if v_ad is null then raise exception 'Gecersiz outlet'; end if;

  if v_tur = 'bar' then
    -- Kaptan bazlı kimlik: geçerli + aktif kaptan PIN'i şart. gonderen = kaptan adı.
    select ad into v_gonderen from kaptan
     where kod = p_kaptan_kod and aktif
       and pin = extensions.crypt(coalesce(p_kaptan_pin,''), pin);
    if v_gonderen is null then raise exception 'Kaptan girisi gerekli'; end if;
  else
    -- Mutfak (ve diğer): outlet_pin akışı — DEĞİŞMEDİ.
    select count(*) into v_pinvar from outlet_pin where outlet_kod = p_outlet_kod;
    if v_pinvar > 0 then
      select etiket into v_gonderen from outlet_pin
       where outlet_kod = p_outlet_kod and pin = extensions.crypt(coalesce(p_pin,''), pin) limit 1;
      if v_gonderen is null then raise exception 'PIN hatali'; end if;
    end if;
  end if;
```

- [ ] **Step 5: Grant satırını güncelle** (842)

```sql
grant execute on function public.siparis_gonder(text, text, jsonb, text, text, text, text, text) to anon;
```

- [ ] **Step 6: libpg-query ile doğrula**

Run: `node scratchpad/validate-sql.js`
Beklenen: "OK N".

- [ ] **Step 7: Commit**

```bash
git add kurulum.sql && git commit -F <mesaj>
# mesaj: "feat: siparis_gonder tur bazli kimlik (bar=kaptan, mutfak=degismedi)"
```

---

## Task 3: bar.html — kaptan giriş + bar seçim + gönderimde kaptan kimliği

**Files:**
- Modify: `bar.html` — giriş ekranı HTML (12-20), yeni bar seçim ekranı, durum globalleri (70-75), `girisYap`/yeni `kaptanGiris`, yeni `barSecimGoster`, `birimAc`/`barDegistir`, `gonder` (507-510)
- Test: tarayıcı duman testi (statik sunucu + konsol)

**Interfaces:**
- Consumes: `kaptan_liste_ac`, `kaptan_giris` (Task 1); `siparis_gonder` 8-arg (Task 2); mevcut `D` (bar listesi), `birimAc`.

- [ ] **Step 1: Giriş ekranına kaptan bloğu ekle** (12-20 arası kilit ekranına)

```html
<div class="kilit" id="kilit">
  <h2>SİPARİŞ GİRİŞİ</h2>
  <div id="kaptanGirisKutu">
    <p>Kaptan girişi</p>
    <select id="kaptanSec" class="sb"><option value="">Kaptan seçin…</option></select>
    <input type="password" id="kaptanPin" placeholder="PIN" autocomplete="off" maxlength="12" inputmode="numeric">
    <button id="kaptanBtn" onclick="kaptanGiris()">Devam</button>
    <div class="err" id="kaptanHata"></div>
  </div>
  <hr style="margin:16px 0;opacity:.3">
  <p>Mutfak birim kodu</p>
  <input type="text" id="kod" placeholder="Kod" autocomplete="off" maxlength="6">
  <input type="password" id="pin" placeholder="PIN" autocomplete="off" maxlength="12" inputmode="numeric" style="display:none">
  <button id="girisBtn" onclick="girisYap()">Devam</button>
  <div class="err" id="kodHata"></div>
</div>
```

- [ ] **Step 2: Bar seçim ekranı HTML'i ekle** (bolumEkran'dan sonra)

```html
<div class="kilit" id="barEkran" style="display:none">
  <h2 id="barBaslik">BAR SEÇ</h2>
  <p id="kaptanAdEt">—</p>
  <div id="barButonlar"></div>
  <button class="cb" style="margin-top:14px" onclick="kaptanaCik()">← Kaptan çıkışı</button>
</div>
```

- [ ] **Step 3: Global durum ekle** (70-75 civarı)

```js
let KAPTAN = null;     // {kod, ad, pin} — bar girişi kaptan kimliği (mutfakta null)
```

- [ ] **Step 4: Kaptan listesini yükle + `kaptanGiris` + `barSecimGoster`**

```js
// Sayfa açılışında aktif kaptanları doldur (kilit ekranındaki select)
async function kaptanlariYukle() {
  try {
    const { data, error } = await SB.rpc("kaptan_liste_ac");
    if (error || !data) return;
    const sel = document.getElementById("kaptanSec");
    sel.innerHTML = '<option value="">Kaptan seçin…</option>' +
      data.map(k => '<option value="' + htmlEsc(k.kod) + '">' + htmlEsc(k.ad) + '</option>').join("");
  } catch (e) { /* offline: kaptan girişi kullanılamaz, mutfak kod girişi çalışır */ }
}

async function kaptanGiris() {
  const err = document.getElementById("kaptanHata");
  const kod = document.getElementById("kaptanSec").value;
  const pin = document.getElementById("kaptanPin").value.trim();
  if (!kod) { err.textContent = "Kaptan seçin."; return; }
  if (!pin) { err.textContent = "PIN girin."; return; }
  try {
    const { data, error } = await SB.rpc("kaptan_giris", { p_kod: kod, p_pin: pin });
    if (error) { err.textContent = "Kaptan veya PIN hatalı."; return; }
    KAPTAN = { kod: kod, ad: data.ad, pin: pin };
    sessionStorage.setItem("gurok_kaptan_kod", kod);
    sessionStorage.setItem("gurok_kaptan_pin", pin);
    sessionStorage.setItem("gurok_kaptan_ad", data.ad);
    err.textContent = "";
    barSecimGoster();
  } catch (e) { err.textContent = "Bağlantı hatası."; }
}

function barSecimGoster() {
  document.getElementById("kilit").style.display = "none";
  document.getElementById("bolumEkran").style.display = "none";
  document.getElementById("ana").style.display = "none";
  document.getElementById("barEkran").style.display = "";
  document.getElementById("kaptanAdEt").textContent = "Kaptan: " + (KAPTAN ? KAPTAN.ad : "");
  document.getElementById("barButonlar").innerHTML = D.map(o =>
    '<button class="bolum-btn" onclick="barSec(' + JSON.stringify(o).replace(/"/g,"&quot;") + ')">'
    + htmlEsc(kisaKod(o.c)) + ' — ' + htmlEsc(o.n) + '</button>').join("");
}

async function barSec(o) {
  sessionStorage.setItem("gurok_birim", o.c);
  document.getElementById("barEkran").style.display = "none";
  await birimAc({ c: o.c, n: o.n, i: o.i, bl: null });
}

function kaptanaCik() {
  KAPTAN = null;
  ["gurok_kaptan_kod","gurok_kaptan_pin","gurok_kaptan_ad"].forEach(k => sessionStorage.removeItem(k));
  document.getElementById("barEkran").style.display = "none";
  document.getElementById("ana").style.display = "none";
  document.getElementById("kilit").style.display = "";
}
```

- [ ] **Step 5: `girisYap` bar dalını kaptan girişine yönlendir** (149-153: bar tipinde artık uyar)

```js
  if (c.tip === "bar") {
    document.getElementById("kodHata").textContent =
      "Bar girişi artık KAPTAN ile yapılır — yukarıdan kaptanınızı seçip PIN girin.";
    return;
  }
```
(Mutfak dalı 154-158 aynı kalır.)

- [ ] **Step 6: `barDegistir` bar seçim ekranına dönsün**

```js
function barDegistir() {
  if (KAPTAN) { barSecimGoster(); return; }   // kaptan: bar değiştir = yeniden bar seç
  kodaDon();                                   // mutfak: eski davranış
}
```

- [ ] **Step 7: `gonder` çağrısına kaptan kimliğini ekle** (507-510)

```js
    const { data, error } = await SB.rpc("siparis_gonder", {
      p_outlet_kod: C.c, p_outlet_ad: C.n, p_kalemler: kalemler,
      p_bolum: C.bl, p_istemci_id: siparisId, p_pin: PIN,
      p_kaptan_kod: KAPTAN ? KAPTAN.kod : null,
      p_kaptan_pin: KAPTAN ? KAPTAN.pin : null
    });
```

- [ ] **Step 8: Açılışta kaptanları yükle + oturumdan geri yükle** (mevcut init/DOMContentLoaded neredeyse; `kaptanlariYukle()` çağır, sessionStorage'daki kaptanı geri yükle)

```js
kaptanlariYukle();
(function kaptanOturumGeriYukle(){
  const kod = sessionStorage.getItem("gurok_kaptan_kod");
  const ad  = sessionStorage.getItem("gurok_kaptan_ad");
  const pin = sessionStorage.getItem("gurok_kaptan_pin");
  if (kod && ad && pin) KAPTAN = { kod, ad, pin };
})();
```

- [ ] **Step 9: Tarayıcı duman testi**

Statik sunucu (8899) çalışırken `bar.html` aç → konsol hatası yok → şu doğrulama geçmeli:

```js
// javascript_tool ile:
JSON.stringify({
  kaptanGiris: typeof kaptanGiris, barSecimGoster: typeof barSecimGoster,
  barSec: typeof barSec, kaptanSec: !!document.getElementById('kaptanSec'),
  barEkran: !!document.getElementById('barEkran')
})
// hepsi function/true olmalı
```

- [ ] **Step 10: Commit**

```bash
git add bar.html && git commit -F <mesaj>
# mesaj: "feat: bar.html kaptan giris + bar secim + gonderimde kaptan kimligi"
```

---

## Task 4: admin.html — Kaptanlar paneli

**Files:**
- Modify: `admin.html` — üst araç çubuğuna buton (28), yeni `kaptanPanel` HTML (33 civarı), script'e kaptan fonksiyonları
- Test: tarayıcı duman testi

**Interfaces:**
- Consumes: `kaptan_liste`, `kaptan_ekle`, `kaptan_sil` (Task 1).

- [ ] **Step 1: Araç çubuğuna buton** (28. satır yanına)

```html
<button class="cb" style="width:auto;margin:0;padding:9px 14px" onclick="kaptanPaneliAc()">🧑‍✈️ Kaptanlar</button>
```

- [ ] **Step 2: Kaptan paneli HTML'i** (pinPanel'den sonra ~38)

```html
<div id="kaptanPanel" style="display:none;padding:12px">
  <button class="geri" onclick="kaptanPaneliKapat()">← Liste düzenlemeye dön</button>
  <div class="depo-header"><span>KAPTAN YÖNETİMİ</span><span class="depo-count" id="kaptanCount">—</span></div>
  <div class="ekle-kutu">
    <b>Kaptan ekle</b>
    <input id="kKod" placeholder="Kod (K01)" maxlength="10">
    <input id="kAd" placeholder="Ad Soyad">
    <input id="kPin" placeholder="PIN (3-12 hane)" maxlength="12" inputmode="numeric">
    <button class="gb" onclick="kaptanEkle()">+ Ekle</button>
  </div>
  <div id="kaptanIcerik"><div class="em">Yükleniyor...</div></div>
</div>
```

- [ ] **Step 3: Kaptan fonksiyonları** (script'e ekle)

```js
async function kaptanPaneliAc() {
  if (!SIFRE) { alert("Önce giriş yapın."); return; }
  document.getElementById("listePanel").style.display = "none";
  document.getElementById("pinPanel").style.display = "none";
  document.getElementById("kaptanPanel").style.display = "";
  await kaptanListele();
}
function kaptanPaneliKapat() {
  document.getElementById("kaptanPanel").style.display = "none";
  document.getElementById("listePanel").style.display = "";
}
async function kaptanListele() {
  const kutu = document.getElementById("kaptanIcerik");
  try {
    const { data, error } = await SB.rpc("kaptan_liste", { p_sifre: SIFRE });
    if (error) throw error;
    const list = data || [];
    document.getElementById("kaptanCount").textContent = list.length + " kaptan";
    kutu.innerHTML = list.length
      ? '<table class="tb"><thead><tr><th>KOD</th><th>AD</th><th></th></tr></thead><tbody>' +
        list.map(k => '<tr><td><b>' + htmlEsc(k.kod) + '</b></td><td>' + htmlEsc(k.ad) + '</td>' +
          '<td><button class="cb" style="width:auto;margin:0;padding:6px 12px" onclick="kaptanSil(\'' +
          htmlEsc(k.kod) + '\')">Sil</button></td></tr>').join("") + '</tbody></table>'
      : '<div class="em">Henüz kaptan yok. Yukarıdan ekleyin.</div>';
  } catch (e) { kutu.innerHTML = '<div class="em">⚠ ' + htmlEsc(e.message || "hata") + '</div>'; }
}
async function kaptanEkle() {
  const kod = document.getElementById("kKod").value.trim();
  const ad = document.getElementById("kAd").value.trim();
  const pin = document.getElementById("kPin").value.trim();
  if (!kod || !ad || !pin) { alert("Kod, ad ve PIN gerekli."); return; }
  try {
    const { error } = await SB.rpc("kaptan_ekle", { p_sifre: SIFRE, p_kod: kod, p_ad: ad, p_pin: pin });
    if (error) throw error;
    document.getElementById("kKod").value = ""; document.getElementById("kAd").value = ""; document.getElementById("kPin").value = "";
    await kaptanListele();
  } catch (e) { alert("Eklenemedi: " + (e.message || "hata")); }
}
async function kaptanSil(kod) {
  if (!confirm(kod + " kaptanı silinsin mi?")) return;
  try {
    const { error } = await SB.rpc("kaptan_sil", { p_sifre: SIFRE, p_kod: kod });
    if (error) throw error;
    await kaptanListele();
  } catch (e) { alert("Silinemedi: " + (e.message || "hata")); }
}
```

- [ ] **Step 4: Tarayıcı duman testi** — `admin.html` aç, konsol hatasız; `typeof kaptanPaneliAc === "function"` ve `#kaptanPanel` mevcut.

- [ ] **Step 5: Commit**

```bash
git add admin.html && git commit -F <mesaj>
# mesaj: "feat: admin.html Kaptanlar paneli (ekle/sil/liste)"
```

---

## Self-Review Notları

- **Spec kapsamı:** kaptan tablosu+RPC → Task 1; siparis_gonder tur ayrımı → Task 2; bar.html kaptan giriş+bar seçim+gönderim → Task 3; admin Kaptanlar → Task 4; depo değişmez (görev yok, doğru). Login UX = isim listesi+PIN (spec önerisi), Task 3 Step 1/4.
- **Placeholder yok:** tüm adımlar gerçek kod içerir.
- **Tip tutarlılığı:** `KAPTAN={kod,ad,pin}` (Task 3) ↔ `siparis_gonder` `p_kaptan_kod/p_kaptan_pin` (Task 2) ↔ `kaptan_giris(p_kod,p_pin)` (Task 1). Kaptan `kod` her yerde giriş kimliği.
- **Geri-uyum:** `siparis_gonder` yeni paramlar default null; mutfak akışı (tur≠'bar') hiç değişmedi; PostgREST adlı-param çözümü eski çağrıları da kabul eder.
- **Güvenlik:** bar için kaptan zorunlu sunucuda (`v_tur='bar'` → gonderen null ise raise); gonderen sunucudan; kaptan tablosu RLS+revoke; PIN bcrypt. `outletler.tur` doğru olmalı (risk spec'te not edildi).
- **Deploy:** kurulum.sql + bar.html + admin.html birlikte; ilk kaptanlar admin panelinden eklenir.
