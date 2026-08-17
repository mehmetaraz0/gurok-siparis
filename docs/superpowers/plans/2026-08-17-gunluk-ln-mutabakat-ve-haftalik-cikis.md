# Günlük LN Mutabakatı + Outlet Haftalık Çıkış Excel'i — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Depo stoğunu her gün LN anlık sayımıyla mutabık kılmak (gelen malı otomatik ekleyip canlı takibi bozmadan) ve her outlet için haftalık toplam çıkışı mevcut LN Excel formatında üretmek.

**Architecture:** Saf mantık `mutabakat.js`'te (Node'da `vm` ile test edilir), veritabanı mantığı yeni `stok_mutabakat` + `mutabakat_bilgi` RPC'lerinde (`kurulum.sql`), arayüz `depo.html` STOK sekmesinde. Mevcut otomatik stok düşümü (`depo_durum_degistir`) ve `buildExcelBlob` **değişmez**.

**Tech Stack:** Vanilla JS, Supabase Postgres (SECURITY DEFINER RPC), JSZip+SheetJS, Node (test + libpg-query SQL doğrulama).

## Global Constraints

- Türkçe arayüz ve mesajlar. Kod deseni: kalem kodu `^[A-Z]{3}[0-9]{8}$`.
- Tüketim = **durum='onaylandi'** siparişler; kalem miktarı = `coalesce((el->>'o')::numeric,(el->>'m')::numeric)` (düzeltilmiş miktar, yoksa asıl).
- `ayarlar` tablosu (anahtar text, deger text) anahtar/değer deposudur.
- Tüm yeni RPC'ler `security definer set search_path = public, extensions`, başında `if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;`, sonunda `grant execute ... to anon`.
- `buildExcelBlob(outletKod, outletAd, kalemler)` — `kalemler = [{k,a,b,m}]`. Çıktısı non-`&` ürünlerde **birebir aynı** kalmalı (regresyon).
- Zaman dilimi: `Europe/Istanbul`. Kesim günü: **Cumartesi** (dow=6).
- SQL değişiklikleri `libpg-query` ile parse-doğrulanır. Yeni RPC canlıya çıkınca kullanıcı `kurulum.sql`'i tekrar çalıştırmalı (buton aksi halde hata verir).

---

## Task 1: Mutabakat formülü (saf mantık)

**Files:**
- Create: `mutabakat.js`
- Test: `scratchpad/test-mutabakat.js` (Node, `vm` ile yükler)

**Interfaces:**
- Produces: `mutabakatHesapla(kalemler, stokMap, gMap, kesim)` → `[{k,a,b,s,g,l,fark,yeni}]`
  - `kalemler`: `[{k,a,b,m}]` (m = LN sayısı L)
  - `stokMap`: `{kod: mevcutStok}` (S), `gMap`: `{kod: donemCikis}` (G), `kesim`: boolean
  - `s=Number(stokMap[k]||0)`, `g=Number(gMap[k]||0)`, `l=Number(m)`, `yeni = kesim ? l : l-g`, `fark = yeni - s`

- [ ] **Step 1: Failing test yaz** — `scratchpad/test-mutabakat.js`

```js
const fs = require("fs"), vm = require("vm");
const ctx = { module: {}, console };
vm.createContext(ctx);
vm.runInContext(fs.readFileSync("mutabakat.js", "utf8"), ctx);
const mutabakatHesapla = vm.runInContext("mutabakatHesapla", ctx);

let fail = 0;
const eq = (ad, a, b) => { if (JSON.stringify(a) !== JSON.stringify(b)) { console.error("FAIL", ad, "beklenen", b, "gelen", a); fail++; } };

// Normal gün: L=150, S=100, G=30 → fark 20, yeni 120 (kullanıcı örneği)
let r = mutabakatHesapla([{k:"YIY01000001",a:"DANA",b:"kg",m:150}], {YIY01000001:100}, {YIY01000001:30}, false)[0];
eq("normal-fark", r.fark, 20); eq("normal-yeni", r.yeni, 120);

// Kesim günü (Cumartesi): yeni = L = 150, fark = 50
r = mutabakatHesapla([{k:"YIY01000001",a:"DANA",b:"kg",m:150}], {YIY01000001:100}, {YIY01000001:30}, true)[0];
eq("kesim-yeni", r.yeni, 150); eq("kesim-fark", r.fark, 50);

// Yeni ürün (stok yok): S=0, G=0 → yeni = L
r = mutabakatHesapla([{k:"YIY09000999",a:"YENI",b:"ad",m:12}], {}, {}, false)[0];
eq("yeni-urun-yeni", r.yeni, 12); eq("yeni-urun-fark", r.fark, 12);

console.log(fail ? `\n${fail} test BAŞARISIZ` : "\nTüm testler geçti");
process.exit(fail ? 1 : 0);
```

- [ ] **Step 2: Testi çalıştır, BAŞARISIZ olduğunu gör**

Run: `cd "D:/sipariş/gurok-siparis" && node scratchpad/test-mutabakat.js`
Beklenen: FAIL (mutabakat.js yok / fonksiyon tanımsız).

- [ ] **Step 3: `mutabakat.js` yaz**

```js
// mutabakat.js — Günlük LN mutabakatı saf mantık (tarayıcı + Node/vm)
// L = LN sayısı, S = mevcut stok (siparişlerle canlı düşmüş),
// G = son kesimden (Cumartesi) beri onaylanan çıkış.
// Kesim günü: yeni = L (LN tüketimi işledi). Diğer gün: yeni = L - G.
// fark = yeni - S = stoğa eklenecek (gelen mal). S ve G sunucudan gelir.
function mutabakatHesapla(kalemler, stokMap, gMap, kesim) {
  return kalemler.map(function (it) {
    var l = Number(it.m);
    var s = Number((stokMap && stokMap[it.k]) || 0);
    var g = Number((gMap && gMap[it.k]) || 0);
    var yeni = kesim ? l : l - g;
    return { k: it.k, a: it.a, b: it.b, s: s, g: g, l: l, fark: yeni - s, yeni: yeni };
  });
}
```

- [ ] **Step 4: Testi çalıştır, GEÇTİĞİNİ gör**

Run: `node scratchpad/test-mutabakat.js`
Beklenen: "Tüm testler geçti".

- [ ] **Step 5: Commit**

```bash
git add mutabakat.js && git commit -F <mesaj-dosyası>
# mesaj: "feat: mutabakat formulu (saf mantik) + test"
```

---

## Task 2: SQL — ayarlar.son_kesim + stok_mutabakat + mutabakat_bilgi

**Files:**
- Modify: `kurulum.sql` (ayarlar seed bloğu ~131; stok_yukleme mod constraint 476-477; STOK bölümüne yeni RPC'ler; grant bloğu ~844-854)
- Test: `scratchpad/validate-sql.js` (libpg-query parse)

**Interfaces:**
- Produces:
  - `mutabakat_bilgi(p_sifre text)` → `{ son_kesim, bugun_kesim, g: [{kod,g}] }`
  - `stok_mutabakat(p_sifre text, p_kalemler jsonb, p_kesim boolean default null, p_zorla boolean default false, p_uygula boolean default true)` → `{ ok, adet, toplam, zorlandi, kesim, kalemler:[{k,a,b,s,g,l,fark,yeni}] }`
- Consumes: mevcut `depo_dogru`, `stok`, `siparisler`, `ayarlar`, `stok_yukleme`, `extensions.digest`.

- [ ] **Step 1: `ayarlar`'a son_kesim seed ekle** (mevcut ayarlar insert'lerinin yanına, ~135. satırdan sonra)

```sql
-- Son kesim (Cumartesi) — mutabakatta G'nin başlangıç noktası. Varsayılan: en yakın geçmiş Cumartesi 00:00.
insert into public.ayarlar (anahtar, deger)
values ('son_kesim',
  (date_trunc('day', (now() at time zone 'Europe/Istanbul'))
   - (((extract(dow from (now() at time zone 'Europe/Istanbul'))::int + 1) % 7) || ' days')::interval)::text)
on conflict (anahtar) do nothing;
```

- [ ] **Step 2: stok_yukleme mod constraint'ine 'mutabakat' ekle** (kurulum.sql:477'i değiştir)

```sql
alter table public.stok_yukleme add constraint stok_yukleme_mod_chk check (mod in ('baseline','malkabul','mutabakat'));
```

- [ ] **Step 3: `mutabakat_bilgi` ve `stok_mutabakat` RPC'lerini ekle** (STOK bölümüne, stok_temizle'den sonra ~688)

```sql
-- Mutabakat için hazırlık bilgisi: son kesim, bugün kesim mi, ürün bazında dönem çıkışı (G)
create or replace function public.mutabakat_bilgi(p_sifre text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_kesim timestamptz; v_bugun_kesim boolean;
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  select deger::timestamptz into v_kesim from ayarlar where anahtar = 'son_kesim';
  v_bugun_kesim := extract(dow from (now() at time zone 'Europe/Istanbul')) = 6;
  return jsonb_build_object(
    'son_kesim', v_kesim,
    'bugun_kesim', v_bugun_kesim,
    'g', coalesce((
      select jsonb_agg(jsonb_build_object('kod', kod, 'g', g))
      from (
        select el->>'k' kod, sum(coalesce((el->>'o')::numeric,(el->>'m')::numeric)) g
        from siparisler ss, jsonb_array_elements(ss.kalemler) el
        where ss.durum = 'onaylandi' and ss.onay_saati > v_kesim
          and (el->>'k') ~ '^[A-Z]{3}[0-9]{8}$'
        group by 1
      ) t), '[]'::jsonb));
end $$;

-- Günlük LN mutabakatı. p_kalemler=[{k,a,b,m}] (m=LN sayısı L).
-- p_kesim null => bugün Cumartesi ise true. Kesim: yeni=L, son_kesim=now(). Diğer: yeni=L-G.
-- p_uygula=false => sadece önizleme (stok/kayıt değişmez).
create or replace function public.stok_mutabakat(
  p_sifre text, p_kalemler jsonb, p_kesim boolean default null,
  p_zorla boolean default false, p_uygula boolean default true)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_kesim timestamptz; v_bugun_kesim boolean; v_rows jsonb; v_imza text;
  v_adet int; v_toplam numeric; v_eski timestamptz; v_mukerrer boolean := false;
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if jsonb_typeof(p_kalemler) <> 'array' then raise exception 'Gecersiz veri'; end if;
  select deger::timestamptz into v_kesim from ayarlar where anahtar = 'son_kesim';
  v_bugun_kesim := coalesce(p_kesim, extract(dow from (now() at time zone 'Europe/Istanbul')) = 6);

  with ham as (
    select el->>'k' kod, left(el->>'a',120) ad, left(coalesce(el->>'b','ad'),20) birim,
           (el->>'m')::numeric l
      from jsonb_array_elements(p_kalemler) el
     where el->>'k' ~ '^[A-Z]{3}[0-9]{8}$' and (el->>'m') ~ '^-?[0-9]+(\.[0-9]+)?$'),
  veri as (select kod, max(ad) ad, max(birim) birim, max(l) l from ham group by kod),
  g as (
    select el->>'k' kod, sum(coalesce((el->>'o')::numeric,(el->>'m')::numeric)) g
    from siparisler ss, jsonb_array_elements(ss.kalemler) el
    where ss.durum='onaylandi' and ss.onay_saati > v_kesim and (el->>'k') ~ '^[A-Z]{3}[0-9]{8}$'
    group by 1),
  hesap as (
    select v.kod, v.ad, v.birim, v.l,
           coalesce(s.miktar, 0) s, coalesce(g.g, 0) gg,
           s.miktar e,
           case when v_bugun_kesim then v.l else v.l - coalesce(g.g,0) end yeni
    from veri v
    left join stok s on s.kod = v.kod
    left join g on g.kod = v.kod)
  select coalesce(jsonb_agg(jsonb_build_object(
           'k',kod,'a',ad,'b',birim,'s',s,'g',gg,'l',l,'fark',yeni - s,'yeni',yeni,'e',e) order by kod),'[]'::jsonb)
    into v_rows from hesap;

  v_adet := jsonb_array_length(v_rows);
  if v_adet = 0 then raise exception 'Uygulanabilir kalem yok'; end if;

  select encode(extensions.digest(
           string_agg((el->>'k')||':'||(el->>'l'),';' order by el->>'k'),'sha256'),'hex'),
         coalesce(sum((el->>'yeni')::numeric),0)
    into v_imza, v_toplam from jsonb_array_elements(v_rows) el;

  select olusturma into v_eski from stok_yukleme
   where imza = v_imza and mod='mutabakat' and not geri_alindi order by olusturma desc limit 1;
  if found then
    v_mukerrer := true;
    if p_uygula and not coalesce(p_zorla,false) then
      raise exception 'Bu dosya zaten yuklendi: %. Yine de uygulamak icin "yine de uygula" isaretleyin.',
        to_char(v_eski at time zone 'Europe/Istanbul','DD.MM.YYYY HH24:MI');
    end if;
  end if;

  if p_uygula then
    insert into stok (kod, ad, birim, miktar, guncelleme)
    select el->>'k', el->>'a', el->>'b', (el->>'yeni')::numeric, now()
      from jsonb_array_elements(v_rows) el
    on conflict (kod) do update set miktar=excluded.miktar, ad=excluded.ad,
      birim=excluded.birim, guncelleme=now();

    insert into stok_yukleme (mod, imza, kalem_sayisi, toplam, kalemler, zorlandi)
    values ('mutabakat', v_imza, v_adet, v_toplam,
      (select jsonb_agg(jsonb_build_object('k',el->>'k','a',el->>'a','b',el->>'b','m',el->>'yeni','e',el->'e'))
         from jsonb_array_elements(v_rows) el), v_mukerrer);

    if v_bugun_kesim then
      update ayarlar set deger = now()::text where anahtar='son_kesim';
    end if;
  end if;

  return jsonb_build_object('ok', true, 'adet', v_adet, 'toplam', v_toplam,
    'zorlandi', v_mukerrer, 'kesim', v_bugun_kesim, 'kalemler', v_rows);
end $$;
```

- [ ] **Step 4: grant bloğuna ekle** (kurulum.sql ~854, stok_temizle grant'ının yanına)

```sql
grant execute on function public.mutabakat_bilgi(text)                                to anon;
grant execute on function public.stok_mutabakat(text, jsonb, boolean, boolean, boolean) to anon;
```

- [ ] **Step 5: SQL'i libpg-query ile doğrula** — `scratchpad/validate-sql.js`

```js
const fs = require("fs");
const { parse } = require("libpg-query");
(async () => {
  const sql = fs.readFileSync("kurulum.sql", "utf8");
  try { const r = await parse(sql); console.log("OK, statement:", r.stmts.length); }
  catch (e) { console.error("PARSE HATASI:", e.message); process.exit(1); }
})();
```

Run: `node scratchpad/validate-sql.js`
Beklenen: "OK, statement: N" (hata yok).

- [ ] **Step 6: Commit**

```bash
git add kurulum.sql && git commit -F <mesaj>
# mesaj: "feat: stok_mutabakat + mutabakat_bilgi RPC + son_kesim ayari"
```

---

## Task 3: depo.html — Günlük LN Mutabakat modu (arayüz)

**Files:**
- Modify: `depo.html` — STOK sekmesi mod radyoları (84-86), script (`mutabakat.js` yükle), stok akış fonksiyonları (~1010-1140), önizleme/uygulama
- Modify: `stil.css` (gerekirse; mevcut `stok-tbl` yeniden kullanılır)

**Interfaces:**
- Consumes: `mutabakatHesapla` (Task 1), `mutabakat_bilgi` + `stok_mutabakat` (Task 2), mevcut `stokDosyaOku`/`stokParsed` (k,a,b,kalan,gelen), `STOK` global.

- [ ] **Step 1: `mutabakat.js`'i sayfaya ekle** — depo.html `<head>`/script bloğunda diğer JS dosyalarının (ortak.js, tuketim.js) yanına:

```html
<script src="mutabakat.js"></script>
```

- [ ] **Step 2: Üçüncü mod radyosunu ekle** (depo.html:86'daki malkabul label'ından sonra)

```html
<label><input type="radio" name="stokMod" value="mutabakat" onchange="stokModDegisti()">
  📅 Günlük LN Mutabakat</label>
```

- [ ] **Step 3: `stokModDegisti` ve önizleme mantığını genişlet**

`stokModDegisti()` mutabakat modunda: LN dosyasından `L = kalan` kullanılır (KUM raporundaki "Kalan" sütunu = anlık stok). Dosya yüklüyse `mutabakatOnizle()` çağrılır.

`mutabakatOnizle()` (yeni):
```js
async function mutabakatOnizle() {
  if (!stokParsed || !stokParsed.length) return;
  const kalemler = stokParsed.map(k => ({ k: k.k, a: k.a, b: k.b, m: k.kalan }));
  const kesimKutu = document.getElementById("mutabakatKesim");
  const args = { p_sifre: SIFRE, p_kalemler: kalemler, p_uygula: false };
  if (kesimKutu && kesimKutu.dataset.dokunuldu === "1") args.p_kesim = kesimKutu.checked;
  const { data, error } = await SB.rpc("stok_mutabakat", args);
  if (error) { document.getElementById("stokOnizle").innerHTML =
      '<span class="hata">⛔ ' + htmlEsc(error.message) + '</span>'; return; }
  if (kesimKutu && kesimKutu.dataset.dokunuldu !== "1") kesimKutu.checked = !!data.kesim;
  cizMutabakatOnizle(data);
}
```

`cizMutabakatOnizle(data)` (yeni): `data.kalemler` için tablo çizer — `KOD · AD · S · G · L · GELEN(fark) · YENİ`. `fark<0` veya `yeni<0` satırı `class="negatif"`. Başlıkta kesim durumunu göster: `data.kesim ? "KESİM (LN'e eşitle)" : "Normal (L−G)"`.

- [ ] **Step 4: `stokUygula`'yı mutabakat için genişlet** (mevcut fonksiyon ~1082)

`mod === "mutabakat"` dalı:
```js
if (mod === "mutabakat") {
  const kalemler = stokParsed.map(k => ({ k: k.k, a: k.a, b: k.b, m: k.kalan }));
  const kesimKutu = document.getElementById("mutabakatKesim");
  const args = { p_sifre: SIFRE, p_kalemler: kalemler, p_uygula: true, p_kesim: kesimKutu.checked };
  if (zorla) args.p_zorla = true;
  const { data, error } = await SB.rpc("stok_mutabakat", args);
  if (error) throw error;   // "zaten yuklendi" mevcut catch'te ele alınır
  btn.textContent = "✅ " + data.adet + " kalem mutabık" + (data.kesim ? " (kesim)" : "");
  // ... mevcut temizlik + stokGetir + yuklemeGetir
  return;
}
```
Kesim kutusu HTML'i (önizleme kutusunun yanında): `<label><input type="checkbox" id="mutabakatKesim" onchange="this.dataset.dokunuldu='1'"> Cumartesi kesimi (stoğu LN'e eşitle)</label>`.

- [ ] **Step 5: Tarayıcıda duman testi**

`mcp__Claude_Browser__preview_start` ile depo.html açılır → Konsol hatası yok → mutabakat modu seçilince kesim kutusu görünür. (Canlı RPC testi kullanıcı `kurulum.sql`'i çalıştırdıktan sonra yapılır.)

Run/kontrol: konsolda JS hatası olmamalı; `document.querySelector('input[value=mutabakat]')` mevcut olmalı.

- [ ] **Step 6: Commit**

```bash
git add depo.html stil.css && git commit -F <mesaj>
# mesaj: "feat: depo gunluk LN mutabakat modu (onizleme + kesim)"
```

---

## Task 4: Outlet haftalık çıkış toplama (saf mantık)

**Files:**
- Modify: `mutabakat.js` (fonksiyon ekle)
- Test: `scratchpad/test-haftalik.js`

**Interfaces:**
- Produces: `haftalikCikisTopla(siparisler, outletKod)` → `[{k,a,b,m}]` (kod bazında, m = Σ çıkış miktarı, kod'a göre sıralı)
  - `siparisler`: `depo_envanter` dönüşü `[{outlet_kod, durum, kalemler:[{k,a,b,m,o?}]}]`
  - Sadece `durum==='onaylandi'` ve `outlet_kod===outletKod`; miktar = `o ?? m`; `m>0` süzülür.

- [ ] **Step 1: Failing test** — `scratchpad/test-haftalik.js`

```js
const fs = require("fs"), vm = require("vm");
const ctx = { console }; vm.createContext(ctx);
vm.runInContext(fs.readFileSync("mutabakat.js", "utf8"), ctx);
const topla = vm.runInContext("haftalikCikisTopla", ctx);

const sip = [
  { outlet_kod:"B201", durum:"onaylandi", kalemler:[{k:"YIY01000001",a:"DANA",b:"kg",m:5},{k:"ICA00000002",a:"KOLA",b:"ad",m:10}] },
  { outlet_kod:"B201", durum:"onaylandi", kalemler:[{k:"YIY01000001",a:"DANA",b:"kg",m:3,o:2}] }, // o kazanır
  { outlet_kod:"B201", durum:"talep",     kalemler:[{k:"YIY01000001",a:"DANA",b:"kg",m:99}] },     // onaysız sayılmaz
  { outlet_kod:"M201", durum:"onaylandi", kalemler:[{k:"YIY01000001",a:"DANA",b:"kg",m:7}] },       // başka outlet
];
const r = topla(sip, "B201");
let fail = 0; const eq=(n,a,b)=>{ if(JSON.stringify(a)!==JSON.stringify(b)){console.error("FAIL",n,a,"!=",b);fail++;} };
eq("adet", r.length, 2);
eq("dana", r.find(x=>x.k==="YIY01000001").m, 7);   // 5 + 2(o) ; talep ve M201 hariç
eq("kola", r.find(x=>x.k==="ICA00000002").m, 10);
eq("sirali", r.map(x=>x.k), ["ICA00000002","YIY01000001"]);
console.log(fail?`${fail} FAIL`:"Tüm testler geçti"); process.exit(fail?1:0);
```

- [ ] **Step 2: Çalıştır, BAŞARISIZ gör** — Run: `node scratchpad/test-haftalik.js` → FAIL (fonksiyon yok).

- [ ] **Step 3: `haftalikCikisTopla`'yı `mutabakat.js`'e ekle**

```js
// Bir outlet'in onaylı siparişlerini kod bazında toplar (haftalık çıkış Excel'i için).
// Dönüş buildExcelBlob'un beklediği [{k,a,b,m}] biçiminde, kod'a göre sıralı.
function haftalikCikisTopla(siparisler, outletKod) {
  var map = {};
  (siparisler || []).forEach(function (s) {
    if (s.durum !== "onaylandi" || s.outlet_kod !== outletKod) return;
    (s.kalemler || []).forEach(function (el) {
      var mik = (el.o === undefined || el.o === null) ? Number(el.m) : Number(el.o);
      if (!(mik > 0)) return;
      if (!map[el.k]) map[el.k] = { k: el.k, a: el.a, b: el.b || "ad", m: 0 };
      map[el.k].m += mik;
    });
  });
  return Object.keys(map).sort().map(function (k) { return map[k]; });
}
```

- [ ] **Step 4: Çalıştır, GEÇTİĞİNİ gör** — Run: `node scratchpad/test-haftalik.js` → "Tüm testler geçti".

- [ ] **Step 5: Commit**

```bash
git add mutabakat.js && git commit -F <mesaj>
# mesaj: "feat: haftalikCikisTopla (outlet cikis toplama) + test"
```

---

## Task 5: depo.html — Outlet haftalık çıkış Excel'i (arayüz)

**Files:**
- Modify: `depo.html` — TÜKETİM sekmesine outlet seçici + tarih aralığı + indirme butonu; script'e `haftalikExcelIndir()`

**Interfaces:**
- Consumes: `haftalikCikisTopla` (Task 4), `buildExcelBlob` (ortak.js), `depo_envanter` + `mutabakat_bilgi` (RPC), mevcut outlet listesi (TÜKETİM sekmesi zaten outletleri biliyor / `OUTLETLER` global veya siparişlerden türetilir).

- [ ] **Step 1: Arayüz öğelerini ekle** (TÜKETİM sekmesi üstüne)

```html
<div class="haftalik-cikis">
  <select id="hcOutlet"></select>
  <input type="date" id="hcBas"> – <input type="date" id="hcBit">
  <button class="cb" onclick="haftalikExcelIndir()">📥 Haftalık Çıkış Excel</button>
</div>
```
`hcOutlet` TÜKETİM verisindeki benzersiz `outlet_kod (outlet_ad)` ile doldurulur. Sayfa açılışında `mutabakat_bilgi` ile `hcBas = son_kesim tarihi`, `hcBit = bugün` önceden doldurulur (elle değişebilir).

- [ ] **Step 2: `haftalikExcelIndir()` yaz**

```js
async function haftalikExcelIndir() {
  const kod = document.getElementById("hcOutlet").value;
  const bas = document.getElementById("hcBas").value, bit = document.getElementById("hcBit").value;
  if (!kod || !bas || !bit) { alert("Outlet ve tarih aralığı seçin."); return; }
  const { data, error } = await SB.rpc("depo_envanter", { p_sifre: SIFRE, p_bas: bas, p_bit: bit });
  if (error) { alert("Alınamadı: " + error.message); return; }
  const kalemler = haftalikCikisTopla(data || [], kod);
  if (!kalemler.length) { alert("Bu outlet için bu aralıkta onaylı çıkış yok."); return; }
  const ad = (data.find(s => s.outlet_kod === kod) || {}).outlet_ad || kod;
  const blob = await buildExcelBlob(kod, ad, kalemler);
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = "haftalik_cikis_" + kod + "_" + bas + "_" + bit + ".xlsx";
  document.body.appendChild(a); a.click(); a.remove(); URL.revokeObjectURL(url);
}
```

- [ ] **Step 3: buildExcelBlob regresyon testi (Node)** — `scratchpad/test-excel-regresyon.js`

Bilinen bir kalem kümesiyle `buildExcelBlob` çağır, üretilen sheet1.xml'in kalem satırlarını mevcut davranışla karşılaştır (non-`&` ürünlerde byte-özdeş). ortak.js'in bağımlılıkları (JSZip, TPL_B64, ROW2, xmlEsc) `vm` + `jszip` (node) ile yüklenir.

Run: `node scratchpad/test-excel-regresyon.js`
Beklenen: "Excel çıktısı beklenenle aynı".

- [ ] **Step 4: Tarayıcı duman testi** — depo.html aç, TÜKETİM sekmesinde outlet+tarih seç, buton konsol hatası vermemeli.

- [ ] **Step 5: Commit**

```bash
git add depo.html && git commit -F <mesaj>
# mesaj: "feat: outlet haftalik cikis Excel (LN formatinda ozet)"
```

---

## Self-Review Notları

- **Spec kapsamı:** Çözüm 1 → Task 1-3; Çözüm 2 → Task 4-5. Cumartesi kesim kuralı Task 2 (`v_bugun_kesim`) + Task 3 (kesim kutusu). Geri alma: mutabakat `else` dalıyla çalışır (kurulum.sql:643-646, `e` değerine döner) — mod constraint'e 'mutabakat' eklendi (Task 2 Step 2), ek değişiklik gerekmez.
- **Çift sayım:** Formül `S`'i (otomatik düşülmüş stok) kullanır; `fark = yeni - S` yalnız gelen malı ekler. Task 1 testi kullanıcı örneğini (20/120) doğrular.
- **Geri-uyum:** `stok_mutabakat`/`mutabakat_bilgi` yeni; canlıda `kurulum.sql` çalıştırılmadan buton hata verir (kullanıcıya bildirilecek). `buildExcelBlob` çağrısı değişmez; Task 5 Step 3 regresyonu korur.
- **Tip tutarlılığı:** `mutabakatHesapla`/`stok_mutabakat` alanları aynı: `{k,a,b,s,g,l,fark,yeni}`. `haftalikCikisTopla`/`buildExcelBlob`: `{k,a,b,m}`.
